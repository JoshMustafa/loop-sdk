import Foundation

/// On-disk FIFO buffer for diagnostic payloads that failed to POST. Each
/// payload is written as its own `.json` file in `directory`; flushing reads
/// them oldest-first (lexicographic filenames, which are timestamp-prefixed).
///
/// Thread-safe via `NSLock`, matching the SDK's lock-not-actor convention.
/// Best-effort: disk errors are swallowed (diagnostics must never crash the
/// host), so a failed write simply means that one payload is dropped.
final class OfflineBufferStore: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let fileManager = FileManager.default

    init(directory: URL) {
        self.directory = directory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Default store location: an app-support subfolder. Falls back to the
    /// temporary directory if app-support is unavailable.
    static func makeDefault() -> OfflineBufferStore {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return OfflineBufferStore(directory: base.appendingPathComponent("LoopSDKDiagnostics", isDirectory: true))
    }

    /// Persist a payload for later retry. Filenames are sortable by age so
    /// `drain()` returns them in FIFO order.
    func enqueue(_ payload: Data) {
        lock.lock(); defer { lock.unlock() }
        let name = String(format: "%020.0f", Date().timeIntervalSince1970 * 1000)
            + "-" + UUID().uuidString + ".json"
        let url = directory.appendingPathComponent(name)
        try? payload.write(to: url, options: .atomic)
    }

    /// Returns the count of buffered payloads (test/observability hook).
    func pendingCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return fileURLs().count
    }

    /// Atomically removes and returns all buffered payloads, oldest first.
    /// The caller is responsible for re-enqueueing any that fail to send.
    func drain() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        let urls = fileURLs()
        var out: [Data] = []
        for url in urls {
            if let data = try? Data(contentsOf: url) {
                out.append(data)
            }
            try? fileManager.removeItem(at: url)
        }
        return out
    }

    private func fileURLs() -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
