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
/// * Rewrites are atomic (temp file + rename), so a crash never leaves a
///   half-written queue.
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
        guard let line = try? encoder.encode(event.storageJSON()) else { return }
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
            try createDirectory(for: fileURL)
            try data.write(to: fileURL, options: .atomic)
            fileLines = entries.count
            needsRewrite = false
        } catch {
            needsRewrite = true
        }
    }

    private func createDirectory(for file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}
