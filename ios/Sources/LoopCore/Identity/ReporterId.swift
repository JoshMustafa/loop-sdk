import Foundation

/// Generates the anonymous `r_<12 lowercase hex>` reporter id we hand out
/// on first launch and pin to the device's Keychain. Format matches the
/// backend's regex (`^r_[a-z0-9]{8,32}$`).
package enum ReporterId {
    static let prefix = "r_"
    static let entropyBytes = 6  // 12 lowercase hex chars

    package static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: entropyBytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return prefix + hex
    }

    package static func looksValid(_ id: String) -> Bool {
        guard id.hasPrefix(prefix) else { return false }
        let rest = id.dropFirst(prefix.count)
        guard rest.count >= 8, rest.count <= 32 else { return false }
        return rest.allSatisfy { ("0"..."9").contains($0) || ("a"..."z").contains($0) }
    }
}
