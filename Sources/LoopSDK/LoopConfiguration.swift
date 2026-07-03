import Foundation

/// Static configuration the host app provides once at launch via
/// `LoopSDK.start(...)`. Values are read-only after construction.
public struct LoopConfiguration: Sendable {
    /// Backend base URL the SDK posts to. Hard-coded here so host apps
    /// don't have to know or care where the Loop server lives — they
    /// just paste their `loop_pk_…` key and they're done.
    ///
    /// Production endpoint on Fly. Override per-test by passing a custom
    /// `apiBase` to `LoopSDK.start(...)` if you need to point at a local
    /// backend during development.
    public static let defaultBaseURL = URL(string: "https://loop-backend.fly.dev")!

    /// Optional. Called by the SDK right before each report is submitted
    /// to read the host app's current subscription / business tier for
    /// that user. Whatever string the closure returns is attached to the
    /// ingest payload under `user.tier`; the dev sees it as a pill on
    /// the dashboard.
    ///
    /// Read-on-submit instead of a sticky setter so the value can never
    /// go stale — if a user downgrades from "paid" to "free" the next
    /// report picks up the new state automatically, no callback the host
    /// has to remember to wire on every subscription event.
    ///
    /// **Defaults to an auto-detector** (`AutoTier.resolve`) that
    /// recognises RevenueCat via the Obj-C runtime when the host links
    /// it. Pass an explicit closure to override, or pass
    /// `tierProvider: nil` *explicitly via `init(..., tierProvider:)`*
    /// to disable tier reporting entirely.
    ///
    /// The closure runs on the SDK's submit task, so the read must be
    /// **cheap and non-blocking** — read a cached property, don't make
    /// a network round-trip.
    public typealias TierProvider = @Sendable () -> String?

    public let apiKey: String
    public let apiBase: URL
    public let tierProvider: TierProvider?

    /// Master switch for the product-analytics ("Retention") subsystem.
    /// When `false`, `LoopSDK.track` / `identify` / `resetIdentity` /
    /// `defineFunnel` and the automatic `app_opened` / `session_start`
    /// events are all no-ops — nothing is buffered and nothing is sent.
    /// Defaults to `true`.
    public let analyticsEnabled: Bool

    /// Default initialiser — uses the built-in auto-detector
    /// (RevenueCat via Obj-C runtime; falls back to nil when nothing
    /// recognises the host's subscription source).
    public init(
        apiKey: String,
        apiBase: URL = LoopConfiguration.defaultBaseURL,
        analyticsEnabled: Bool = true
    ) {
        self.apiKey = apiKey
        self.apiBase = apiBase
        self.tierProvider = { AutoTier.resolve() }
        self.analyticsEnabled = analyticsEnabled
    }

    /// Override initialiser — host supplies its own closure (e.g. a
    /// hand-rolled StoreKit 2 wrapper). Pass `nil` to opt out of
    /// tier reporting entirely.
    public init(
        apiKey: String,
        apiBase: URL = LoopConfiguration.defaultBaseURL,
        tierProvider: TierProvider?,
        analyticsEnabled: Bool = true
    ) {
        self.apiKey = apiKey
        self.apiBase = apiBase
        self.tierProvider = tierProvider
        self.analyticsEnabled = analyticsEnabled
    }

    /// Runs the configured `tierProvider` (if any), trims, and treats
    /// empty / whitespace-only strings as nil. Pure function — exposed
    /// so tests can exercise the normalisation without standing up the
    /// whole SDK runtime.
    public static func resolveTier(from provider: TierProvider?) -> String? {
        guard let raw = provider?() else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
