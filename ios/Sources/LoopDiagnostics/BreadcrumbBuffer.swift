import Foundation

/// A single recorded breadcrumb. Captured at `record` time; the relative
/// time string is computed later, against the diagnostic capture moment.
struct Breadcrumb: Sendable {
    let message: String
    let fail: Bool
    let timestamp: Date
}

/// Thread-safe in-memory ring buffer of the most recent breadcrumbs.
///
/// Capped at `capacity` (20) — once full, recording a new crumb drops the
/// oldest. Mirrors the SDK's existing concurrency approach: a plain class
/// guarded by an `NSLock`, `@unchecked Sendable`, no actors.
final class BreadcrumbBuffer: @unchecked Sendable {
    static let capacity = 20

    private let lock = NSLock()
    private var crumbs: [Breadcrumb] = []

    func record(message: String, fail: Bool, at timestamp: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        crumbs.append(Breadcrumb(message: message, fail: fail, timestamp: timestamp))
        if crumbs.count > Self.capacity {
            crumbs.removeFirst(crumbs.count - Self.capacity)
        }
    }

    /// Returns a copy of the current crumbs, oldest first.
    func snapshot() -> [Breadcrumb] {
        lock.lock(); defer { lock.unlock() }
        return crumbs
    }
}
