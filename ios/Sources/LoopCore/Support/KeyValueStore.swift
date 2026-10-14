import Foundation

/// Small typed key-value persistence. Setting `nil` removes the key.
package protocol KeyValueStore: AnyObject, Sendable {
    func string(_ key: String) -> String?
    func int64(_ key: String) -> Int64?
    func bool(_ key: String) -> Bool?
    func set(_ value: String?, for key: String)
    func set(_ value: Int64?, for key: String)
    func set(_ value: Bool?, for key: String)
}

/// `UserDefaults`-backed store in its own suite.
package final class UserDefaultsStore: KeyValueStore, @unchecked Sendable {
    // UserDefaults is thread-safe.
    private let defaults: UserDefaults

    /// Falls back to `.standard` if the suite cannot be opened.
    package init(suiteName: String) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    package func string(_ key: String) -> String? {
        defaults.object(forKey: key) as? String
    }

    package func int64(_ key: String) -> Int64? {
        (defaults.object(forKey: key) as? NSNumber)?.int64Value
    }

    package func bool(_ key: String) -> Bool? {
        (defaults.object(forKey: key) as? NSNumber)?.boolValue
    }

    package func set(_ value: String?, for key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    package func set(_ value: Int64?, for key: String) {
        if let value { defaults.set(NSNumber(value: value), forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    package func set(_ value: Bool?, for key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// In-memory store for tests and as a fallback.
package final class MemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    // Guarded by `lock`.
    private var values: [String: Any] = [:]
    private let lock = NSLock()

    package init() {}

    package func string(_ key: String) -> String? { get(key) as? String }
    package func int64(_ key: String) -> Int64? { get(key) as? Int64 }
    package func bool(_ key: String) -> Bool? { get(key) as? Bool }

    package func set(_ value: String?, for key: String) { put(value, key) }
    package func set(_ value: Int64?, for key: String) { put(value, key) }
    package func set(_ value: Bool?, for key: String) { put(value, key) }

    private func get(_ key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    private func put(_ value: Any?, _ key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }
}
