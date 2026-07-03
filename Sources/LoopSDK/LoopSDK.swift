import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Public entry point. Configure once at app launch:
///
///     LoopSDK.start(apiKey: "loop_pk_…")
///
/// Then drop `LoopReporterView()` inside a sheet from your settings screen,
/// or call `LoopSDK.presentReporter(from:)` from a UIKit host.
public enum LoopSDK {

    // MARK: - Public API

    /// Minimal start — uses the built-in auto-tier detector (RevenueCat
    /// today, more sources later). Recommended for most hosts.
    public static func start(
        apiKey: String,
        apiBase: URL = LoopConfiguration.defaultBaseURL
    ) {
        Runtime.shared.configure(.init(apiKey: apiKey, apiBase: apiBase))
    }

    /// Start with a custom tier provider. Pass `nil` to disable tier
    /// reporting entirely (auto-detect is bypassed).
    public static func start(
        apiKey: String,
        apiBase: URL = LoopConfiguration.defaultBaseURL,
        tierProvider: LoopConfiguration.TierProvider?
    ) {
        Runtime.shared.configure(.init(apiKey: apiKey, apiBase: apiBase, tierProvider: tierProvider))
    }

    public static func start(configuration: LoopConfiguration) {
        Runtime.shared.configure(configuration)
    }

    /// Returns the persisted reporter id (Keychain), generating it on first
    /// call. Useful if the host wants to display "your report id" in its
    /// own UI.
    public static func currentReporterId() -> String {
        Runtime.shared.reporterId
    }

    // MARK: - Automatic diagnostics

    /// Records a breadcrumb into the in-memory ring buffer (last 20 kept).
    /// Cheap and non-blocking; safe to call before `start()`. The buffer is
    /// snapshotted into the next `captureDiagnostic` payload.
    ///
    /// - Parameters:
    ///   - message: Short developer-supplied description of what happened.
    ///   - fail: Mark this crumb as a failure step (default `false`).
    public static func breadcrumb(_ message: String, fail: Bool = false) {
        Runtime.shared.breadcrumb(message, fail: fail)
    }

    /// Captures a diagnostic event and sends it to the Loop backend.
    ///
    /// Fire-and-forget: returns immediately, sends asynchronously, never
    /// throws. Repeat captures of the same `name` arriving faster than the
    /// rate-limit interval are dropped. If the send fails (offline / non-2xx)
    /// the payload is buffered on disk and retried on the next capture.
    ///
    /// No-ops silently if `start()` hasn't been called (no configuration to
    /// authenticate with) — it won't crash the host.
    ///
    /// - Parameters:
    ///   - name: Stable fingerprint that groups occurrences of the same issue.
    ///   - severity: `.info`, `.warning`, or `.error` (default `.error`).
    ///   - title: Optional human-readable title.
    ///   - culprit: Optional location/function blamed for the event.
    ///   - context: Optional developer-supplied key/value strings.
    public static func captureDiagnostic(
        _ name: String,
        severity: Severity = .error,
        title: String? = nil,
        culprit: String? = nil,
        context: [String: String] = [:]
    ) {
        Runtime.shared.captureDiagnostic(
            name,
            severity: severity,
            title: title,
            culprit: culprit,
            context: context
        )
    }

    // MARK: - Product analytics (Retention)

    /// Records a product-analytics event.
    ///
    /// Fire-and-forget and non-blocking: the event is enveloped
    /// (occurredAt, sessionId, userId), buffered on disk, and batched to
    /// the backend (20 events, 15 s, or app-background — whichever comes
    /// first). No-ops before `start()` or when
    /// `LoopConfiguration.analyticsEnabled` is `false`.
    ///
    /// - Parameters:
    ///   - name: Event name — lowercase snake_case, ≤64 chars. Names are
    ///     sanitized ("Set Logged" → `set_logged`); events whose name can't
    ///     be salvaged are dropped.
    ///   - props: Optional scalar properties (String/Int/Double/Bool only,
    ///     ≤16 keys, strings truncated to 256 chars; everything else is
    ///     dropped).
    public static func track(_ name: String, _ props: [String: Any]? = nil) {
        Runtime.shared.track(name, props)
    }

