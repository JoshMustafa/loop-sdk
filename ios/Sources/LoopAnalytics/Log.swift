import Foundation
import os

/// The module's internal log. Read it with
/// `log stream --predicate 'subsystem == "io.loop.analytics"'` or in
/// Console.app; there is no public log-level setting yet.
enum Log {
    static let analytics = AnalyticsLog()

    enum Level: Sendable, Equatable {
        case debug, warning, error
    }

    /// Test hook: `observer` receives every message until
    /// `removeObserver(_:)` is called with the returned token.
    static func addObserver(_ observer: @escaping @Sendable (Level, String) -> Void) -> Int {
        observers.add(observer)
    }

    static func removeObserver(_ token: Int) {
        observers.remove(token)
    }

    fileprivate static let observers = Observers()

    fileprivate final class Observers: @unchecked Sendable {
        private let lock = NSLock()
        private var observers: [Int: @Sendable (Level, String) -> Void] = [:]
        private var nextToken = 0

        func add(_ observer: @escaping @Sendable (Level, String) -> Void) -> Int {
            lock.lock(); defer { lock.unlock() }
            nextToken += 1
            observers[nextToken] = observer
            return nextToken
        }

        func remove(_ token: Int) {
            lock.lock(); defer { lock.unlock() }
            observers[token] = nil
        }

        func notify(_ level: Level, _ message: String) {
            lock.lock()
            let current = Array(observers.values)
            lock.unlock()
            for observer in current { observer(level, message) }
        }
    }
}

/// Messages are for the app's developer: event names (which the developer
/// chooses), status codes, counts and error descriptions. They are logged
/// with `privacy: .public` so they stay readable on a device; never put
/// property values or user ids in one.
struct AnalyticsLog: Sendable {
    private let logger = Logger(subsystem: "io.loop.analytics", category: "analytics")

    func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        Log.observers.notify(.debug, message)
    }

    func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        Log.observers.notify(.warning, message)
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        Log.observers.notify(.error, message)
    }
}
