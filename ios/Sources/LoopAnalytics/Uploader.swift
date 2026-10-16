import Foundation
import LoopCore

/// Sends one HTTP request. Returns the status code, the response headers with
/// lower-cased names, and the body. Throws on network errors and timeouts.
protocol AnalyticsTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Int, [String: String], Data)
}

/// The production transport over `URLSession`, with a 30 s request timeout.
struct URLSessionTransport: AnalyticsTransport {
    static let requestTimeout: TimeInterval = 30

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = Self.requestTimeout
            // Caps the whole request, not just idle time between packets.
            config.timeoutIntervalForResource = Self.requestTimeout
            self.session = URLSession(configuration: config)
        }
    }

    func send(_ request: URLRequest) async throws -> (Int, [String: String], Data) {
        var request = request
        request.timeoutInterval = Self.requestTimeout
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            guard let name = name as? String else { continue }
            headers[name.lowercased()] = value as? String ?? "\(value)"
        }
        return (http.statusCode, headers, data)
    }
}

/// Sends queued events to `POST /api/ingest/analytics/batch`.
///
/// * A batch is the oldest ≤ batch-limit events (also kept under
///   `maxBodyBytes` of JSON), gzip-compressed. One upload runs at a time;
///   `flush()` drains the queue batch by batch.
/// * 2xx → the batch is removed from the store.
/// * 413 → the batch is halved and retried at once; a single event that is
///   still too large is dropped.
/// * 401/403 → a wrong or missing API key: the events stay queued and
///   uploads pause for an hour (or the server's `Retry-After`).
/// * Other 4xx → the batch is dropped (it would never succeed).
/// * 429, 5xx, network errors and timeouts → the events stay queued and
///   uploads pause with exponential backoff (30 s doubling to 10 min, or the
///   server's `Retry-After`), reset by the next success.
/// * A failed batch is remembered and retried as the identical event set so
///   server-side dedup makes a resend harmless.
///
/// All time comes from the injected `LoopClock`.
actor Uploader {
    static let endpointPath = "api/ingest/analytics/batch"

    /// The server rejects bodies over 1 MB decompressed; leave headroom for
    /// the envelope and context.
    static let defaultMaxBodyBytes = 900 * 1024
    static let initialBackoffMillis: Int64 = 30_000
    static let maxBackoffMillis: Int64 = 600_000
    /// Fixed pause after 401/403 (bad or missing API key).
    static let authBackoffMillis: Int64 = 3_600_000
    /// Upper bound on how long a `Retry-After` can pause uploads.
    static let maxRetryAfterMillis: Int64 = 3_600_000
    /// How long one request may take before it counts as a network error.
    static let defaultRequestTimeout: Duration = .seconds(30)

    private let store: EventStore
    private let transport: AnalyticsTransport
    private let endpoint: URL
    private let apiKey: String
    private let context: @Sendable () async -> JSONObject
    private let maxBatchSize: Int
    private let maxBodyBytes: Int
    private let clock: LoopClock
    private let isEnabled: @Sendable () async -> Bool
    private let requestTimeout: Duration
    private let encoder = JSONEncoder()

    private var batchLimit: Int
    /// The batch that failed last and must be retried unchanged.
    private var pending: [LoopEvent]?
    private var failures = 0
    /// When uploads may resume after a failure, in ms since epoch; nil when
    /// not backing off.
    private(set) var nextAttemptAt: Int64?
    private var inFlight: Task<Void, Never>?

    init(
        store: EventStore,
        transport: AnalyticsTransport,
        serverUrl: URL,
        apiKey: String,
        context: @escaping @Sendable () async -> JSONObject,
        maxBatchSize: Int,
        maxBodyBytes: Int = Uploader.defaultMaxBodyBytes,
        clock: LoopClock,
        isEnabled: @escaping @Sendable () async -> Bool = { true },
        requestTimeout: Duration = Uploader.defaultRequestTimeout
    ) {
        self.store = store
        self.transport = transport
        self.endpoint = serverUrl.appendingPathComponent(Self.endpointPath)
        self.apiKey = apiKey
        self.context = context
        self.maxBatchSize = max(1, maxBatchSize)
        self.maxBodyBytes = maxBodyBytes
        self.clock = clock
        self.isEnabled = isEnabled
        self.requestTimeout = requestTimeout
        self.batchLimit = max(1, maxBatchSize)
    }

    var isUploading: Bool { inFlight != nil }

    var isBackingOff: Bool {
        guard let nextAttemptAt else { return false }
        return clock.nowMillis() < nextAttemptAt
    }

    /// Uploads queued events until the queue is empty, a retryable failure
    /// occurs, or uploads are disabled. Joins the running upload if there is
    /// one. Never throws.
    func flush() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { await self.drain() }
        inFlight = task
        await task.value
    }

    /// Waits for the upload in flight, if any, without starting one.
    func waitForInFlight() async {
        await inFlight?.value
    }

    /// Fixes the next batch now, from the store as it is, unless one is
    /// already pending or uploads are disabled. The next upload sends exactly
    /// this batch, whatever is added meanwhile; at startup that keeps a batch
    /// resent after a kill identical, so server-side dedup still applies.
    func primePendingBatch() async {
        guard pending == nil, await isEnabled() else { return }
        _ = await takeNextBatch()
    }

    private func drain() async {
        while await isEnabled(), !isBackingOff {
            let batch: [LoopEvent]
            if let pending {
                batch = pending
            } else {
                guard let next = await takeNextBatch() else { break }
                batch = next
            }
            if !(await upload(batch)) { break }
        }
        if await store.count == 0 { batchLimit = maxBatchSize }
        inFlight = nil
    }

    /// The oldest queued events that fit one batch, remembered as `pending`
    /// until acknowledged; nil when the queue is empty or uploads are
    /// disabled.
    private func takeNextBatch() async -> [LoopEvent]? {
        let events = await store.peek(batchLimit)
        guard !events.isEmpty, await isEnabled() else { return nil }
        let batch = fitToBodyLimit(Self.sameContextPrefix(events))
        pending = batch
        return batch
    }

    /// Sends one batch and applies the outcome. Returns whether draining
    /// should continue right away.
    private func upload(_ batch: [LoopEvent]) async -> Bool {
        let status: Int
        let headers: [String: String]
        do {
            let request = try await request(for: batch)
            (status, headers, _) = try await Self.send(request, via: transport, timeout: requestTimeout)
        } catch {
            scheduleRetry(retryAfter: nil)
            return false
        }

        if (200..<300).contains(status) {
            await store.remove(ids: Self.ids(batch))
            pending = nil
            failures = 0
            nextAttemptAt = nil
            return true
        }
        if status == 413 {
            if batch.count == 1 {
                // Still too large on its own: drop it.
                Log.analytics.warning("Dropped an event the server rejected as too large (HTTP 413)")
                await store.remove(ids: Self.ids(batch))
                pending = nil
                batchLimit = maxBatchSize
            } else {
                let half = batch.count / 2
                pending = Array(batch.prefix(half))
                batchLimit = half
            }
            return true
        }
        if status == 401 || status == 403 {
            // A wrong or not-yet-configured key: keep the events until it's fixed.
            Log.analytics.error("Analytics upload refused (HTTP \(status)): check the Loop API key. Events stay queued; retrying later")
            scheduleRetry(retryAfter: retryAfter(headers), backoff: Self.authBackoffMillis)
            return false
        }
        // 1xx/3xx are unexpected here; treat them like a transient failure.
        if status == 429 || status >= 500 || status < 400 {
            scheduleRetry(retryAfter: retryAfter(headers))
            return false
        }
        // Any other 4xx would never succeed.
        Log.analytics.error("Dropped \(batch.count) event(s) the server rejected (HTTP \(status))")
        await store.remove(ids: Self.ids(batch))
        pending = nil
        return true
    }

    /// `transport.send(request)`, or `URLError(.timedOut)` once `timeout`
    /// passes. The loser is cancelled, but nothing waits for it, so a
    /// transport that ignores cancellation cannot hold up the uploader.
    private static func send(
        _ request: URLRequest,
        via transport: AnalyticsTransport,
        timeout: Duration
    ) async throws -> (Int, [String: String], Data) {
        try await withCheckedThrowingContinuation { continuation in
            let race = Race(continuation)
            race.add(Task {
                do {
                    race.finish(.success(try await transport.send(request)))
                } catch {
                    race.finish(.failure(error))
                }
            })
            race.add(Task {
                // A cancelled sleep means the request already finished.
                guard (try? await Task.sleep(for: timeout)) != nil else { return }
                race.finish(.failure(URLError(.timedOut)))
            })
        }
    }

    /// Resumes a continuation exactly once, with whichever side finishes
    /// first, then cancels every task in the race.
    private final class Race: @unchecked Sendable {
        typealias Reply = (Int, [String: String], Data)

        private let lock = NSLock()
        private var continuation: CheckedContinuation<Reply, Error>?
        private var tasks: [Task<Void, Never>] = []

        init(_ continuation: CheckedContinuation<Reply, Error>) {
            self.continuation = continuation
        }

        /// Adds a racer; cancels it at once if the race is already over.
        func add(_ task: Task<Void, Never>) {
            lock.lock()
            let over = continuation == nil
            if !over { tasks.append(task) }
            lock.unlock()
            if over { task.cancel() }
        }

        func finish(_ result: Result<Reply, Error>) {
            lock.lock()
            let winner = continuation
            continuation = nil
            let losers = tasks
            tasks = []
            lock.unlock()
            guard let winner else { return }
            winner.resume(with: result)
            for task in losers { task.cancel() }
        }
    }

    private struct Body: Encodable {
        let sentAt: String
        let context: JSONObject
        let events: [JSONObject]
    }

    private func request(for batch: [LoopEvent]) async throws -> URLRequest {
        let batchContext: JSONObject
        if let snapshot = batch.first?.context {
            batchContext = snapshot
        } else {
            batchContext = await context()
        }
        let body = Body(
            sentAt: LoopTimestamp.format(millis: clock.nowMillis()),
            context: batchContext,
            events: batch.map { $0.wireJSON() }
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        request.httpBody = try Gzip.compress(try encoder.encode(body))
        return request
    }

    /// The leading run of `events` whose context snapshots are equal, so each
    /// batch is sent with the context its events were tracked under.
    private static func sameContextPrefix(_ events: [LoopEvent]) -> [LoopEvent] {
        guard let first = events.first else { return events }
        var count = 1
        while count < events.count, events[count].context == first.context {
            count += 1
        }
        return Array(events.prefix(count))
    }

    /// The leading events whose wire JSON (plus one byte each) fits in
    /// `maxBodyBytes`; always at least one event.
    private func fitToBodyLimit(_ events: [LoopEvent]) -> [LoopEvent] {
        var bytes = 0
        var count = 0
        for event in events {
            bytes += ((try? encoder.encode(event.wireJSON()))?.count ?? 0) + 1
            if count > 0 && bytes > maxBodyBytes { break }
            count += 1
        }
        return Array(events.prefix(count))
    }

    private func scheduleRetry(retryAfter: Int64?, backoff: Int64? = nil) {
        failures += 1
        let exponential = Self.initialBackoffMillis << Int64(min(failures - 1, 10))
        var delay = retryAfter ?? backoff ?? min(exponential, Self.maxBackoffMillis)
        delay = min(delay, Self.maxRetryAfterMillis)
        delay = max(delay, 0)
        nextAttemptAt = clock.nowMillis() + delay
    }

    /// The `Retry-After` delay in ms (delta-seconds or an HTTP date), or nil
    /// when absent or unparseable.
    private func retryAfter(_ headers: [String: String]) -> Int64? {
        guard let raw = headers.first(where: { $0.key.lowercased() == "retry-after" })?.value else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        if let seconds = Int64(value) {
            // Clamped first so a huge value cannot overflow the conversion.
            return min(max(seconds, 0), Self.maxRetryAfterMillis / 1000) * 1000
        }
        guard let date = Self.httpDateFormatter.date(from: value) else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded()) - clock.nowMillis()
    }

    /// RFC 7231 IMF-fixdate, e.g. `Wed, 14 Oct 2026 09:03:00 GMT`.
    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    private static func ids(_ batch: [LoopEvent]) -> Set<String> {
        Set(batch.map(\.id))
    }
}
