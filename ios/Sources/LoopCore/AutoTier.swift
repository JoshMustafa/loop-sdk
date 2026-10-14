import Foundation

/// Best-effort tier auto-detection used when the host hasn't supplied an
/// explicit `tierProvider` to `LoopSDK.start(...)`. Returns `"paid"`,
/// `"free"`, or `nil` (unknown) without taking any subscription SDK as a
/// hard dependency.
///
/// The SDK reaches across to other frameworks via the **Objective-C
/// runtime**, not Swift imports — so this file doesn't `import
/// RevenueCat` (or anything else). If the host links RevenueCat, the
/// `RCPurchases` class is registered at runtime and the lookup
/// succeeds; if not, it returns nil and we move on. Same pattern for
/// any future StoreKit / custom-backend detector we plug in.
///
/// Adding a new detector: implement a function returning `String?`
/// (cheap, non-blocking, nil-on-absence), then append it to
/// `detectors` below.
package enum AutoTier {
    /// Returns the first non-nil detector's result, or nil if none
    /// recognise the host's subscription source.
    package static func resolve() -> String? {
        for detect in detectors {
            if let tier = detect() {
                return tier
            }
        }
        return nil
    }

    // Detectors in priority order. RevenueCat first because it's the
    // most common third-party subscription SDK for iOS.
    private static let detectors: [() -> String?] = [
        detectRevenueCat
        // Future: detectStoreKit2, detectAdapty, etc.
    ]

    // MARK: - RevenueCat

    /// Looks up RevenueCat's `RCPurchases.sharedPurchases.cachedCustomerInfo.entitlements.active`
    /// via Obj-C runtime. RevenueCat's public API is `@objc`-exposed
    /// (the framework supports Obj-C-only apps), so KVC and selector
    /// dispatch both work against it.
    ///
    /// Returns:
    ///   * `"paid"` — at least one active entitlement
    ///   * `"free"` — RevenueCat present, configured, no active
    ///     entitlement
    ///   * `nil`    — RevenueCat isn't linked, or `Purchases.configure`
    ///     hasn't been called yet (don't pretend to know)
    private static func detectRevenueCat() -> String? {
        guard let purchasesClass = NSClassFromString("RCPurchases") as? NSObject.Type else {
            return nil
        }

        let sharedSel = NSSelectorFromString("sharedPurchases")
        guard purchasesClass.responds(to: sharedSel) else { return nil }
        guard let shared =
                purchasesClass.perform(sharedSel)?.takeUnretainedValue() as? NSObject
        else { return nil }

        // Cached info — synchronous, no network. Nil before first
        // fetch; in that case we can't claim "free" honestly.
        let cachedSel = NSSelectorFromString("cachedCustomerInfo")
        guard let customerInfo =
                shared.perform(cachedSel)?.takeUnretainedValue() as? NSObject
        else { return nil }

        let entitlementsSel = NSSelectorFromString("entitlements")
        guard let entitlements =
                customerInfo.perform(entitlementsSel)?.takeUnretainedValue() as? NSObject
        else { return "free" }

        let activeSel = NSSelectorFromString("active")
        guard let active =
                entitlements.perform(activeSel)?.takeUnretainedValue() as? [AnyHashable: Any]
        else { return "free" }

        return active.isEmpty ? "free" : "paid"
    }
}
