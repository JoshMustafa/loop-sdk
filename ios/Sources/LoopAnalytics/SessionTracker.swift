import Foundation
import LoopCore

/// Idle-based sessions. The session id is the session's start time in ms
/// since epoch.
///
/// Each event, resume and pause counts as activity. When more than
/// `minTimeBetweenSessionsMillis` passes without activity, the next activity
/// starts a new session. While the app is known to be in the foreground the
/// session does not time out (someone reading a screen is not idle); idle time
/// is counted from the last event or from going to the background. No session
/// events are emitted. The id and last activity time are persisted so a quick
/// relaunch continues the session.
final class SessionTracker {
    static let sessionIdKey = "io.loop.analytics.session_id"
    static let lastActivityKey = "io.loop.analytics.last_activity"

    private let kv: KeyValueStore
    private let gap: Int64
    private let clock: LoopClock

    /// The current session id, or nil before the first activity.
    private(set) var sessionId: Int64?
    private var lastActivity: Int64?
    private var inForeground = false

    init(kv: KeyValueStore, minTimeBetweenSessionsMillis: Int64, clock: LoopClock) {
        self.kv = kv
        self.gap = minTimeBetweenSessionsMillis
        self.clock = clock
        sessionId = kv.int64(Self.sessionIdKey)
        lastActivity = kv.int64(Self.lastActivityKey)
    }

    /// Records an event; returns the session it belongs to.
    func onEvent() -> Int64 { touch() }

    /// The app came to the foreground: extend or roll over the session.
    func onForeground() {
        touch()
        inForeground = true
    }

    /// The app is going to the background: the time spent in it counts.
    func onBackground() {
        if sessionId != nil { touch() }
        inForeground = false
    }

    /// Ends the current session and starts a new one now.
    func startNew() {
        let now = clock.nowMillis()
        sessionId = now
        lastActivity = now
        persist()
    }

    @discardableResult
    private func touch() -> Int64 {
        let now = clock.nowMillis()
        let session: Int64
        if let current = sessionId, let last = lastActivity, inForeground || now - last <= gap {
            session = current
        } else {
            session = now
        }
        sessionId = session
        // A clock that moved backwards must not shorten the idle window.
        if lastActivity.map({ now > $0 }) ?? true { lastActivity = now }
        persist()
        return session
    }

    private func persist() {
        if let sessionId { kv.set(sessionId, for: Self.sessionIdKey) }
        if let lastActivity { kv.set(lastActivity, for: Self.lastActivityKey) }
    }
}
