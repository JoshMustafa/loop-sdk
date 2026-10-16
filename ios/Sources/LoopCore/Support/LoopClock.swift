import Foundation

/// Source of wall-clock time in Unix epoch milliseconds. Injectable so tests
/// can control time.
package protocol LoopClock: Sendable {
    func nowMillis() -> Int64
}

/// The real clock.
package struct SystemClock: LoopClock {
    package init() {}

    package func nowMillis() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
    }
}
