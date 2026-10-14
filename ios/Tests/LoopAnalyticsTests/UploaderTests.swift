import XCTest
import LoopCore
import LoopTestSupport
@testable import LoopAnalytics

/// A request as the server would see it: the gzip-decoded JSON body.
struct Sent: Sendable {
    let request: URLRequest
    let body: JSONObject

    init(_ request: URLRequest) throws {
        self.request = request
        let json = try Gzip.decompress(request.httpBody ?? Data())
        self.body = try JSONDecoder().decode(JSONObject.self, from: json)
    }

    var events: [JSONObject] {
        guard case .array(let events)? = body["events"] else { return [] }
        return events.compactMap { if case .object(let e) = $0 { return e } else { return nil } }
    }

    var ids: [String] {
        events.compactMap { if case .string(let id)? = $0["id"] { return id } else { return nil } }
    }
}

typealias Reply = (Int, [String: String], Data)

func reply(_ status: Int, _ body: String = "{}", headers: [String: String] = [:]) -> Reply {
    (status, headers, Data(body.utf8))
}

/// Records every request and answers with `respond(sent, index)`, where
/// `index` is the number of earlier requests.
actor FakeTransport: AnalyticsTransport {
    private(set) var sent: [Sent] = []
    private(set) var maxInFlight = 0
    private var inFlight = 0
    private var delayNanos: UInt64 = 0
    private var respond: @Sendable (Sent, Int) async throws -> Reply = { _, _ in
        reply(202, #"{"accepted":1,"dropped":0}"#)
    }

    func setRespond(_ respond: @escaping @Sendable (Sent, Int) async throws -> Reply) {
        self.respond = respond
    }

    func setDelay(nanoseconds: UInt64) { delayNanos = nanoseconds }

    func send(_ request: URLRequest) async throws -> (Int, [String: String], Data) {
        let s = try Sent(request)
        let index = sent.count
        sent.append(s)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        if delayNanos > 0 { try await Task.sleep(nanoseconds: delayNanos) }
        return try await respond(s, index)
    }
}

/// A transport whose requests never return and ignore cancellation.
actor HangingTransport: AnalyticsTransport {
    private var hung: [CheckedContinuation<Reply, Never>] = []
    var calls: Int { hung.count }

    func send(_ request: URLRequest) async throws -> (Int, [String: String], Data) {
        await withCheckedContinuation { hung.append($0) }
    }

    /// Lets the hung requests finish so the test leaves nothing suspended.
    func release() {
        for continuation in hung { continuation.resume(returning: reply(202)) }
        hung = []
    }
}

final class Toggle: @unchecked Sendable {
    var on = true
}

final class UploaderTests: XCTestCase {
    private static let start: Int64 = 1_791_968_400_000 // 2026-10-14T09:00:00.000Z
    private let second: Int64 = 1000
    private let minute: Int64 = 60_000
    private let hour: Int64 = 3_600_000
    private let currentContext: JSONObject = ["platform": .string("ios")]

    private var clock = FakeClock(start)
    private var transport = FakeTransport()
    private var store: EventStore!
    private var enabled = Toggle()
    private var dir: URL?

    override func setUp() async throws {
        clock = FakeClock(Self.start)
        transport = FakeTransport()
        store = await EventStore(fileURL: nil, maxQueueSize: 1000)
        enabled = Toggle()
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func uploader(
        maxBatchSize: Int = 100,
        maxBodyBytes: Int = 900_000,
        serverUrl: String = "https://loop.test"
    ) -> Uploader {
        let context = currentContext
        let enabled = enabled
        return Uploader(
            store: store,
            transport: transport,
            serverUrl: URL(string: serverUrl)!,
            apiKey: "loop_pk_test",
            context: { context },
            maxBatchSize: maxBatchSize,
            maxBodyBytes: maxBodyBytes,
            clock: clock,
            isEnabled: { enabled.on }
        )
    }

    private func addEvents(_ n: Int, prefix: String = "e") async {
        for i in 0..<n { await store.add(.sample(id: "\(prefix)\(i)")) }
    }

    private func respond(_ respond: @escaping @Sendable (Sent, Int) async throws -> Reply) async {
        await transport.setRespond(respond)
    }

    private func respond(_ status: Int, _ body: String = "{}", headers: [String: String] = [:]) async {
        await transport.setRespond { _, _ in reply(status, body, headers: headers) }
    }

    private func sent() async -> [Sent] { await transport.sent }

    private func fileBackedStore(maxQueueSize: Int = 1000) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loop_uploader_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dir = dir
        let file = dir.appendingPathComponent("events.jsonl")
        store = await EventStore(fileURL: file, maxQueueSize: maxQueueSize)
        return file
    }

    // MARK: - Basics

    func test_posts_a_gzip_JSON_batch_with_auth_headers_and_removes_it_on_202() async throws {
        let file = try await fileBackedStore()
        await addEvents(2)
        await uploader().flush()

        let sent = await sent()
        XCTAssertEqual(sent.count, 1)
        let req = sent[0].request
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "https://loop.test/api/ingest/analytics/batch")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer loop_pk_test")
        XCTAssertTrue(req.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        XCTAssertEqual(sent[0].body["sentAt"], .string("2026-10-14T09:00:00.000Z"))
        XCTAssertEqual(sent[0].body["context"], .object(currentContext))
        XCTAssertEqual(sent[0].ids, ["e0", "e1"])
        XCTAssertEqual(sent[0].events[0], LoopEvent.sample(id: "e0").wireJSON())
        let count = await store.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(try Data(contentsOf: file), Data())
    }

    func test_sentAt_comes_from_the_injected_clock() async {
        await addEvents(1)
        clock.now = Self.start + 1234
        await uploader().flush()
        let sent = await sent()
        XCTAssertEqual(sent.first?.body["sentAt"], .string("2026-10-14T09:00:01.234Z"))
    }

    func test_nothing_queued_means_no_request() async {
        await uploader().flush()
        let sent = await sent()
        XCTAssertTrue(sent.isEmpty)
    }

    func test_events_are_on_disk_before_they_are_sent() async throws {
        let file = try await fileBackedStore()
        await addEvents(1)
        await respond { _, _ in
            let contents = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            return contents.contains(#""e0""#) ? reply(202) : reply(500)
        }
        await uploader().flush()
        let sent = await sent()
        XCTAssertEqual(sent.count, 1)
        let count = await store.count
        XCTAssertEqual(count, 0, "the event was on disk when the request went out")
    }

    func test_splits_the_queue_into_batches_of_maxBatchSize_oldest_first() async {
        await addEvents(250)
        await uploader().flush()
        let sent = await sent()
        XCTAssertEqual(sent.map(\.events.count), [100, 100, 50])
        XCTAssertEqual(sent.first?.ids.first, "e0")
        XCTAssertEqual(sent.last?.ids.last, "e249")
        let count = await store.count
        XCTAssertEqual(count, 0)
    }

    func test_also_splits_by_encoded_size_to_stay_under_the_body_limit() async {
        for i in 0..<10 {
            await store.add(.sample(id: "big\(i)", props: ["blob": .string(String(repeating: "x", count: 1000))]))
        }
        await uploader(maxBodyBytes: 3500).flush()
        let sent = await sent()
        XCTAssertTrue(sent.allSatisfy { $0.events.count <= 3 }, "\(sent.map(\.events.count))")
        XCTAssertEqual(sent.flatMap(\.ids).count, 10)
    }

    func test_a_single_event_over_the_body_limit_is_still_sent_alone() async {
        await store.add(.sample(id: "huge", props: ["blob": .string(String(repeating: "x", count: 5000))]))
        await store.add(.sample(id: "small"))
        await uploader(maxBodyBytes: 3500).flush()
        let sent = await sent()
        XCTAssertEqual(sent.map(\.ids), [["huge"], ["small"]])
    }

    func test_production_defaults() {
        XCTAssertEqual(Uploader.defaultMaxBodyBytes, 900 * 1024)
        XCTAssertEqual(Uploader.initialBackoffMillis, 30_000)
        XCTAssertEqual(Uploader.maxBackoffMillis, 600_000)
        XCTAssertEqual(Uploader.authBackoffMillis, 3_600_000)
        XCTAssertEqual(Uploader.maxRetryAfterMillis, 3_600_000)
        XCTAssertEqual(Uploader.endpointPath, "api/ingest/analytics/batch")
        XCTAssertEqual(URLSessionTransport.requestTimeout, 30)
        XCTAssertEqual(Uploader.defaultRequestTimeout, .seconds(30))
    }

    // MARK: - 413

    func test_413_halves_the_batch_until_it_fits_then_sends_the_rest() async {
        await addEvents(100)
        await respond { s, _ in
            s.events.count > 25 ? reply(413, #"{"error":"too large"}"#) : reply(202)
        }
        await uploader().flush()
        let sent = await sent()
        XCTAssertEqual(sent.map(\.events.count), [100, 50, 25, 25, 25, 25])
        XCTAssertEqual(sent[1].ids, Array(sent[0].ids.prefix(50)))
        let count = await store.count
        XCTAssertEqual(count, 0)
    }

    func test_413_drops_a_single_event_that_is_still_too_large() async {
        await addEvents(3)
        await respond { s, _ in
            s.ids.contains("e0") ? reply(413, #"{"error":"too large"}"#) : reply(202)
        }
        await uploader().flush()
        let sent = await sent()
        XCTAssertEqual(sent.map(\.events.count), [3, 1, 2])
        XCTAssertEqual(sent.last?.ids, ["e1", "e2"])
        let count = await store.count
        XCTAssertEqual(count, 0)
    }

    // MARK: - Other 4xx

    func test_other_4xx_drops_the_batch_and_carries_on() async {
        for status in [400, 404, 409, 422] {
            transport = FakeTransport()
            store = await EventStore(fileURL: nil, maxQueueSize: 1000)
            await addEvents(150)
            await respond { _, index in
                index == 0 ? reply(status, #"{"error":"bad"}"#) : reply(202)
            }
            let up = uploader()
            await up.flush()
            let sent = await sent()
            XCTAssertEqual(sent.map(\.events.count), [100, 50], "HTTP \(status)")
            let count = await store.count
            XCTAssertEqual(count, 0, "HTTP \(status)")
            let next = await up.nextAttemptAt
            XCTAssertNil(next, "HTTP \(status)")
        }
    }

    // MARK: - 401/403 (bad or missing key)

    func test_401_and_403_keep_the_events_and_back_off_for_an_hour() async {
        for status in [401, 403] {
            clock = FakeClock(Self.start)
            transport = FakeTransport()
            store = await EventStore(fileURL: nil, maxQueueSize: 1000)
            await addEvents(3)
            let up = uploader()
            await respond(status, #"{"error":"invalid api key"}"#)

            await up.flush()
            var sent = await sent()
            XCTAssertEqual(sent.count, 1, "HTTP \(status)")
            var count = await store.count
            XCTAssertEqual(count, 3, "HTTP \(status)")
            var next = await up.nextAttemptAt
            XCTAssertEqual(next, clock.now + hour, "HTTP \(status)")
            var backingOff = await up.isBackingOff
            XCTAssertTrue(backingOff, "HTTP \(status)")

            clock.now += 59 * minute
            await up.flush()
            sent = await self.sent()
            XCTAssertEqual(sent.count, 1, "HTTP \(status)")

            clock.now += minute
            await up.flush()
            sent = await self.sent()
            XCTAssertEqual(sent.count, 2, "HTTP \(status)")
            XCTAssertEqual(sent[1].ids, sent[0].ids, "identical retry, HTTP \(status)")
            next = await up.nextAttemptAt
            XCTAssertEqual(next, clock.now + hour, "no growth, HTTP \(status)")

            clock.now += hour
            await respond(202)
            await up.flush()
            count = await store.count
            XCTAssertEqual(count, 0, "HTTP \(status)")
            next = await up.nextAttemptAt
            XCTAssertNil(next, "HTTP \(status)")
            backingOff = await up.isBackingOff
            XCTAssertFalse(backingOff, "HTTP \(status)")
        }
    }

    func test_401_honours_Retry_After() async {
        await addEvents(1)
        let up = uploader()
        await respond(401, "", headers: ["retry-after": "300"])
        await up.flush()
        let next = await up.nextAttemptAt
        XCTAssertEqual(next, clock.now + 5 * minute)
    }

    func test_the_queue_cap_still_applies_while_the_key_is_wrong() async {
        store = await EventStore(fileURL: nil, maxQueueSize: 5)
        await addEvents(4)
        let up = uploader()
        await respond(401, "")
        await up.flush()
        await addEvents(10, prefix: "more")
        let count = await store.count
        XCTAssertLessThanOrEqual(count, 5)
        let last = await store.peek(Int.max).last?.id
        XCTAssertEqual(last, "more9")
    }

    // MARK: - Per-event context

    private let a: JSONObject = ["platform": .string("ios"), "appVersion": .string("5.2.0 (812)")]
    private let b: JSONObject = ["platform": .string("ios"), "appVersion": .string("5.3.0 (820)")]

    func test_a_batch_only_holds_consecutive_events_with_the_same_context_sent_as_the_batch_context() async {
        await store.add(.sample(id: "1", context: a))
        await store.add(.sample(id: "2", context: a.merging([:]) { x, _ in x }))
        await store.add(.sample(id: "3", context: b))
        await store.add(.sample(id: "4", context: b))
        await store.add(.sample(id: "5", context: a))
        await uploader().flush()
        let sent = await sent()
        XCTAssertEqual(sent.map(\.ids), [["1", "2"], ["3", "4"], ["5"]])
        XCTAssertEqual(sent.map { $0.body["context"] }, [.object(a), .object(b), .object(a)])
        let count = await store.count
        XCTAssertEqual(count, 0)
    }

    func test_events_without_a_snapshot_use_the_current_context() async {
        await store.add(.sample(id: "old"))
        await store.add(.sample(id: "new", context: a))
        await uploader().flush()
        let sent = await sent()
        XCTAssertEqual(sent.map { $0.body["context"] }, [.object(currentContext), .object(a)])
    }

    func test_a_retried_context_batch_is_identical() async {
        await store.add(.sample(id: "1", context: a))
        await store.add(.sample(id: "2", context: b))
        let up = uploader()
        await respond(500, "")
        await up.flush()
        await store.add(.sample(id: "3", context: a))
        clock.now += 30 * second
        await respond(202)
        await up.flush()
        let sent = await sent()
        XCTAssertEqual(sent[1].ids, ["1"])
        XCTAssertEqual(sent[1].body["context"], .object(a))
        XCTAssertEqual(sent.dropFirst(2).map(\.ids), [["2"], ["3"]])
    }

    // MARK: - Retryable failures

    func test_5xx_keeps_the_events_and_backs_off_30s_doubling_then_resets() async {
        await addEvents(3)
        let up = uploader()
        await respond(503, "")

        await up.flush()
        var sent = await sent()
        XCTAssertEqual(sent.count, 1)
        var count = await store.count
        XCTAssertEqual(count, 3)
        var next = await up.nextAttemptAt
        XCTAssertEqual(next, clock.now + 30 * second)

        await up.flush()
        sent = await self.sent()
        XCTAssertEqual(sent.count, 1, "still backing off")

        clock.now += 30 * second
        await up.flush()
        sent = await self.sent()
        XCTAssertEqual(sent.count, 2)
        next = await up.nextAttemptAt
        XCTAssertEqual(next, clock.now + 60 * second)

        clock.now += 59 * second
        await up.flush()
        sent = await self.sent()
        XCTAssertEqual(sent.count, 2)

        clock.now += second
        await respond(202)
        await up.flush()
        sent = await self.sent()
        XCTAssertEqual(sent.count, 3)
        count = await store.count
        XCTAssertEqual(count, 0)
        next = await up.nextAttemptAt
        XCTAssertNil(next)

        await addEvents(1, prefix: "n")
        await respond(500, "")
        await up.flush()
        next = await up.nextAttemptAt
        XCTAssertEqual(next, clock.now + 30 * second, "backoff resets after a success")
    }

    func test_a_retried_batch_is_the_identical_event_set() async {
        await addEvents(5)
        let up = uploader(maxBatchSize: 3)
        await respond(502, "")
        await up.flush()

        // New events arrive and an older one is no longer first in line;
        // the retry must still be exactly the same batch.
        await addEvents(4, prefix: "late")
        clock.now += 30 * second
        await up.flush()
        var sent = await sent()
        XCTAssertEqual(sent[1].ids, sent[0].ids)
        XCTAssertEqual(sent[1].ids, ["e0", "e1", "e2"])
        XCTAssertEqual(sent[1].body["events"], sent[0].body["events"])

        await respond(202)
        clock.now += 60 * second
        await up.flush()
        sent = await self.sent()
        XCTAssertEqual(sent[2].ids, ["e0", "e1", "e2"])
        XCTAssertEqual(sent.dropFirst(3).flatMap(\.ids), ["e3", "e4", "late0", "late1", "late2", "late3"])
        let count = await store.count
        XCTAssertEqual(count, 0)
    }

    func test_a_primed_batch_is_sent_first_and_unchanged() async {
        await addEvents(2)
        let up = uploader()
        await up.primePendingBatch()
        await addEvents(2, prefix: "late")
        await up.flush()
        let sent = await sent()
        XCTAssertEqual(sent.map(\.ids), [["e0", "e1"], ["late0", "late1"]])
    }

    func test_priming_does_nothing_while_disabled() async {
        await addEvents(2)
        enabled.on = false
        let up = uploader()
        await up.primePendingBatch()
        await addEvents(1, prefix: "late")
        enabled.on = true
        await up.flush()
        let sent = await sent()
        XCTAssertEqual(sent.map(\.ids), [["e0", "e1", "late0"]])
    }

    func test_backoff_is_capped_at_10_minutes() async {
        await addEvents(1)
        let up = uploader()
        await respond(500, "")
        for _ in 0..<8 {
            await up.flush()
            clock.now += 10 * minute
        }
        let sent = await sent()
        XCTAssertEqual(sent.count, 8)
        await up.flush()
        let next = await up.nextAttemptAt
        XCTAssertEqual(next, clock.now + 10 * minute)
    }

    func test_429_honours_Retry_After_seconds() async {
        await addEvents(1)
        let up = uploader()
        await respond(429, #"{"error":"rate limited"}"#, headers: ["retry-after": "120"])
        await up.flush()
        let next = await up.nextAttemptAt
        XCTAssertEqual(next, clock.now + 120 * second)
        clock.now += 119 * second
        await up.flush()
        var sent = await sent()
        XCTAssertEqual(sent.count, 1)
        clock.now += second
        await respond(202)
        await up.flush()
        sent = await self.sent()
        XCTAssertEqual(sent.count, 2)
        let count = await store.count
        XCTAssertEqual(count, 0)
    }

    func test_Retry_After_as_an_HTTP_date() async {
        await addEvents(1)
        let up = uploader()
        // Three minutes after the fake clock's 2026-10-14T09:00:00Z.
        await respond(503, "", headers: ["retry-after": "Wed, 14 Oct 2026 09:03:00 GMT"])
        await up.flush()
        let next = await up.nextAttemptAt
        XCTAssertEqual(next, clock.now + 3 * minute)
    }

    func test_Retry_After_is_capped_at_an_hour() async {
        await addEvents(1)
        let up = uploader()
        await respond(429, "", headers: ["retry-after": "7200"])
        await up.flush()
        var next = await up.nextAttemptAt
        XCTAssertEqual(next, clock.now + hour)

        clock.now += hour
        await respond(503, "", headers: ["retry-after": "Thu, 15 Oct 2026 09:00:00 GMT"])
        await up.flush()
        next = await up.nextAttemptAt
        XCTAssertEqual(next, clock.now + hour, "an HTTP date is capped too")
    }

    func test_Retry_After_in_the_past_retries_at_once_and_garbage_falls_back_to_backoff() async {
        await addEvents(1)
        let up = uploader()
        await respond(503, "", headers: ["retry-after": "Wed, 14 Oct 2026 08:00:00 GMT"])
        await up.flush()
        var next = await up.nextAttemptAt
        XCTAssertEqual(next, clock.now)

        await respond(503, "", headers: ["retry-after": "soon"])
        await up.flush()
        next = await up.nextAttemptAt
        XCTAssertEqual(next, clock.now + 60 * second, "second failure: ordinary backoff")
    }

    func test_network_errors_keep_the_events_and_back_off() async {
        await addEvents(2)
        let up = uploader()
        await respond { _, _ in throw URLError(.notConnectedToInternet) }
        await up.flush()
        let count = await store.count
        XCTAssertEqual(count, 2)
        let next = await up.nextAttemptAt
        XCTAssertEqual(next, clock.now + 30 * second)
    }

    func test_a_hung_request_times_out_and_is_retried_later() async {
        await addEvents(1)
        let hanging = HangingTransport()
        let up = Uploader(
            store: store,
            transport: hanging,
            serverUrl: URL(string: "https://loop.test")!,
            apiKey: "k",
            context: { ["platform": .string("ios")] },
            maxBatchSize: 100,
            clock: clock,
            requestTimeout: .milliseconds(10)
        )
        await up.flush()
        let calls = await hanging.calls
        XCTAssertEqual(calls, 1)
        let count = await store.count
        XCTAssertEqual(count, 1)
        let next = await up.nextAttemptAt
        XCTAssertNotNil(next)
        let uploading = await up.isUploading
        XCTAssertFalse(uploading)
        await hanging.release()
    }

    func test_a_transport_reported_timeout_is_retried_later() async {
        // URLSessionTransport surfaces its 30 s timeout as URLError.timedOut.
        await addEvents(1)
        let up = uploader()
        await respond { _, _ in throw URLError(.timedOut) }
        await up.flush()
        let count = await store.count
        XCTAssertEqual(count, 1)
        let next = await up.nextAttemptAt
        XCTAssertNotNil(next)
    }

    // MARK: - Concurrency and opt-out

    func test_only_one_upload_is_in_flight_at_a_time() async {
        await addEvents(250)
        await transport.setDelay(nanoseconds: 5_000_000)
        let up = uploader()
        async let one: Void = up.flush()
        async let two: Void = up.flush()
        async let three: Void = up.flush()
        _ = await (one, two, three)
        let maxInFlight = await transport.maxInFlight
        XCTAssertEqual(maxInFlight, 1)
        let sent = await sent()
        XCTAssertEqual(sent.flatMap(\.ids).count, 250)
        XCTAssertEqual(Set(sent.flatMap(\.ids)).count, 250)
        let uploading = await up.isUploading
        XCTAssertFalse(uploading)
    }

    func test_a_flush_joins_the_running_upload() async {
        await addEvents(1)
        await transport.setDelay(nanoseconds: 20_000_000)
        let up = uploader()
        async let first: Void = up.flush()
        // Let the first flush start its request.
        while await transport.sent.isEmpty { await Task.yield() }
        let uploading = await up.isUploading
        XCTAssertTrue(uploading)
        await up.flush()
        let count = await store.count
        XCTAssertEqual(count, 0, "the second flush returns only once the upload is done")
        await first
        let sent = await sent()
        XCTAssertEqual(sent.count, 1)
    }

    func test_does_nothing_while_disabled_opt_out() async {
        await addEvents(2)
        enabled.on = false
        let up = uploader()
        await up.flush()
        var sent = await sent()
        XCTAssertTrue(sent.isEmpty)
        let count = await store.count
        XCTAssertEqual(count, 2)
        enabled.on = true
        await up.flush()
        sent = await self.sent()
        XCTAssertEqual(sent.count, 1)
    }

    // MARK: - Endpoint

    func test_serverUrl_with_or_without_a_trailing_slash_and_with_a_path_prefix() async {
        let cases = [
            ("https://loop.test", "https://loop.test/api/ingest/analytics/batch"),
            ("https://loop.test/", "https://loop.test/api/ingest/analytics/batch"),
            ("https://loop.test/base", "https://loop.test/base/api/ingest/analytics/batch"),
            ("https://loop.test/base/", "https://loop.test/base/api/ingest/analytics/batch"),
        ]
        for (index, (server, expected)) in cases.enumerated() {
            await addEvents(1, prefix: "s\(index)-")
            await uploader(serverUrl: server).flush()
            let sent = await sent()
            XCTAssertEqual(sent.last?.request.url?.absoluteString, expected, server)
            XCTAssertEqual(sent.count, index + 1, server)
        }
    }

    // MARK: - URLSessionTransport

    func test_URLSessionTransport_returns_status_lower_cased_headers_and_body_with_a_30s_timeout() async throws {
        let seenTimeout = Toggle()
        let session = MockURLProtocol.install { request in
            seenTimeout.on = request.timeoutInterval == 30
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 429, httpVersion: "HTTP/1.1",
                headerFields: ["Retry-After": "120", "Content-Type": "application/json"]
            )!
            return (response, Data(#"{"error":"rate limited"}"#.utf8))
        }
        defer { MockURLProtocol.handler = nil }
        var request = URLRequest(url: URL(string: "https://loop.test/api/ingest/analytics/batch")!)
        request.httpMethod = "POST"
        let (status, headers, body) = try await URLSessionTransport(session: session).send(request)
        XCTAssertEqual(status, 429)
        XCTAssertEqual(headers["retry-after"], "120")
        XCTAssertEqual(headers["content-type"], "application/json")
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"error":"rate limited"}"#)
        XCTAssertTrue(seenTimeout.on, "request timeout is 30 s")
    }
}
