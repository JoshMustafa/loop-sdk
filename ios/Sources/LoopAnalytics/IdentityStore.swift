import Foundation
import LoopCore

/// A new device id: a random UUID v4, upper-case, followed by `R`
/// (e.g. `9860D042-84A6-4BB3-95AB-F974F56D9C3DR`), the same shape as the
/// imported historical iOS ids.
func generateDeviceId() -> String {
    UUID().uuidString.uppercased() + "R"
}

/// Who the events are about: device id, user id, RevenueCat purchaser id, the
/// merged user-property snapshot and the opt-out flag. Persisted in a
/// `KeyValueStore`.
final class IdentityStore {
    static let deviceIdKey = "io.loop.analytics.device_id"
    static let userIdKey = "io.loop.analytics.user_id"
    static let purchaserIdKey = "io.loop.analytics.purchaser_id"
    static let userPropsKey = "io.loop.analytics.user_props"
    static let optOutKey = "io.loop.analytics.opt_out"

    /// Server limit on device ids.
    static let maxDeviceIdLength = 200

    private let kv: KeyValueStore
    private let newDeviceId: () -> String

    private(set) var deviceId: String
    private(set) var userId: String?
    private(set) var purchaserId: String?
    /// The current snapshot (a value; safe to embed in an event).
    private(set) var userProperties: JSONObject
    private(set) var optOut: Bool

    /// Loads the stored identity. On first run the device id is
    /// `legacyDeviceId` (trimmed) when it is valid, else `newDeviceId()`.
    init(kv: KeyValueStore, legacyDeviceId: String?, newDeviceId: @escaping () -> String) {
        self.kv = kv
        self.newDeviceId = newDeviceId
        if let stored = kv.string(Self.deviceIdKey), Self.isValidDeviceId(stored) {
            deviceId = stored
        } else {
            let legacy = legacyDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines)
            deviceId = legacy.flatMap { Self.isValidDeviceId($0) ? $0 : nil } ?? newDeviceId()
            kv.set(deviceId, for: Self.deviceIdKey)
        }
        userId = kv.string(Self.userIdKey)
        purchaserId = kv.string(Self.purchaserIdKey)
        optOut = kv.bool(Self.optOutKey) ?? false
        userProperties = Self.decodeProps(kv.string(Self.userPropsKey))
    }

    func setUserId(_ userId: String?) {
        self.userId = userId
        kv.set(userId, for: Self.userIdKey)
    }

    func setPurchaserId(_ purchaserId: String?) {
        self.purchaserId = purchaserId
        kv.set(purchaserId, for: Self.purchaserIdKey)
    }

    /// Merges `properties` into the snapshot; a `.null` value removes that key.
    func mergeUserProperties(_ properties: JSONObject) {
        var next = userProperties
        for (key, value) in properties {
            next[key] = value == .null ? nil : value
        }
        userProperties = next
        if let data = try? JSONEncoder().encode(next) {
            kv.set(String(decoding: data, as: UTF8.self), for: Self.userPropsKey)
        }
    }

    func setOptOut(_ optOut: Bool) {
        self.optOut = optOut
        kv.set(optOut, for: Self.optOutKey)
    }

    /// New random device id (never the legacy one) and no user, purchaser or
    /// user properties. Opt-out is kept: it is the person's choice, not
    /// identity.
    func reset() {
        deviceId = newDeviceId()
        userId = nil
        purchaserId = nil
        userProperties = [:]
        kv.set(deviceId, for: Self.deviceIdKey)
        kv.set(nil as String?, for: Self.userIdKey)
        kv.set(nil as String?, for: Self.purchaserIdKey)
        kv.set(nil as String?, for: Self.userPropsKey)
    }

    /// A missing or unreadable snapshot loads as empty.
    private static func decodeProps(_ raw: String?) -> JSONObject {
        guard let raw else { return [:] }
        return (try? JSONDecoder().decode(JSONObject.self, from: Data(raw.utf8))) ?? [:]
    }

    private static func isValidDeviceId(_ id: String) -> Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && id.utf16.count <= maxDeviceIdLength
    }
}