    /// Associates the anonymous reporter id with the host app's own user
    /// id. Attached to all subsequent events (persisted across launches)
    /// until `resetIdentity()`.
    public static func identify(_ userId: String) {
        Runtime.shared.identify(userId)
    }

    /// Clears the identity set by `identify(_:)` — call on sign-out.
    public static func resetIdentity() {
        Runtime.shared.resetIdentity()
    }

    /// Declares a funnel the dashboard should compute. Safe to call on
    /// every launch: declarations are sent once per app run and upserted
    /// idempotently server-side (keyed by `key`).
    ///
    /// - Parameters:
    ///   - key: Stable identifier for the funnel.
    ///   - name: Human-readable name shown on the dashboard.
    ///   - steps: Ordered event names that make up the funnel.
    ///   - windowDays: Completion window in days (default 7).
    ///   - activation: Mark this as the product's activation funnel.
    public static func defineFunnel(
        key: String,
        name: String,
        steps: [String],
        windowDays: Int = 7,
        activation: Bool = false
    ) {
        Runtime.shared.defineFunnel(FunnelDefinition(
            key: key,
            name: name,
            steps: steps,
            windowDays: windowDays,
            activation: activation
        ))
    }

    #if canImport(UIKit)
    /// UIKit convenience: presents `LoopReporterView` modally from the
    /// supplied view controller.
    @MainActor
    public static func presentReporter(from presenter: UIViewController) {
        guard #available(iOS 16.0, *) else { return }
        let controller = UIHostingController(rootView: LoopReporterView())
        presenter.present(controller, animated: true)
    }
    #endif

    // MARK: - Internal accessor used by views

    static func runtime() -> Runtime { .shared }

    /// Singleton that owns the parsed configuration, the reporter id, the
    /// per-launch session id, and the lazily-built `LoopClient`.
    final class Runtime: @unchecked Sendable {
        static let shared = Runtime()

        private let lock = NSLock()
        private var configuration: LoopConfiguration?
        private let store = ReporterStore()

        /// Always-available breadcrumb buffer — usable before `start()`.
        private let breadcrumbs = BreadcrumbBuffer()
        /// On-disk offline buffer for diagnostics that fail to POST.
        private let diagnosticsStore = OfflineBufferStore.makeDefault()
        /// Lazily built once configuration is available; rebuilt is
        /// unnecessary because apiKey/base don't change after start().
        private var diagnosticsEngine: DiagnosticsEngine?

        /// Product-analytics buffer — its own store, fully separate from
        /// the diagnostics buffer (analytics events never mix with
        /// bug-report breadcrumbs).
        private let retentionStore = RetentionEventStore.makeDefault()
        private var retentionEngine: RetentionEngine?
        #if canImport(UIKit) && os(iOS)
        /// Keeps the lifecycle → auto-event subscriptions alive.
        private var retentionLifecycle: RetentionLifecycleObserver?
        #endif
        private(set) lazy var sessionId: String = {
            let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            return "sess_" + String(raw.prefix(12))
        }()
        private(set) lazy var reporterId: String = store.ensureId()

        func configure(_ configuration: LoopConfiguration) {
            lock.lock()
            self.configuration = configuration
            lock.unlock()
            // Built eagerly (not lazily like diagnostics) because the auto
            // events need to observe the app lifecycle from launch, before
            // the host ever calls track().
            startRetentionIfEnabled()
        }

        // MARK: - Diagnostics

        func breadcrumb(_ message: String, fail: Bool) {
            breadcrumbs.record(message: message, fail: fail)
        }

