import Foundation

/// Owns the product-analytics ("Retention") pipeline: session derivation,
/// event envelopes, batching + flush triggers, funnel declarations, and the
/// offline retry semantics around `POST /api/ingest/track`.
///
/// An actor, unlike the lock-based `DiagnosticsEngine`: the flush path has
/// multiple await points (funnels then events) and actor isolation keeps
/// its bookkeeping (timer task, in-flight guard, session state) coherent
/// without manual lock choreography across suspensions. Sanitization of
/// `[String: Any]` props happens *before* the actor hop (see
/// `RetentionSanitizer`), so only Sendable values cross.
///
/// One engine per SDK runtime; entirely separate from Diagnostics — product
/// analytics events never mix with bug-report breadcrumbs.
actor RetentionEngine {

    /// Buffered-event count that triggers an immediate flush.
    static let flushThreshold = 20
    /// Max wait between the first unflushed event and a timed flush.
    static let flushInterval: TimeInterval = 15
    /// Background gap after which the next event starts a new session.
    static let sessionGap: TimeInterval = 30 * 60

    private let client: LoopClient
    private let store: RetentionEventStore
    private let persistence: RetentionPersistence
    private let appVersion: String

    private var userId: String?
    private var sessionId: String?
    private var lastActivityAt: Date?
    private var isFlushing = false
    private var isForegrounded = false
    private var flushTimer: Task<Void, Never>?
    private var declaredFunnelKeys: Set<String> = []
    private var pendingFunnels: [FunnelDefinition] = []

    init(
        client: LoopClient,
        store: RetentionEventStore,
        persistence: RetentionPersistence,
        appVersion: String = RetentionEngine.hostAppVersion()
    ) {
        self.client = client
        self.store = store
        self.persistence = persistence
        self.appVersion = appVersion
        // Resume identity + session across relaunches: a quick relaunch
        // (< sessionGap since the last event) continues the same session.
        userId = persistence.userId
        sessionId = persistence.sessionId
        lastActivityAt = persistence.lastActivityAt
    }

    // MARK: - Tracking

    /// Sanitizes, envelopes, and buffers one event; synthesizes a
    /// `session_start` first when a new session begins. `occurredAt` is the
    /// moment of the public `track` call (passed in so it survives the
    /// actor hop and so tests can inject a clock).
    func track(
        name rawName: String,
        props: [String: RetentionPropValue]? = nil,
        occurredAt: Date = Date()
    ) async {
        guard let name = RetentionSanitizer.sanitizeName(rawName) else { return }
        let session = resolveSession(at: occurredAt)
        let occurredAtISO = Self.iso8601(occurredAt)
        if session.isNew {
            store.append(RetentionEvent(
                name: "session_start",
                occurredAt: occurredAtISO,
                sessionId: session.id,
                props: [:],
                userId: userId
            ))
        }
        store.append(RetentionEvent(
            name: name,
            occurredAt: occurredAtISO,
            sessionId: session.id,
            props: props ?? [:],
            userId: userId
        ))

        if store.count() >= Self.flushThreshold {
            cancelFlushTimer()
            await flush()
        } else {
            scheduleFlushTimer()
        }
    }

    // MARK: - Identity

    func identify(_ userId: String) {
        self.userId = userId
        persistence.userId = userId
    }

    func resetIdentity() {
        userId = nil
        persistence.userId = nil
    }

    // MARK: - Auto events (driven by RetentionLifecycleObserver)

    /// Records `app_opened` once per foreground stint. Both the
    /// `didBecomeActive` notification and the already-active check at
    /// `start()` funnel through here, so a launch can't double-count.
    func trackAppOpened(at occurredAt: Date = Date()) async {
        guard !isForegrounded else { return }
        isForegrounded = true
        await track(name: "app_opened", occurredAt: occurredAt)
    }

    /// Backgrounding flushes immediately (best effort — events are already
    /// persisted, so a cut-short flush loses nothing).
    func handleDidEnterBackground() async {
        isForegrounded = false
        cancelFlushTimer()
        await flush()
    }

    // MARK: - Funnels

    /// Queues a funnel declaration and sends it. Each key is sent at most
    /// once per app run; the backend upsert makes re-sends across runs
    /// idempotent. Failed sends stay queued and retry on the next flush.
    func defineFunnel(_ funnel: FunnelDefinition) async {
        guard !declaredFunnelKeys.contains(funnel.key) else { return }
        declaredFunnelKeys.insert(funnel.key)
        pendingFunnels.append(funnel)
        await sendPendingFunnels()
    }

    // MARK: - Flushing

    /// Sends any pending funnel declarations, then the whole event buffer
    /// as one batch. Retry semantics: 2xx clears the batch; any 4xx drops
    /// it (poison-pill protection); transport errors and 5xx keep it
    /// buffered for the next flush.
    func flush() async {
        guard !isFlushing else { return } // actor reentrancy guard
        isFlushing = true
        defer { isFlushing = false }

        await sendPendingFunnels()

        let entries = store.snapshot()
        guard !entries.isEmpty else { return }
        let batch = RetentionTrackBatch(
            platform: "ios",
            appVersion: appVersion,
            events: entries.map(\.event)
        )
        guard let body = try? JSONEncoder().encode(batch) else { return }
        do {
            try await client.sendTrackBatch(body: body)
            store.remove(ids: entries.map(\.id))
        } catch {
            if Self.isClientRejection(error) {
                store.remove(ids: entries.map(\.id))
            }
            // Otherwise keep buffered; the next flush retries.
        }
    }

    /// Test/observability hook.
    func bufferedEventCount() -> Int {
        store.count()
    }

    // MARK: - Internals

    private func resolveSession(at occurredAt: Date) -> (id: String, isNew: Bool) {
        if let sessionId,
           let last = lastActivityAt,
           occurredAt.timeIntervalSince(last) < Self.sessionGap {
            let activity = max(last, occurredAt)
            lastActivityAt = activity
            persistence.lastActivityAt = activity
            return (sessionId, false)
        }
        let fresh = UUID().uuidString
        sessionId = fresh
        lastActivityAt = occurredAt
        persistence.sessionId = fresh
        persistence.lastActivityAt = occurredAt
        return (fresh, true)
    }

    private func sendPendingFunnels() async {
        guard !pendingFunnels.isEmpty else { return }
        let batch = pendingFunnels
        guard let body = try? JSONEncoder().encode(RetentionFunnelBatch(funnels: batch)) else {
            pendingFunnels = []
            return
        }
        do {
            try await client.sendFunnels(body: body)
            pendingFunnels = []
        } catch {
            if Self.isClientRejection(error) {
                pendingFunnels = []
            }
            // Otherwise keep queued; retried by the next flush.
        }
    }

    private func scheduleFlushTimer() {
        guard flushTimer == nil else { return }
        flushTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.flushInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.flushTimerFired()
        }
    }

    private func flushTimerFired() async {
        flushTimer = nil
        await flush()
    }

    private func cancelFlushTimer() {
        flushTimer?.cancel()
        flushTimer = nil
    }

    /// A 4xx means the server understood us and said no — retrying the
    /// same batch forever would be a poison pill, so drop it. Transport
    /// failures and 5xx are transient and keep the batch.
    static func isClientRejection(_ error: Error) -> Bool {
        switch error {
        case LoopError.invalidApiKey, LoopError.badRequest, LoopError.notFound:
            return true
        case LoopError.unknown(let status):
            return (400..<500).contains(status)
        default:
            return false
        }
    }

    /// The wire contract wants the bare marketing version, not the
    /// "1.2.3 (45)" composite `DeviceMeta` uses for bug reports.
    static func hostAppVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// ISO-8601 in UTC, whole seconds — matches the frozen wire example
    /// (`2026-07-03T12:00:00Z`).
    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
