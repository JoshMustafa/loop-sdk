import Foundation
import LoopCore

/// Breadcrumbs and captured problems, sent to Loop's diagnostics inbox.
/// Safe to call before `Loop.configure`: breadcrumbs are kept, captures are dropped.
public enum LoopDiagnostics {
    /// Records a breadcrumb into the in-memory ring buffer (last 20 kept).
    /// Cheap and non-blocking; snapshotted into the next capture.
    ///
    /// - Parameters:
    ///   - message: Short description of what happened.
    ///   - fail: Mark this crumb as a failure step.
    public static func breadcrumb(_ message: String, fail: Bool = false) {
        DiagnosticsRuntime.shared.breadcrumbs.record(message: message, fail: fail)
    }

    /// Captures a diagnostic and sends it to Loop.
    ///
    /// Fire-and-forget: returns immediately and never throws. Repeat captures
    /// of the same `name` inside the rate-limit window are dropped. If the
    /// send fails (offline / non-2xx) the payload is buffered on disk and
    /// retried on the next capture.
    ///
    /// - Parameters:
    ///   - name: Stable fingerprint that groups occurrences of the same issue.
    ///   - severity: `.info`, `.warning`, or `.error`.
    ///   - title: Optional human-readable title.
    ///   - culprit: Optional location/function blamed for the event.
    ///   - context: Optional key/value strings.
    public static func capture(
        _ name: String,
        severity: Severity = .error,
        title: String? = nil,
        culprit: String? = nil,
        context: [String: String] = [:]
    ) {
        guard let engine = DiagnosticsRuntime.shared.engine() else { return }
        Task.detached {
            try? await engine.capture(name, severity: severity, title: title, culprit: culprit, context: context)
        }
    }
}

/// Owns the breadcrumb buffer, offline store and engine for this module.
final class DiagnosticsRuntime: @unchecked Sendable {
    static let shared = DiagnosticsRuntime()

    let breadcrumbs = BreadcrumbBuffer()
    private let store = OfflineBufferStore.makeDefault()
    private let lock = NSLock()
    private var cached: (configurationVersion: Int, engine: DiagnosticsEngine)?

    /// Built on first use after `Loop.configure`; rebuilt after every
    /// `Loop.configure` so a new key, server or tier provider takes effect.
    func engine() -> DiagnosticsEngine? {
        let runtime = LoopRuntime.shared
        let version = runtime.configurationVersion
        guard let configuration = runtime.configuration, let http = runtime.http() else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let cached, cached.configurationVersion == version {
            return cached.engine
        }
        let engine = DiagnosticsEngine(
            sender: DiagnosticsClient(http: http),
            sessionId: runtime.sessionId,
            tierProvider: configuration.options.tierProvider,
            store: store,
            buffer: breadcrumbs
        )
        cached = (version, engine)
        return engine
    }
}