        /// Fire-and-forget. No-ops (apart from breadcrumb retention) when no
        /// configuration is present; otherwise dispatches an async capture
        /// that never throws back to the caller.
        func captureDiagnostic(
            _ name: String,
            severity: Severity,
            title: String?,
            culprit: String?,
            context: [String: String]
        ) {
            guard let engine = diagnosticsEngineIfConfigured() else { return }
            Task.detached {
                try? await engine.capture(
                    name,
                    severity: severity,
                    title: title,
                    culprit: culprit,
                    context: context
                )
            }
        }

        /// Returns the engine, building it on first use, but only if the host
        /// has called `start()`. Returns `nil` (rather than fatal-ing like
        /// `currentConfiguration()`) so diagnostics stay non-fatal.
        // MARK: - Retention (product analytics)

        /// Builds the retention engine + lifecycle observer once, at
        /// `configure` time — auto events must observe the app lifecycle
        /// from launch, before the host ever calls `track()`.
        func startRetentionIfEnabled() {
            lock.lock()
            defer { lock.unlock() }
            guard let configuration, configuration.analyticsEnabled, retentionEngine == nil else {
                return
            }

            let client = LoopClient(
                baseURL: configuration.apiBase,
                apiKey: configuration.apiKey,
                reporterId: reporterId
            )
            let engine = RetentionEngine(
                client: client,
                store: retentionStore,
                persistence: RetentionPersistence()
            )
            retentionEngine = engine
            #if canImport(UIKit) && os(iOS)
            retentionLifecycle = RetentionLifecycleObserver(engine: engine)
            #endif
        }

        func track(_ name: String, _ props: [String: Any]?) {
            guard let engine = retentionEngineIfStarted() else { return }
            let occurredAt = Date()
            let sanitized = RetentionSanitizer.sanitizeProps(props)
            Task.detached {
                await engine.track(name: name, props: sanitized, occurredAt: occurredAt)
            }
        }

        func identify(_ userId: String) {
            guard let engine = retentionEngineIfStarted() else { return }
            Task.detached { await engine.identify(userId) }
        }

        func resetIdentity() {
            guard let engine = retentionEngineIfStarted() else { return }
            Task.detached { await engine.resetIdentity() }
        }

        func defineFunnel(_ funnel: FunnelDefinition) {
            guard let engine = retentionEngineIfStarted() else { return }
            Task.detached { await engine.defineFunnel(funnel) }
        }

        private func retentionEngineIfStarted() -> RetentionEngine? {
            lock.lock(); defer { lock.unlock() }
            return retentionEngine
        }

        private func diagnosticsEngineIfConfigured() -> DiagnosticsEngine? {
            lock.lock(); defer { lock.unlock() }
            guard let configuration else { return nil }
            if let diagnosticsEngine { return diagnosticsEngine }
            let client = LoopClient(
                baseURL: configuration.apiBase,
                apiKey: configuration.apiKey,
                reporterId: reporterId
            )
            let engine = DiagnosticsEngine(
                client: client,
                sessionId: sessionId,
                tierProvider: configuration.tierProvider,
                store: diagnosticsStore,
                buffer: breadcrumbs
            )
            diagnosticsEngine = engine
            return engine
        }

        /// Returns the configured value or fatals if the host forgot to
        /// call `start()` — better to crash loudly during integration than
        /// silently swallow a 401.
        func currentConfiguration() -> LoopConfiguration {
            lock.lock(); defer { lock.unlock() }
            guard let configuration else {
                fatalError("LoopSDK.start(apiKey:) must be called before presenting LoopReporterView")
            }
            return configuration
        }

        #if os(iOS)
        @MainActor
        func makeReporterModel() -> LoopReporterModel {
            let cfg = currentConfiguration()
            let client = LoopClient(
                baseURL: cfg.apiBase,
                apiKey: cfg.apiKey,
                reporterId: reporterId
            )
            return LoopReporterModel(
                client: client,
                reporterId: reporterId,
                sessionId: sessionId,
                tierProvider: cfg.tierProvider
            )
        }
        #endif
    }
}
