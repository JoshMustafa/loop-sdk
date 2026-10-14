import Foundation

/// Severity of a captured diagnostic event.
public enum Severity: String, Sendable {
    case info
    case warning
    case error
}

/// Owns the breadcrumb ring buffer and the capture pipeline: payload
/// assembly, per-fingerprint rate limiting, the POST to `/api/ingest/events`,
/// and the offline buffer + retry. One engine per SDK runtime.
///
/// Concurrency follows the package convention: a plain class guarded by an
/// `NSLock` and marked `@unchecked Sendable` — no actors. The actual network
/// call goes through `LoopClient` (an actor), but the engine's own mutable
/// state (rate-limit clock) is lock-protected.
final class DiagnosticsEngine: @unchecked Sendable {

    /// Minimum gap between accepted captures of the *same* fingerprint.
    /// Repeat captures arriving faster than this are dropped.
    static let rateLimitInterval: TimeInterval = 2.0

    private let client: LoopClient
    private let sessionId: String
    private let tierProvider: LoopConfiguration.TierProvider?
    private let store: OfflineBufferStore
    private let buffer: BreadcrumbBuffer

    private let lock = NSLock()
    private var lastCaptureByFingerprint: [String: Date] = [:]

    init(
        client: LoopClient,
        sessionId: String,
        tierProvider: LoopConfiguration.TierProvider?,
        store: OfflineBufferStore,
        buffer: BreadcrumbBuffer = BreadcrumbBuffer()
    ) {
        self.client = client
        self.sessionId = sessionId
        self.tierProvider = tierProvider
        self.store = store
        self.buffer = buffer
    }

    // MARK: - Breadcrumbs

    func breadcrumb(_ message: String, fail: Bool) {
        buffer.record(message: message, fail: fail)
    }

    // MARK: - Capture

    /// Async, throwing core used by tests. The public fire-and-forget entry
    /// point (`LoopSDK.captureDiagnostic`) wraps this in a detached Task and
    /// swallows errors.
    func capture(
        _ name: String,
        severity: Severity = .error,
        title: String? = nil,
        culprit: String? = nil,
        context: [String: String] = [:]
    ) async throws {
        let now = Date()

        // Rate-limit per fingerprint.
        if !shouldAccept(fingerprint: name, at: now) {
            return
        }

        let payload = buildPayload(
            name: name,
            severity: severity,
            title: title,
            culprit: culprit,
            context: context,
            occurredAt: now
        )

        // Best-effort flush of anything previously buffered, then send this
        // one. If this send fails, buffer it for the next attempt.
        await flushPending()

        do {
            try await client.sendDiagnostic(body: payload)
        } catch {
            store.enqueue(payload)
        }
    }

    /// Drains the offline buffer and tries to re-send each payload. Any that
    /// fail again are re-enqueued. Safe to call repeatedly.
    func flushPending() async {
        let pending = store.drain()
        for data in pending {
            do {
                try await client.sendDiagnostic(body: data)
            } catch {
                store.enqueue(data)
            }
        }
    }

    // MARK: - Internals

    private func shouldAccept(fingerprint: String, at now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let last = lastCaptureByFingerprint[fingerprint],
           now.timeIntervalSince(last) < Self.rateLimitInterval {
            return false
        }
        lastCaptureByFingerprint[fingerprint] = now
        return true
    }

    /// Assembles the snake_case ingest payload as serialized JSON `Data`.
    /// Uses `JSONSerialization` because `context` and `breadcrumbs` are
    /// arbitrary developer-supplied maps/arrays.
    func buildPayload(
        name: String,
        severity: Severity,
        title: String?,
        culprit: String?,
        context: [String: String],
        occurredAt: Date
    ) -> Data {
        let crumbs = buffer.snapshot().map { BreadcrumbFormatter.render($0, relativeTo: occurredAt) }
        let meta = DeviceMeta.capture(sessionId: sessionId)
        let tierValue: Any = LoopConfiguration.resolveTier(from: tierProvider) ?? NSNull()

        var dict: [String: Any] = [
            "fingerprint": name,
            "severity": severity.rawValue,
            "occurred_at": Self.iso8601Millis(occurredAt),
            "context": context,
            "breadcrumbs": crumbs,
            "device_meta": [
                "device": meta.device,
                "os": meta.os,
                "appVersion": meta.appVersion,
                "locale": meta.locale,
                "network": meta.network,
                "sessionId": meta.sessionId
            ],
            "user": ["tier": tierValue]
        ]
        if let title { dict["title"] = title }
        if let culprit { dict["culprit"] = culprit }

        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
    }

    /// ISO-8601 in UTC with millisecond precision, e.g.
    /// `2026-06-13T16:42:08.412Z`.
    static func iso8601Millis(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
