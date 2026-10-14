import Foundation

/// The durable event queue: an append-only JSON-lines file mirrored in memory.
///
/// * `add` appends the event's line to the file (and syncs it) before it
///   returns, so `peek` only ever returns events that are on disk.
/// * The queue is capped at `maxQueueSize`: when an event would exceed it,
///   the oldest `dropBatch` events are dropped at once (so this happens at
///   most once per `dropBatch` events) and the file is rewritten. The file is
///   also rewritten after every `remove` and compacted if it grows past twice
///   the cap; opening keeps only the newest `maxQueueSize` lines.
/// * Rewrites go through a synced temp file and a rename, so a crash or power
///   cut never leaves a half-written or empty queue.
/// * Corrupt or truncated lines are skipped on load.
/// * With a nil `fileURL` the queue lives in memory only.
actor EventStore {
    /// How many of the oldest events are dropped when the queue is full.
    static let dropBatch = 20

    /// A queued event and its encoded line (without the newline).
    private struct Entry {
        let event: LoopEvent
        let line: Data
    }

    private let fileURL: URL?
    private let maxQueueSize: Int
    /// Line count at which the file is compacted.
    private let compactAt: Int
    private let encoder = JSONEncoder()
    private var entries: [Entry]
    /// Lines in the file as far as we know (including dropped ones).
    private var fileLines: Int
    /// Set when the file no longer matches `entries` (a drop or a failed
    /// write); the next write rewrites it.
    private var needsRewrite = false

    init(fileURL: URL?, maxQueueSize: Int) async {
        let max = Swift.max(1, maxQueueSize)
        self.fileURL = fileURL
        self.maxQueueSize = max
        self.compactAt = max > Int.max / 2 ? Int.max : max * 2

        let raw = fileURL.flatMap { try? Data(contentsOf: $0) } ?? Data()
        var loaded: [Entry] = []
        var lines = 0
        var corrupt = 0
        let decoder = JSONDecoder()
        for line in raw.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            // JSON strings escape control characters, so a raw "\r" can only
            // be part of a CRLF line ending.
            var line = Data(line)
            if line.last == UInt8(ascii: "\r") { line.removeLast() }
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { continue }
            lines += 1
            do {
                let json = try decoder.decode(JSONObject.self, from: line)
                loaded.append(Entry(event: try LoopEvent(storageJSON: json), line: line))
            } catch {
                corrupt += 1
            }
        }
        let overflow = loaded.count - max
        if overflow > 0 { loaded.removeFirst(overflow) }

        self.entries = loaded
        self.fileLines = lines
        // A file ending mid-line must be rewritten, or the next append would
        // be glued onto the partial line.
        let cleanTail = raw.isEmpty || raw.last == UInt8(ascii: "\n")
        if corrupt > 0 || overflow > 0 || !cleanTail { rewrite() }
    }

    /// Number of queued events.
    var count: Int { entries.count }

    /// Queues `event` in memory and on disk. An event that cannot be
    /// JSON-encoded (e.g. a NaN built directly as a `JSONValue`) is not
    /// queued.
    func add(_ event: LoopEvent) {
        let line: Data
        do {
            line = try encoder.encode(event.storageJSON())
        } catch {
            Log.analytics.error("Dropped event \"\(event.name)\": it could not be encoded as JSON (\(error.localizedDescription))")
            return
        }
        entries.append(Entry(event: event, line: line))
        if entries.count > maxQueueSize {
            // Drop the oldest batch, but always keep the event just added.
            var dropped = Self.dropBatch
            if dropped < entries.count - maxQueueSize { dropped = entries.count - maxQueueSize }
            if dropped > entries.count - 1 { dropped = entries.count - 1 }
            entries.removeFirst(dropped)
            needsRewrite = true
        }
        guard fileURL != nil else { return }
        if needsRewrite || fileLines + 1 > compactAt {
            rewrite()
        } else {
            append(line)
        }
    }

    /// Up to `n` oldest events. They are already on disk.
    func peek(_ n: Int) -> [LoopEvent] {
        entries.prefix(Swift.max(0, n)).map(\.event)
    }

    /// Removes the events with these ids (e.g. after a successful upload).
    func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        entries.removeAll { ids.contains($0.event.id) }
        rewrite()
    }

    private func append(_ line: Data) {
        guard let fileURL else { return }
        do {
            try createDirectory(for: fileURL)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line + Data("\n".utf8))
            try handle.synchronize()
            fileLines += 1
        } catch {
            // The event is still queued in memory; fix the file next time.
            Log.analytics.error("Could not append to the analytics queue file; will rewrite it on the next change: \(error.localizedDescription)")
            needsRewrite = true
        }
    }

    /// Replaces the file with exactly the in-memory queue.
    private func rewrite() {
        guard let fileURL else { return }
        var data = Data()
        for entry in entries {
            data.append(entry.line)
            data.append(UInt8(ascii: "\n"))
        }
        do {
            try replaceDurably(fileURL, with: data)
            fileLines = entries.count
            needsRewrite = false
        } catch {
            // Covers every step of `replaceDurably` (directory, temp file,
            // write, rename): they throw to here, so each failure is logged once.
            Log.analytics.error("Could not rewrite the analytics queue file; \(entries.count) event(s) are kept in memory: \(error.localizedDescription)")
            needsRewrite = true
        }
    }

    /// Writes `data` to a temp file beside `file`, syncs it to disk, then
    /// renames it over `file`, so a crash or power cut leaves either the old
    /// queue or the new one, never an empty or partial file.
    private func replaceDurably(_ file: URL, with data: Data) throws {
        try createDirectory(for: file)
        let directory = file.deletingLastPathComponent()
        // A fixed name: a temp file left by a crash is simply overwritten.
        let temp = directory.appendingPathComponent(file.lastPathComponent + ".tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            // Logged by `rewrite()`, which this throws to.
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        guard rename(temp.path, file.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(code)
        }
        // Make the rename itself durable.
        let fd = open(directory.path, O_RDONLY)
        if fd >= 0 {
            fsync(fd)
            close(fd)
        }
    }

    private func createDirectory(for file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}
