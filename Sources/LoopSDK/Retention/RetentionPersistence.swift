import Foundation

/// Small UserDefaults-backed persistence for analytics identity + session
/// continuity. Lets `identify(_:)` survive relaunches and lets a quick
/// relaunch (< 30 min) resume the same session instead of minting a new
/// one. UserDefaults is already thread-safe, so no lock is needed.
final class RetentionPersistence: @unchecked Sendable {
    private enum Keys {
        static let userId = "io.loop.sdk.retention.userId"
        static let sessionId = "io.loop.sdk.retention.sessionId"
        static let lastActivityAt = "io.loop.sdk.retention.lastActivityAt"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var userId: String? {
        get { defaults.string(forKey: Keys.userId) }
        set { setOrRemove(newValue, forKey: Keys.userId) }
    }

    var sessionId: String? {
        get { defaults.string(forKey: Keys.sessionId) }
        set { setOrRemove(newValue, forKey: Keys.sessionId) }
    }

    var lastActivityAt: Date? {
        get { defaults.object(forKey: Keys.lastActivityAt) as? Date }
        set { setOrRemove(newValue, forKey: Keys.lastActivityAt) }
    }

    private func setOrRemove(_ value: Any?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
