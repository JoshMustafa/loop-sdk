import Foundation
import Security

/// Persists the device's anonymous reporter id in Keychain.
///
/// Single key per device (not synced across iCloud), readable after the
/// device's first unlock. We deliberately use a class-level lock around
/// `SecItem*` calls because the underlying APIs are global state and we
/// don't want a torn read on first launch.
package final class ReporterStore: @unchecked Sendable {
    /// Default service identifier for the Keychain entry.
    package static let defaultService = "io.loop.sdk"
    package static let defaultAccount = "reporter_id"

    private let service: String
    private let account: String
    private let lock = NSLock()

    package init(service: String = ReporterStore.defaultService,
                account: String = ReporterStore.defaultAccount) {
        self.service = service
        self.account = account
    }

    /// Returns the persisted id, generating + storing one on first call.
    package func ensureId() -> String {
        lock.lock()
        defer { lock.unlock() }

        if let existing = readUnlocked(), ReporterId.looksValid(existing) {
            return existing
        }

        let fresh = ReporterId.generate()
        // Best-effort write. If Keychain is genuinely unavailable (extremely
        // rare) we still hand the caller a usable id for this launch.
        _ = writeUnlocked(fresh)
        return fresh
    }

    /// Test-only / reset support. Removes the persisted id.
    package func reset() {
        lock.lock()
        defer { lock.unlock() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Private

    private func readUnlocked() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private func writeUnlocked(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        // Try update first; if no row exists, fall through to add.
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        var addQuery = baseQuery
        for (k, v) in attributes { addQuery[k] = v }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }
}
