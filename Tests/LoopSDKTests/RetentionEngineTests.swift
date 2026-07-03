import XCTest
@testable import LoopSDK

final class RetentionEngineTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("loop-retention-engine-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Persistence backed by a throwaway UserDefaults suite, cleaned up
    /// when the test finishes.
    private func makePersistence() -> RetentionPersistence {
        let suite = "loop-retention-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return RetentionPersistence(defaults: defaults)
    }

    private func makeEngine(
        session: URLSession,
        directory: URL? = nil,
        persistence: RetentionPersistence? = nil
    ) -> RetentionEngine {
        let client = LoopClient(
            baseURL: URL(string: "https://example.test")!,
            apiKey: "loop_pk_test_aabbccdd11223344",
            reporterId: "r_abcd1234abcd",
            session: session
        )
        return RetentionEngine(
            client: client,
            store: RetentionEventStore(directory: directory ?? makeTempDir()),
            persistence: persistence ?? makePersistence(),
            appVersion: "9.9.9"
        )
    }

    private func decodeEvents(_ body: Data?) throws -> [[String: Any]] {
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]
        )
        return try XCTUnwrap(json["events"] as? [[String: Any]])
    }

    // MARK: - Wire format

    func test_flush_posts_expected_batch_shape() async throws {
        let captured = CapturedRequest()
        let session = MockURLProtocol.install { req in
            captured.body = req.httpBodyStreamData()
            captured.path = req.url?.path
            captured.method = req.httpMethod
            captured.auth = req.value(forHTTPHeaderField: "Authorization")
            captured.reporter = req.value(forHTTPHeaderField: "X-Loop-Reporter-Id")
            return (.with(status: 202), Data(#"{"accepted":2}"#.utf8))
        }
        let engine = makeEngine(session: session)

        await engine.track(name: "set_logged", props: ["reps": .int(30)], occurredAt: Date())
        await engine.flush()

        XCTAssertEqual(captured.path, "/api/ingest/track")
        XCTAssertEqual(captured.method, "POST")
        XCTAssertEqual(captured.auth, "Bearer loop_pk_test_aabbccdd11223344")
        XCTAssertEqual(captured.reporter, "r_abcd1234abcd")

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: captured.body ?? Data()) as? [String: Any]
        )
        XCTAssertEqual(json["platform"] as? String, "ios")
        XCTAssertEqual(json["appVersion"] as? String, "9.9.9")

        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        // First event ever ⇒ a synthesized session_start precedes it.
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?["name"] as? String, "session_start")
        XCTAssertEqual(events.last?["name"] as? String, "set_logged")

        let props = try XCTUnwrap(events.last?["props"] as? [String: Any])
        XCTAssertEqual(props["reps"] as? Int, 30)

        // occurredAt is ISO8601 UTC.
        let occurred = try XCTUnwrap(events.last?["occurredAt"] as? String)
        XCTAssertTrue(occurred.hasSuffix("Z"), "got \(occurred)")
        XCTAssertTrue(occurred.contains("T"), "got \(occurred)")

        // userId rides as an explicit null until identify().
        XCTAssertTrue(events.last?["userId"] is NSNull)

        // sessionId is a UUID shared by both events.
        let sid = try XCTUnwrap(events.first?["sessionId"] as? String)
        XCTAssertNotNil(UUID(uuidString: sid))
        XCTAssertEqual(events.last?["sessionId"] as? String, sid)
    }

    // MARK: - Session derivation

    func test_events_within_30_minutes_share_a_session() async throws {
        let captured = CapturedRequest()
        let session = MockURLProtocol.install { req in
            captured.body = req.httpBodyStreamData()
            return (.with(status: 202), Data(#"{"accepted":3}"#.utf8))
        }
        let engine = makeEngine(session: session)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        await engine.track(name: "app_opened", occurredAt: t0)
        await engine.track(name: "set_logged", occurredAt: t0.addingTimeInterval(29 * 60))
        await engine.flush()

        let events = try decodeEvents(captured.body)
        // Only one session_start for the whole run.
        XCTAssertEqual(events.map { $0["name"] as? String }, ["session_start", "app_opened", "set_logged"])
        let sids = Set(events.compactMap { $0["sessionId"] as? String })
        XCTAssertEqual(sids.count, 1)
    }

    func test_gap_of_30_minutes_or_more_starts_a_new_session() async throws {
        let captured = CapturedRequest()
        let session = MockURLProtocol.install { req in
            captured.body = req.httpBodyStreamData()
            return (.with(status: 202), Data(#"{"accepted":4}"#.utf8))
        }
        let engine = makeEngine(session: session)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        await engine.track(name: "app_opened", occurredAt: t0)
        await engine.track(name: "app_opened", occurredAt: t0.addingTimeInterval(31 * 60))
        await engine.flush()

        let events = try decodeEvents(captured.body)
        XCTAssertEqual(
            events.map { $0["name"] as? String },
            ["session_start", "app_opened", "session_start", "app_opened"]
        )
        let firstSid = events[0]["sessionId"] as? String
        XCTAssertEqual(events[1]["sessionId"] as? String, firstSid)
        let secondSid = events[2]["sessionId"] as? String
        XCTAssertEqual(events[3]["sessionId"] as? String, secondSid)
        XCTAssertNotEqual(firstSid, secondSid)
    }

    func test_session_survives_relaunch_within_the_gap() async throws {
        let captured = CapturedRequest()
        let session = MockURLProtocol.install { req in
            captured.body = req.httpBodyStreamData()
            return (.with(status: 202), Data(#"{"accepted":1}"#.utf8))
        }
        let dir = makeTempDir()
        let persistence = makePersistence()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        let first = makeEngine(session: session, directory: dir, persistence: persistence)
        await first.track(name: "app_opened", occurredAt: t0)
        await first.flush()
        let firstEvents = try decodeEvents(captured.body)
        let sid = firstEvents.first?["sessionId"] as? String

        // "Relaunch" 10 minutes later: same persistence ⇒ same session,
        // and no second session_start.
        let second = makeEngine(session: session, directory: dir, persistence: persistence)
        await second.track(name: "set_logged", occurredAt: t0.addingTimeInterval(10 * 60))
        await second.flush()

        let events = try decodeEvents(captured.body)
        XCTAssertEqual(events.map { $0["name"] as? String }, ["set_logged"])
        XCTAssertEqual(events.first?["sessionId"] as? String, sid)
    }

    // MARK: - identify / resetIdentity

    func test_identify_attaches_user_id_and_reset_clears_it() async throws {
        let captured = CapturedRequest()
        let session = MockURLProtocol.install { req in
            captured.body = req.httpBodyStreamData()
            return (.with(status: 202), Data(#"{"accepted":3}"#.utf8))
        }
        let engine = makeEngine(session: session)

        await engine.track(name: "before_identify", occurredAt: Date())
        await engine.identify("u_42")
        await engine.track(name: "after_identify", occurredAt: Date())
        await engine.resetIdentity()
        await engine.track(name: "after_reset", occurredAt: Date())
        await engine.flush()

        let events = try decodeEvents(captured.body)
        let byName = Dictionary(uniqueKeysWithValues: events.map { ($0["name"] as! String, $0) })
        XCTAssertTrue(byName["before_identify"]?["userId"] is NSNull)
        XCTAssertEqual(byName["after_identify"]?["userId"] as? String, "u_42")
        XCTAssertTrue(byName["after_reset"]?["userId"] is NSNull)
    }

    func test_identify_persists_across_relaunch() async throws {
        let session = MockURLProtocol.install { _ in
            (.with(status: 202), Data(#"{"accepted":1}"#.utf8))
        }
        let persistence = makePersistence()
        let first = makeEngine(session: session, persistence: persistence)
        await first.identify("u_42")

        let captured = CapturedRequest()
        let capturingSession = MockURLProtocol.install { req in
            captured.body = req.httpBodyStreamData()
            return (.with(status: 202), Data(#"{"accepted":2}"#.utf8))
        }
        let second = makeEngine(session: capturingSession, persistence: persistence)
        await second.track(name: "after_relaunch", occurredAt: Date())
        await second.flush()

        let events = try decodeEvents(captured.body)
        XCTAssertEqual(events.last?["userId"] as? String, "u_42")
    }

    // MARK: - Sanitization at the engine boundary

    func test_invalid_event_names_are_dropped_before_buffering() async throws {
        let counter = RequestCounter()
        let session = MockURLProtocol.install { _ in
            counter.increment()
            return (.with(status: 202), Data(#"{"accepted":0}"#.utf8))
        }
        let engine = makeEngine(session: session)

        await engine.track(name: "💥🎉", occurredAt: Date())
        await engine.track(name: String(repeating: "a", count: 65), occurredAt: Date())
        await engine.flush()

        // Nothing buffered (not even a session_start) ⇒ nothing sent.
        XCTAssertEqual(counter.value, 0)
    }

    // MARK: - Batching triggers

    func test_twenty_buffered_events_trigger_a_flush() async throws {
        let captured = CapturedRequest()
        let counter = RequestCounter()
        let session = MockURLProtocol.install { req in
            counter.increment()
            captured.body = req.httpBodyStreamData()
            return (.with(status: 202), Data(#"{"accepted":20}"#.utf8))
        }
        let engine = makeEngine(session: session)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        // 19 tracked events + 1 synthesized session_start = 20 buffered.
        for i in 0..<19 {
            await engine.track(name: "event_\(i)", occurredAt: t0.addingTimeInterval(Double(i)))
        }

        XCTAssertEqual(counter.value, 1, "hitting 20 buffered events must flush without waiting")
        let events = try decodeEvents(captured.body)
        XCTAssertEqual(events.count, 20)
        XCTAssertEqual(events.first?["name"] as? String, "session_start")
        let buffered = await engine.bufferedEventCount()
        XCTAssertEqual(buffered, 0)
    }

    func test_fewer_than_twenty_events_do_not_flush_immediately() async throws {
        let counter = RequestCounter()
        let session = MockURLProtocol.install { _ in
            counter.increment()
            return (.with(status: 202), Data(#"{"accepted":0}"#.utf8))
        }
        let engine = makeEngine(session: session)

        await engine.track(name: "one", occurredAt: Date())
        await engine.track(name: "two", occurredAt: Date())

        XCTAssertEqual(counter.value, 0)
        let awaited_137 = await engine.bufferedEventCount()
        XCTAssertEqual(awaited_137, 3) // session_start + 2
    }

    // MARK: - Offline retry semantics

    func test_failed_flush_keeps_events_for_the_next_flush() async throws {
        let mode = MockMode()
        let bodies = SentBodies()
        let session = MockURLProtocol.install { req in
            if mode.failNext {
                return (.with(status: 500), Data(#"{"error":"down"}"#.utf8))
            }
            bodies.append(req.httpBodyStreamData())
            return (.with(status: 202), Data(#"{"accepted":2}"#.utf8))
        }
        let engine = makeEngine(session: session)

        mode.failNext = true
        await engine.track(name: "offline_case", occurredAt: Date())
        await engine.flush()
        let awaited_137 = await engine.bufferedEventCount()
        XCTAssertEqual(awaited_137, 2, "5xx must keep the batch buffered")

        mode.failNext = false
        await engine.flush()
        let buffered = await engine.bufferedEventCount()
        XCTAssertEqual(buffered, 0)
        XCTAssertEqual(bodies.count, 1)
        let events = try decodeEvents(bodies.all.first)
        XCTAssertEqual(events.map { $0["name"] as? String }, ["session_start", "offline_case"])
    }

    func test_4xx_response_drops_the_batch_to_avoid_poison_pills() async throws {
        let counter = RequestCounter()
        let session = MockURLProtocol.install { _ in
            counter.increment()
            return (.with(status: 422), Data(#"{"error":"bad batch"}"#.utf8))
        }
        let engine = makeEngine(session: session)

        await engine.track(name: "poison", occurredAt: Date())
        await engine.flush()
        let awaited_137 = await engine.bufferedEventCount()
        XCTAssertEqual(awaited_137, 0, "4xx must drop the batch")

        // A follow-up flush has nothing to send — no retry loop.
        await engine.flush()
        XCTAssertEqual(counter.value, 1)
    }

    func test_buffered_events_survive_relaunch_and_flush_from_disk() async throws {
        let dir = makeTempDir()
        let failing = MockURLProtocol.install { _ in
            (.with(status: 500), Data(#"{"error":"down"}"#.utf8))
        }
        let first = makeEngine(session: failing, directory: dir)
        await first.track(name: "queued_offline", occurredAt: Date())
        await first.flush()

        let captured = CapturedRequest()
        let succeeding = MockURLProtocol.install { req in
            captured.body = req.httpBodyStreamData()
            return (.with(status: 202), Data(#"{"accepted":2}"#.utf8))
        }
        let second = makeEngine(session: succeeding, directory: dir)
        await second.flush()

        let events = try decodeEvents(captured.body)
        XCTAssertEqual(events.map { $0["name"] as? String }, ["session_start", "queued_offline"])
        let secondBuffered = await second.bufferedEventCount()
        XCTAssertEqual(secondBuffered, 0)
    }

    // MARK: - Funnels

    func test_define_funnel_posts_expected_payload_shape() async throws {
        let captured = CapturedRequest()
        let session = MockURLProtocol.install { req in
            captured.body = req.httpBodyStreamData()
            captured.path = req.url?.path
            captured.method = req.httpMethod
            captured.auth = req.value(forHTTPHeaderField: "Authorization")
            return (.with(status: 202), Data("{}".utf8))
        }
        let engine = makeEngine(session: session)

        await engine.defineFunnel(FunnelDefinition(
            key: "activation",
            name: "Activation",
            steps: ["app_opened", "onboarding_completed", "set_logged"],
            windowDays: 7,
            activation: true
        ))

        XCTAssertEqual(captured.path, "/api/ingest/funnels")
        XCTAssertEqual(captured.method, "POST")
        XCTAssertEqual(captured.auth, "Bearer loop_pk_test_aabbccdd11223344")

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: captured.body ?? Data()) as? [String: Any]
        )
        let funnels = try XCTUnwrap(json["funnels"] as? [[String: Any]])
        XCTAssertEqual(funnels.count, 1)
        XCTAssertEqual(funnels.first?["key"] as? String, "activation")
        XCTAssertEqual(funnels.first?["name"] as? String, "Activation")
        XCTAssertEqual(
            funnels.first?["steps"] as? [String],
            ["app_opened", "onboarding_completed", "set_logged"]
        )
        XCTAssertEqual(funnels.first?["windowDays"] as? Int, 7)
        XCTAssertEqual(funnels.first?["activation"] as? Bool, true)
    }

    func test_same_funnel_key_is_sent_only_once_per_run() async throws {
        let counter = RequestCounter()
        let session = MockURLProtocol.install { _ in
            counter.increment()
            return (.with(status: 202), Data("{}".utf8))
        }
        let engine = makeEngine(session: session)

        let funnel = FunnelDefinition(
            key: "activation", name: "Activation",
            steps: ["app_opened"], windowDays: 7, activation: true
        )
        await engine.defineFunnel(funnel)
        await engine.defineFunnel(funnel)

        XCTAssertEqual(counter.value, 1)
    }

    func test_failed_funnel_send_retries_on_next_flush() async throws {
        let mode = MockMode()
        let paths = SentPaths()
        let session = MockURLProtocol.install { req in
            if mode.failNext {
                return (.with(status: 500), Data(#"{"error":"down"}"#.utf8))
            }
            paths.append(req.url?.path)
            return (.with(status: 202), Data("{}".utf8))
        }
        let engine = makeEngine(session: session)

        mode.failNext = true
        await engine.defineFunnel(FunnelDefinition(
            key: "activation", name: "Activation",
            steps: ["app_opened"], windowDays: 7, activation: false
        ))

        mode.failNext = false
        await engine.flush()
        XCTAssertTrue(paths.all.contains("/api/ingest/funnels"))
    }

    // MARK: - Public API surface

    func test_public_analytics_api_is_safe_without_start() {
        // Must never crash before start(): all entry points no-op.
        LoopSDK.track("no_config_yet", ["reps": 30])
        LoopSDK.identify("u_1")
        LoopSDK.resetIdentity()
        LoopSDK.defineFunnel(key: "k", name: "K", steps: ["a", "b"])
    }
}

final class SentPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func append(_ path: String?) { lock.lock(); if let path { paths.append(path) }; lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
}
