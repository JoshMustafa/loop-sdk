import Foundation

/// A buffered event plus the id that names its file on disk. Ids are
/// timestamp+sequence prefixed, so lexicographic order == append order.
struct StoredRetentionEvent: Sendable {
    let id: String
    let event: RetentionEvent
}

/// Disk-backed FIFO buffer of analytics events awaiting flush. Follows the
/// `OfflineBufferStore` pattern (one JSON file per payload, sortable
/// filenames, `NSLock`, best-effort disk IO) but is deliberately its own
/// store: product-analytics events must never mix with diagnostics.
///
/// Unlike `OfflineBufferStore`, this keeps an in-memory mirror loaded at
/// init — events buffer in memory for cheap counting/snapshots and are
/// write-through persisted so they survive relaunch. Capped at `capacity`
/// (500): once full, appending drops the oldest event, memory and disk.
final class RetentionEventStore: @unchecked Sendable {
    static let defaultCapacity = 500

    private let lock = NSLock()
    private let directory: URL
    private let capacity: Int
    private let fileManager = FileManager.default
    private var entries: [StoredRetentionEvent] = []
    private var sequence: UInt64 = 0

    init(directory: URL, capacity: Int = RetentionEventStore.defaultCapacity) {
        self.directory = directory
        self.capacity = capacity
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        entries = Self.loadFromDisk(directory: directory, fileManager: fileManager)
        if entries.count > capacity {
            dropOldestLocked(entries.count - capacity)
        }
    }

    /// Default store location: an app-support subfolder, separate from the
    /// diagnostics buffer. Falls back to the temporary directory.
    static func makeDefault() -> RetentionEventStore {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return RetentionEventStore(directory: base.appendingPathComponent("LoopSDKRetention", isDirectory: true))
    }

    /// Buffers an event (memory + write-through disk), dropping the oldest
    /// beyond `capacity`. Disk errors are swallowed — analytics must never
    /// crash the host; a failed write just means that event won't survive
    /// a relaunch.
    func append(_ event: RetentionEvent) {
        lock.lock(); defer { lock.unlock() }
        let id = String(format: "%020.0f", Date().timeIntervalSince1970 * 1000)
            + String(format: "-%06llu-", sequence)
            + UUID().uuidString
        sequence += 1
        entries.append(StoredRetentionEvent(id: id, event: event))
        if let data = try? JSONEncoder().encode(event) {
            try? data.write(to: fileURL(for: id), options: .atomic)
        }
        if entries.count > capacity {
            dropOldestLocked(entries.count - capacity)
        }
    }

    func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// Current buffer, oldest first. The flush path snapshots, sends, then
    /// calls `remove(ids:)` on success — so a failed send keeps everything.
    func snapshot() -> [StoredRetentionEvent] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    /// Removes flushed (or poison-pill) events from memory and disk.
    /// Unknown ids are ignored, so racing with a capacity drop is harmless.
    func remove(ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        let removing = Set(ids)
        entries.removeAll { removing.contains($0.id) }
        for id in ids {
            try? fileManager.removeItem(at: fileURL(for: id))
        }
    }

    // MARK: - Internals

    private func dropOldestLocked(_ count: Int) {
        let dropped = entries.prefix(count)
        entries.removeFirst(min(count, entries.count))
        for entry in dropped {
            try? fileManager.removeItem(at: fileURL(for: entry.id))
        }
    }

    private func fileURL(for id: String) -> URL {
        directory.appendingPathComponent(id + ".json")
    }

    private static func loadFromDisk(directory: URL, fileManager: FileManager) -> [StoredRetentionEvent] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        let decoder = JSONDecoder()
        return contents
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let event = try? decoder.decode(RetentionEvent.self, from: data) else {
                    // Undecodable file (corrupt / future format): discard so
                    // it can't wedge the buffer forever.
                    try? fileManager.removeItem(at: url)
                    return nil
                }
                return StoredRetentionEvent(id: url.deletingPathExtension().lastPathComponent, event: event)
            }
    }
}
