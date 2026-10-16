import Foundation

/// Options shared by every Loop module, passed once to `Loop.configure`.
public struct LoopOptions: Sendable {
    /// Read right before a report or diagnostic is sent; the returned string
    /// is attached as `user.tier` and shown as a pill on the dashboard.
    /// Must be cheap and non-blocking — read a cached value, don't make a
    /// network round-trip.
    public typealias TierProvider = @Sendable () -> String?

    /// The Loop backend every module talks to.
    public static let defaultServerURL = URL(string: "https://loop-analytics-api.fly.dev")!

    public let serverUrl: URL
    public let tierProvider: TierProvider?

    /// Uses the built-in tier auto-detector (RevenueCat via the Obj-C runtime).
    public init(serverUrl: URL = LoopOptions.defaultServerURL) {
        self.serverUrl = serverUrl
        self.tierProvider = { AutoTier.resolve() }
    }

    /// Supplies your own tier closure; pass `nil` to turn tier reporting off.
    public init(serverUrl: URL = LoopOptions.defaultServerURL, tierProvider: TierProvider?) {
        self.serverUrl = serverUrl
        self.tierProvider = tierProvider
    }

    /// Runs the provider, trims, and treats empty strings as nil.
    public static func resolveTier(from provider: TierProvider?) -> String? {
        guard let raw = provider?() else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
