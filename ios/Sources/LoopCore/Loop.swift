import Foundation

/// Configure Loop once at app launch, before using any module:
///
///     Loop.configure(apiKey: "loop_pk_…")
///
/// Then use `LoopFeedback`, `LoopDiagnostics` (and `LoopAnalytics`).
public enum Loop {
    public static func configure(apiKey: String, options: LoopOptions = LoopOptions()) {
        LoopRuntime.shared.configure(apiKey: apiKey, options: options)
    }

    /// This device's anonymous reporter id (`r_…`, kept in the Keychain and
    /// generated on first use). Handy for showing "your report id" in-app.
    public static var reporterId: String { LoopRuntime.shared.reporterId }
}

package struct LoopConfigurationSnapshot: Sendable {
    package let apiKey: String
    package let options: LoopOptions
}

/// Shared state every module reads: configuration, reporter id and the
/// per-launch session id.
package final class LoopRuntime: @unchecked Sendable {
    package static let shared = LoopRuntime()

    private let lock = NSLock()
    private var _configuration: LoopConfigurationSnapshot?
    private let store = ReporterStore()
    private var _reporterId: String?
    private var _sessionId: String = LoopRuntime.makeSessionId()

    package var configuration: LoopConfigurationSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return _configuration
    }

    package var reporterId: String {
        lock.lock(); defer { lock.unlock() }
        if let _reporterId { return _reporterId }
        let id = store.ensureId()
        _reporterId = id
        return id
    }

    package var sessionId: String {
        lock.lock(); defer { lock.unlock() }
        return _sessionId
    }

    package func configure(apiKey: String, options: LoopOptions) {
        lock.lock(); defer { lock.unlock() }
        _configuration = LoopConfigurationSnapshot(apiKey: apiKey, options: options)
    }

    /// An authenticated client for the configured server, or nil before
    /// `Loop.configure` has been called.
    package func http(session: URLSession? = nil) -> LoopHTTP? {
        guard let configuration else { return nil }
        return LoopHTTP(baseURL: configuration.options.serverUrl, apiKey: configuration.apiKey,
                        reporterId: reporterId, session: session)
    }

    /// Test hook: forget the configuration and start a new launch session.
    package func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        _configuration = nil
        _sessionId = LoopRuntime.makeSessionId()
    }

    private static func makeSessionId() -> String {
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "sess_" + String(raw.prefix(12))
    }
}
