import XCTest
import LoopCore
@testable import LoopAnalytics

final class LoopAnalyticsTests: XCTestCase {
    private var harnesses: [EngineHarness] = []
    private var directories: [URL] = []

    override func tearDown() async throws {
        LoopAnalytics.resetForTesting()
        await AnalyticsRuntime.shared.waitForPendingCalls()
        LoopRuntime.shared.resetForTesting()
        for h in harnesses {
            await h.engine?.dispose()
            h.removeStorage()
        }
        harnesses = []
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
    }

    // MARK: - Helpers

    private func harness(
        _ options: LoopAnalyticsOptions = LoopAnalyticsOptions(),
        requestTimeout: Duration = .milliseconds(500),
        startEngine: Bool = true
    ) async throws -> EngineHarness {
        let h = try await EngineHarness(options: options, requestTimeout: requestTimeout, startEngine: startEngine)
        harnesses.append(h)
        return h
    }

    private func restart(
        _ h: EngineHarness,
        options: LoopAnalyticsOptions? = nil,
        context: ContextBox? = nil
    ) async throws -> EngineHarness {
        await h.engine.dispose()
        let next = try await h.restarted(options: options, context: context)
        harnesses.append(next)
        return next
    }

    /// The facade over a fake environment, not yet configured.
    private func facadeHarness(requestTimeout: Duration = .milliseconds(500)) async throws -> EngineHarness {
        let h = try await harness(requestTimeout: requestTimeout, startEngine: false)
        LoopRuntime.shared.resetForTesting()
        LoopAnalytics.resetForTesting(environment: { h.environment() })
        return h
    }

    private func configure() {
        Loop.configure(
            apiKey: EngineHarness.apiKey,
            options: LoopOptions(serverUrl: EngineHarness.serverUrl, tierProvider: nil)
        )
    }

    private func options(_ change: (inout LoopAnalyticsOptions) -> Void) -> LoopAnalyticsOptions {
        var options = LoopAnalyticsOptions()
        change(&options)
        return options
    }

    private func context(_ sent: Sent) -> JSONObject {
        if case .object(let context)? = sent.body["context"] { return context }
        return [:]
    }

    // MARK: - Facade

    func test_calls_before_configure_are_dropped_without_crashing() async {
        LoopRuntime.shared.resetForTesting(store: ReporterStore(service: "io.loop.sdk.tests.\(UUID().uuidString)"))
        LoopAnalytics.resetForTesting()
        LoopAnalytics.track("Item Viewed")
        LoopAnalytics.setUserId("u1")
        await LoopAnalytics.flush()
        XCTAssertNil(LoopAnalytics.deviceId)
    }

    func test_first_call_after_configure_starts_with_default_options() async throws {
        let h = try await facadeHarness()
        LoopAnalytics.track("Before Configure")
        LoopAnalytics.setOptOut(true)
        await LoopAnalytics.flush()
        XCTAssertNil(LoopAnalytics.deviceId)
        XCTAssertNil(LoopAnalytics.sessionId)

        configure()
        LoopAnalytics.track("Item Viewed")
        await LoopAnalytics.flush()

        XCTAssertEqual(h.transport.sentNames, ["Item Viewed"])
        XCTAssertEqual(LoopAnalytics.deviceId, "DEVICE-1R")
        XCTAssertEqual(LoopAnalytics.sessionId, EngineHarness.clockStart)
        XCTAssertEqual(h.scheduler.intervals, [30_000], "default flushInterval")

        // The engine is running: a later start is ignored.
        LoopAnalytics.start(options: options { $0.legacyDeviceId = "ignored"; $0.flushInterval = 5 })
        await LoopAnalytics.flush()
        XCTAssertEqual(LoopAnalytics.deviceId, "DEVICE-1R")
        XCTAssertEqual(h.scheduler.intervals, [30_000])
    }

    func test_start_options_apply_and_a_second_start_is_ignored() async throws {
        let h = try await facadeHarness()
        configure()
        LoopAnalytics.start(options: options { $0.flushQueueSize = 2; $0.flushInterval = 60 })
        LoopAnalytics.start(options: options { $0.flushQueueSize = 100; $0.flushInterval = 5 })

        LoopAnalytics.track("A")
        LoopAnalytics.track("B")
        try await h.transport.waitForRequests(1)

        XCTAssertEqual(h.transport.sentNames, ["A", "B"])
        XCTAssertEqual(h.scheduler.intervals, [60_000])
    }

    func test_options_initializer_takes_any_option_and_defaults_the_rest() {
        let all = LoopAnalyticsOptions(
            flushQueueSize: 5,
            flushInterval: 10,
            minTimeBetweenSessions: 60,
            maxQueueSize: 200,
            maxBatchSize: 50,
            legacyDeviceId: "legacy-1"
        )
        XCTAssertEqual(all.flushQueueSize, 5)
        XCTAssertEqual(all.flushInterval, 10)
        XCTAssertEqual(all.minTimeBetweenSessions, 60)
        XCTAssertEqual(all.maxQueueSize, 200)
        XCTAssertEqual(all.maxBatchSize, 50)
        XCTAssertEqual(all.legacyDeviceId, "legacy-1")

        for options in [LoopAnalyticsOptions(legacyDeviceId: "legacy-1"), LoopAnalyticsOptions()] {
            XCTAssertEqual(options.flushQueueSize, 30)
            XCTAssertEqual(options.flushInterval, 30)
            XCTAssertEqual(options.minTimeBetweenSessions, 300)
            XCTAssertEqual(options.maxQueueSize, 1000)
            XCTAssertEqual(options.maxBatchSize, 100)
        }
        XCTAssertNil(LoopAnalyticsOptions().legacyDeviceId)
    }

    func test_start_with_an_inline_legacy_device_id() async throws {
        _ = try await facadeHarness()
        configure()
        LoopAnalytics.start(options: .init(legacyDeviceId: "legacy-2"))
        LoopAnalytics.track("A")
        await LoopAnalytics.flush()

        XCTAssertEqual(LoopAnalytics.deviceId, "legacy-2")
    }

    func test_start_before_configure_keeps_its_options_for_the_engine() async throws {
        _ = try await facadeHarness()
        LoopAnalytics.start(options: options { $0.legacyDeviceId = "legacy-1" })
        XCTAssertNil(LoopAnalytics.deviceId)

        configure()
        LoopAnalytics.track("A")
        await LoopAnalytics.flush()

        XCTAssertEqual(LoopAnalytics.deviceId, "legacy-1")
    }

    func test_set_user_properties_removes_keys_set_to_nil_or_NSNull() async throws {
        let h = try await facadeHarness()
        configure()
        LoopAnalytics.setUserProperties(["Plan": "annual", "X": 1, "Y": "y", "Z": true])
        let missing: String? = nil
        LoopAnalytics.setUserProperties(["X": nil, "Y": NSNull(), "Z": missing as Any, "W": 2])
        LoopAnalytics.track("A")
        await LoopAnalytics.flush()

        XCTAssertEqual(h.transport.sentEvents.first?["userProps"], .object(["Plan": .string("annual"), "W": .int(2)]))
    }

    func test_fire_and_forget_calls_keep_their_order() async throws {
        let h = try await facadeHarness()
        configure()
        LoopAnalytics.start(options: options { $0.flushQueueSize = 1000 })
        for i in 0..<50 {
            LoopAnalytics.setUserId("u\(i)")
            LoopAnalytics.setUserProperties(["Step": i])
            LoopAnalytics.track("E\(i)", ["Index": i])
        }
        await LoopAnalytics.flush()

        XCTAssertEqual(h.transport.sentNames, (0..<50).map { "E\($0)" })
        for (i, event) in h.transport.sentEvents.enumerated() {
            XCTAssertEqual(event["userId"], .string("u\(i)"))
            XCTAssertEqual(event["userProps"], .object(["Step": .int(Int64(i))]))
            XCTAssertEqual(event["props"], .object(["Index": .int(Int64(i))]))
        }
    }

    func test_reset_completes_with_the_new_identity_in_place() async throws {
        _ = try await facadeHarness()
        configure()
        LoopAnalytics.setUserId("u1")
        LoopAnalytics.track("A")
        await LoopAnalytics.flush()
        XCTAssertEqual(LoopAnalytics.deviceId, "DEVICE-1R")

        await LoopAnalytics.reset()

        XCTAssertEqual(LoopAnalytics.deviceId, "DEVICE-2R")
    }

    func test_a_slow_flush_does_not_hold_up_later_calls() async throws {
        let h = try await facadeHarness(requestTimeout: .milliseconds(1500))
        configure()
        LoopAnalytics.track("A")
        h.transport.hold()
        let flush = Task { await LoopAnalytics.flush() }
        try await h.transport.waitForRequests(1)

        LoopAnalytics.track("B")

        // B reaches the queue file while the request for A still hangs.
        let deadline = Date().addingTimeInterval(1)
        while !h.queueFileLines().contains(where: { $0.contains(#""name":"B""#) }) {
            guard Date() < deadline else { return XCTFail("B was not queued while the upload hung") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await flush.value // returns once the request times out
    }

    func test_reconfiguring_after_start_warns_once_and_keeps_the_engine() async throws {
        let log = LogRecorder()
        defer { log.stop() }
        let h = try await facadeHarness()
        configure()
        LoopAnalytics.track("A")
        await LoopAnalytics.flush()
        XCTAssertEqual(log.messages(.warning).filter { $0.contains("Loop.configure") }, [])

        Loop.configure(
            apiKey: "loop_pk_other",
            options: LoopOptions(serverUrl: URL(string: "https://other.test")!, tierProvider: nil)
        )
        LoopAnalytics.track("B")
        LoopAnalytics.setUserId("u1")
        LoopAnalytics.track("C")
        await LoopAnalytics.flush()

        XCTAssertEqual(log.messages(.warning).filter { $0.contains("Loop.configure") }.count, 1)
        XCTAssertEqual(h.transport.sentNames, ["A", "B", "C"])
        for sent in h.transport.requests {
            XCTAssertEqual(sent.request.url?.host, "loop.test")
            XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Authorization"), "Bearer loop_pk_test")
        }
        XCTAssertEqual(LoopAnalytics.deviceId, "DEVICE-1R")
    }

    // MARK: - Engine: restart and dispose

    func test_restart_during_inflight_upload_resends_identical_batch() async throws {
        let h = try await harness() // fake env over a temp dir
        h.transport.hold() // next request never completes
        await h.engine.track("E1", nil)
        Task { await h.engine.flush() }
        try await h.transport.waitForRequests(1)
        await h.engine.dispose() // app killed: request outcome unknown
        let h2 = try await h.restarted() // same storage, new engine, startup flush
        harnesses.append(h2)
        try await h2.transport.waitForRequests(1)
        await h2.engine.waitUntilIdle()
        XCTAssertEqual(h2.transport.requests[0].events, h.transport.requests[0].events)
        let queued = await h2.engine.queueLength()
        XCTAssertEqual(queued, 0)
    }

    func test_dispose_waits_for_the_request_in_flight_and_starts_no_upload() async throws {
        let h = try await harness(options { $0.flushQueueSize = 100; $0.maxBatchSize = 1 })
        await h.engine.track("A", nil)
        await h.engine.track("B", nil)
        h.transport.hold(for: 0.3)
        let flush = Task { await h.engine.flush() }
        try await h.transport.waitForRequests(1)

        let started = Date()
        await h.engine.dispose()
        let waited = Date().timeIntervalSince(started)

        XCTAssertGreaterThan(waited, 0.1, "dispose waits for the request in flight")
        await flush.value
        XCTAssertEqual(h.transport.sentNames, ["A"], "the next batch is not sent after dispose")
        let queued = await h.engine.queueLength()
        XCTAssertEqual(queued, 1, "A was acknowledged; B stays queued")
    }

    func test_dispose_wait_is_bounded_by_the_request_timeout() async throws {
        let h = try await harness(requestTimeout: .milliseconds(300))
        await h.engine.track("A", nil)
        h.transport.hold() // never answered
        Task { await h.engine.flush() }
        try await h.transport.waitForRequests(1)

        let started = Date()
        await h.engine.dispose()
        let waited = Date().timeIntervalSince(started)

        XCTAssertGreaterThan(waited, 0.1)
        XCTAssertLessThan(waited, 2, "bounded by the request timeout")
        let queued = await h.engine.queueLength()
        XCTAssertEqual(queued, 1)
    }

    func test_dispose_cancels_the_timer_and_ignores_lifecycle_changes() async throws {
        let h = try await harness(options { $0.flushQueueSize = 100 })
        await h.engine.track("A", nil)
        XCTAssertEqual(h.scheduler.activeTimers, 1)

        await h.engine.dispose()
        XCTAssertEqual(h.scheduler.activeTimers, 0)
        h.lifecycle.emit(false)
        await h.engine.waitUntilIdle()

        XCTAssertEqual(h.transport.requests.count, 0)
        XCTAssertEqual(h.lifecycle.backgroundTasks, [])
        let queued = await h.engine.queueLength()
        XCTAssertEqual(queued, 1, "queued events stay on disk")
    }

    func test_calls_after_dispose_are_ignored() async throws {
        let h = try await harness()
        await h.engine.dispose()
        await h.engine.track("Late", nil)
        await h.engine.setUserId("1")
        await h.engine.setOptOut(false)
        await h.engine.flush()
        await h.engine.reset()
        await h.engine.waitUntilIdle()

        XCTAssertEqual(h.transport.requests.count, 0)
        let queued = await h.engine.queueLength()
        XCTAssertEqual(queued, 0)
        let deviceId = await h.engine.deviceId
        XCTAssertEqual(deviceId, "DEVICE-1R")
    }

    func test_queued_events_survive_a_restart_and_upload_at_startup() async throws {
        let h = try await harness()
        h.transport.respond(503)
        await h.engine.track("Before Crash", nil)
        await h.engine.flush()
        XCTAssertEqual(h.transport.requests.count, 1)

        let h2 = try await restart(h)
        await h2.engine.waitUntilIdle()

        XCTAssertEqual(h2.transport.sentNames, ["Before Crash"])
        let (first, second) = (await h.engine.deviceId, await h2.engine.deviceId)
        XCTAssertEqual(second, first)
    }

    func test_the_startup_batch_is_exactly_the_events_on_disk_even_if_the_app_tracks_at_once() async throws {
        // The startup batch must not depend on whether the app's first
        // track() beats the startup upload: a batch resent after a kill has
        // to be the same event set, or server-side dedup misses it. Repeated
        // because the old behaviour lost only some of the races.
        for run in 0..<25 {
            let h = try await harness(options { $0.flushQueueSize = 100 })
            await h.engine.track("Old 1", nil)
            await h.engine.track("Old 2", nil)

            let h2 = try await restart(h)
            await h2.engine.track("New", nil)
            await h2.engine.waitUntilIdle()

            let batches = h2.transport.requests.map { $0.events.compactMap { event -> String? in
                if case .string(let name)? = event["name"] { return name } else { return nil }
            } }
            XCTAssertEqual(batches.first, ["Old 1", "Old 2"], "run \(run): \(batches)")
            if batches.first != ["Old 1", "Old 2"] { return }
        }
    }

    // MARK: - Engine: wire shape

    func test_sends_exactly_the_wire_contract_body_gzip_encoded() async throws {
        let h = try await harness()
        await h.engine.setUserId("12345")
        await h.engine.setUserProperties(["Plan": .string("annual"), "Total Diary Entries": .int(412)])
        await h.engine.setPurchaserId("$RCAnonymousID:b47e")
        await h.engine.track("Purchase Completed", [
            "Plan": .string("annual"),
            "Restored": .bool(false),
            "foods": .array([.string("apple")]),
            "coupon": .null,
        ])
        h.clock.now += 4718
        await h.engine.flush()

        XCTAssertEqual(h.transport.requests.count, 1)
        let sent = try XCTUnwrap(h.transport.requests.first)
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(sent.request.url?.absoluteString, "https://loop.test/api/ingest/analytics/batch")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Authorization"), "Bearer loop_pk_test")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let expected: JSONObject = [
            "sentAt": .string("2026-01-01T00:00:04.718Z"),
            "context": .object([
                "platform": .string("iOS"),
                "osName": .string("ios"),
                "osVersion": .string("18.0"),
                "appVersion": .string("1.0.0"),
                "appBuild": .string("1"),
                "deviceModel": .string("iPhone15,3"),
                "deviceManufacturer": .string("Apple"),
                "isTablet": .bool(false),
                "locale": .string("en-GB"),
                "purchaserId": .string("$RCAnonymousID:b47e"),
                "sdk": .object(["name": .string("loop-ios"), "version": .string("2.0.0")]),
            ]),
            "events": .array([
                .object([
                    "id": .string("00000000-0000-4000-8000-000000000001"),
                    "name": .string("Purchase Completed"),
                    "occurredAt": .string("2026-01-01T00:00:00.000Z"),
                    "sessionId": .int(EngineHarness.clockStart),
                    "deviceId": .string("DEVICE-1R"),
                    "userId": .string("12345"),
                    "props": .object([
                        "Plan": .string("annual"),
                        "Restored": .bool(false),
                        "foods": .array([.string("apple")]),
                    ]),
                    "userProps": .object(["Plan": .string("annual"), "Total Diary Entries": .int(412)]),
                ]),
            ]),
        ]
        XCTAssertEqual(sent.body, expected)
    }

    func test_anonymous_events_carry_a_null_user_id_and_empty_maps() async throws {
        let h = try await harness()
        await h.engine.track("App Opened", nil)
        await h.engine.flush()

        let sent = try XCTUnwrap(h.transport.requests.first)
        let event = try XCTUnwrap(sent.events.first)
        XCTAssertEqual(event["userId"], .null)
        XCTAssertEqual(event["props"], .object([:]))
        XCTAssertEqual(event["userProps"], .object([:]))
        XCTAssertEqual(context(sent)["purchaserId"], .null)
    }

    func test_empty_user_and_purchaser_ids_mean_none() async throws {
        let h = try await harness()
        await h.engine.setUserId("")
        await h.engine.setPurchaserId("")
        await h.engine.track("A", nil)
        await h.engine.flush()

        let sent = try XCTUnwrap(h.transport.requests.first)
        XCTAssertEqual(sent.events.first?["userId"], .null)
        XCTAssertEqual(context(sent)["purchaserId"], .null)
    }

    func test_invalid_names_and_oversized_events_are_dropped() async throws {
        let log = LogRecorder()
        defer { log.stop() }
        let h = try await harness()
        let longest = String(repeating: "n", count: 128)
        await h.engine.track("", nil)
        await h.engine.track("   ", nil)
        await h.engine.track(String(repeating: "x", count: 129), nil)
        await h.engine.track("Odd", ["n": .number(.nan), "inner": .object(["gone": .null])])
        await h.engine.track("Huge", ["blob": .string(String(repeating: "x", count: 40_000))])
        await h.engine.track(longest, nil)
        await h.engine.flush()

        XCTAssertEqual(h.transport.sentNames, ["Odd", longest])
        XCTAssertEqual(h.transport.sentEvents.first?["props"], .object(["n": .string("nan"), "inner": .object([:])]))
        let warnings = log.messages(.warning)
        XCTAssertEqual(warnings.filter { $0.contains("Dropped event") }.count, 4, "\(warnings)")
        XCTAssertTrue(warnings.contains { $0.contains("\"Huge\"") && $0.contains("32768") }, "\(warnings)")
    }

    func test_an_invalid_event_name_is_not_logged_only_its_length() async throws {
        let log = LogRecorder()
        defer { log.stop() }
        let h = try await harness()
        // An app could pass anything here, even user data; it is logged
        // publicly, so only its length is.
        let name = "  " + String(repeating: "secret ", count: 19) + "  " // 132 once trimmed
        await h.engine.track(name, nil)
        await h.engine.track("  ", nil)

        let messages = log.messages(.warning) + log.messages(.debug) + log.messages(.error)
        XCTAssertFalse(messages.contains { $0.contains("secret") }, "\(messages)")
        XCTAssertEqual(
            log.messages(.warning).filter { $0.hasPrefix("Dropped event") },
            [
                "Dropped event: its name is 132 characters once trimmed; names must be 1–128",
                "Dropped event: its name is 0 characters once trimmed; names must be 1–128",
            ]
        )
    }

    func test_event_size_limit_is_32_kb_of_wire_json() async throws {
        let h = try await harness()
        // Measure the fixed part of an event's wire JSON with a probe.
        await h.engine.track("Probe", ["S": .string(String(repeating: "x", count: 1000))])
        await h.engine.flush()
        let probe = try XCTUnwrap(h.transport.sentEvents.first)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let overhead = try encoder.encode(probe).count - 1000
        let fits = AnalyticsEngine.maxEventBytes - overhead

        await h.engine.track("Probe", ["S": .string(String(repeating: "x", count: fits + 1))])
        await h.engine.track("Probe", ["S": .string(String(repeating: "x", count: fits))])
        await h.engine.flush()

        XCTAssertEqual(h.transport.sentEvents.count, 2)
        guard case .object(let props)? = h.transport.sentEvents.last?["props"],
              case .string(let s)? = props["S"] else { return XCTFail("no props") }
        XCTAssertEqual(s.count, fits, "the largest event that fits is sent untruncated")
    }

    func test_a_transport_error_is_contained_and_events_stay_queued() async throws {
        let h = try await harness()
        h.transport.failNext()
        await h.engine.track("A", nil)
        await h.engine.flush()

        XCTAssertEqual(h.transport.requests.count, 1)
        let queued = await h.engine.queueLength()
        XCTAssertEqual(queued, 1)
    }

    // MARK: - Engine: identity

    func test_uses_the_legacy_device_id_on_first_run() async throws {
        let h = try await harness(options { $0.legacyDeviceId = "legacy-device-1" })
        let deviceId = await h.engine.deviceId
        XCTAssertEqual(deviceId, "legacy-device-1")
        await h.engine.track("X", nil)
        await h.engine.flush()
        XCTAssertEqual(h.transport.sentEvents.first?["deviceId"], .string("legacy-device-1"))
    }

    func test_each_event_snapshots_the_user_properties_at_that_moment() async throws {
        let h = try await harness()
        await h.engine.setUserProperties(["Plan": .string("free"), "Streak": .int(3)])
        await h.engine.track("A", nil)
        await h.engine.setUserProperties(["Plan": .string("annual"), "Streak": .null, "Nested": .object(["x": .null, "y": .int(1)])])
        await h.engine.track("B", nil)
        await h.engine.flush()

        let events = h.transport.sentEvents
        XCTAssertEqual(events[0]["userProps"], .object(["Plan": .string("free"), "Streak": .int(3)]))
        XCTAssertEqual(events[1]["userProps"], .object(["Plan": .string("annual"), "Nested": .object(["y": .int(1)])]))
    }

    func test_reset_gives_a_new_identity_and_session() async throws {
        let h = try await harness(options { $0.legacyDeviceId = "legacy-device" })
        await h.engine.setUserId("12345")
        await h.engine.setUserProperties(["Plan": .string("annual")])
        await h.engine.setPurchaserId("rc-1")
        await h.engine.track("Before", nil)
        let oldSession = await h.engine.sessionId
        h.clock.now += 1000

        await h.engine.reset()

        let (deviceId, userId, session) = (await h.engine.deviceId, await h.engine.userId, await h.engine.sessionId)
        XCTAssertEqual(deviceId, "DEVICE-1R", "a new random id, never the legacy one")
        XCTAssertNil(userId)
        XCTAssertEqual(session, h.clock.now)
        XCTAssertNotEqual(session, oldSession)

        await h.engine.track("After", nil)
        await h.engine.flush()
        let events = h.transport.sentEvents
        XCTAssertEqual(events[0]["deviceId"], .string("legacy-device"))
        XCTAssertEqual(events[0]["userId"], .string("12345"))
        XCTAssertEqual(events[1]["deviceId"], .string("DEVICE-1R"))
        XCTAssertEqual(events[1]["userId"], .null)
        XCTAssertEqual(events[1]["userProps"], .object([:]))
        XCTAssertEqual(events[1]["sessionId"], .int(h.clock.now))
        XCTAssertEqual(context(try XCTUnwrap(h.transport.requests.last))["purchaserId"], .null)
    }

    func test_opt_out_drops_new_events_and_pauses_uploads_but_keeps_the_queue() async throws {
        let h = try await harness()
        await h.engine.track("Queued Before", nil)
        await h.engine.setOptOut(true)
        let optedOut = await h.engine.isOptedOut
        XCTAssertTrue(optedOut)
        await h.engine.track("Ignored", nil)
        await h.engine.flush()
        XCTAssertEqual(h.transport.requests.count, 0)

        let h2 = try await restart(h)
        XCTAssertEqual(h.queueFileLines().count, 1, "queued events stay on disk")
        let stillOptedOut = await h2.engine.isOptedOut
        XCTAssertTrue(stillOptedOut, "opt-out is persisted")
        await h2.engine.track("Still Ignored", nil)
        await h2.engine.flush()
        await h2.engine.waitUntilIdle()
        XCTAssertEqual(h2.transport.requests.count, 0)

        await h2.engine.setOptOut(false)
        await h2.engine.waitUntilIdle()
        XCTAssertEqual(h2.transport.sentNames, ["Queued Before"], "opting back in uploads at once")
        await h2.engine.track("After", nil)
        await h2.engine.flush()
        XCTAssertEqual(h2.transport.sentNames, ["Queued Before", "After"])
    }

    // MARK: - Engine: when uploads happen

    func test_uploads_once_flush_queue_size_events_are_queued() async throws {
        let h = try await harness(options { $0.flushQueueSize = 3 })
        await h.engine.track("A", nil)
        await h.engine.track("B", nil)
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.transport.requests.count, 0)

        await h.engine.track("C", nil)
        await h.engine.waitUntilIdle()

        XCTAssertEqual(h.transport.requests.count, 1)
        XCTAssertEqual(h.transport.sentNames, ["A", "B", "C"])
    }

    func test_uploads_every_flush_interval_and_the_timer_retries_failures() async throws {
        let h = try await harness(options { $0.flushInterval = 30 })
        await h.engine.track("A", nil)
        await h.advance(29_000)
        XCTAssertEqual(h.transport.requests.count, 0)
        await h.advance(1_000)
        XCTAssertEqual(h.transport.requests.count, 1)

        h.transport.respond(503)
        await h.engine.track("B", nil)
        await h.advance(30_000)
        XCTAssertEqual(h.transport.requests.count, 2)
        await h.advance(30_000)
        XCTAssertEqual(h.transport.requests.count, 3)
        XCTAssertEqual(h.transport.sentNames.last, "B")
    }

    func test_going_to_the_background_flushes_inside_a_background_task() async throws {
        let h = try await harness()
        await h.engine.track("A", nil)

        h.lifecycle.emit(false)
        XCTAssertEqual(h.lifecycle.backgroundTasks, ["LoopAnalytics.flush"], "begun before the handler returns")
        await h.engine.waitUntilIdle()

        XCTAssertEqual(h.transport.sentNames, ["A"])
        XCTAssertEqual(h.lifecycle.endedBackgroundTasks, 1, "ended once the flush completed")
        h.lifecycle.emit(true)
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.lifecycle.backgroundTasks.count, 1, "no background task for the foreground")
    }

    func test_coming_back_to_the_foreground_uploads_queued_events() async throws {
        let h = try await harness()
        h.lifecycle.emit(false)
        await h.engine.waitUntilIdle()
        await h.engine.track("While Away", nil)
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.transport.requests.count, 0)

        h.lifecycle.emit(true)
        await h.engine.waitUntilIdle()

        XCTAssertEqual(h.transport.sentNames, ["While Away"])
    }

    func test_sessions_roll_over_after_idle_time_in_the_background() async throws {
        let h = try await harness(options { $0.minTimeBetweenSessions = 300 })
        await h.engine.track("A", nil)
        let first = await h.engine.sessionId

        h.lifecycle.emit(false)
        await h.engine.waitUntilIdle()
        h.clock.now += 120_000
        h.lifecycle.emit(true)
        await h.engine.waitUntilIdle()
        await h.engine.track("B", nil)
        let second = await h.engine.sessionId
        XCTAssertEqual(second, first)

        h.lifecycle.emit(false)
        await h.engine.waitUntilIdle()
        h.clock.now += 360_000
        h.lifecycle.emit(true)
        await h.engine.waitUntilIdle()
        await h.engine.track("C", nil)
        let third = await h.engine.sessionId
        XCTAssertEqual(third, h.clock.now)

        await h.engine.flush()
        let ids = h.transport.sentEvents.map { $0["sessionId"] }
        XCTAssertEqual(ids, [first, first, third].map { $0.map(JSONValue.int) })
    }

    // MARK: - Engine: context

    func test_events_keep_the_purchaser_id_and_locale_they_were_tracked_with() async throws {
        let h = try await harness()
        await h.engine.track("Anonymous", nil)
        await h.engine.setPurchaserId("$RCAnonymousID:1")
        await h.engine.track("Purchased", nil)
        await h.engine.track("Purchased Again", nil)
        h.context.value.locale = "fr-FR"
        await h.engine.track("Bonjour", nil)
        await h.engine.flush()

        let requests = h.transport.requests
        XCTAssertEqual(requests.map(\.events.count), [1, 2, 1])
        let contexts = requests.map(context)
        XCTAssertEqual(contexts[0]["purchaserId"], .null)
        XCTAssertEqual(contexts[1]["purchaserId"], .string("$RCAnonymousID:1"))
        XCTAssertEqual(contexts[1]["locale"], .string("en-GB"))
        XCTAssertEqual(contexts[2]["locale"], .string("fr-FR"))
    }

    func test_events_queued_before_an_app_update_keep_the_old_app_version() async throws {
        let h = try await harness()
        h.transport.respond(503)
        await h.engine.track("Old Version", nil)
        await h.engine.flush()

        let updated = ContextBox()
        updated.value.appVersion = "1.1.0"
        let h2 = try await restart(h, context: updated)
        await h2.engine.waitUntilIdle()
        await h2.engine.track("New Version", nil)
        await h2.engine.flush()

        let requests = h2.transport.requests
        XCTAssertEqual(requests.map { $0.events.count }, [1, 1])
        XCTAssertEqual(context(requests[0])["appVersion"], .string("1.0.0"))
        XCTAssertEqual(requests[0].events.first?["name"], .string("Old Version"))
        XCTAssertEqual(context(requests[1])["appVersion"], .string("1.1.0"))
        XCTAssertEqual(requests[1].events.first?["name"], .string("New Version"))
    }

    // MARK: - Environment

    func test_privacy_manifest_declares_what_analytics_collects() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)

        let collected = try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        XCTAssertEqual(Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }), [
            "NSPrivacyCollectedDataTypeDeviceID",
            "NSPrivacyCollectedDataTypeUserID",
            "NSPrivacyCollectedDataTypeProductInteraction",
            "NSPrivacyCollectedDataTypeOtherDataTypes",
        ])
        XCTAssertEqual(collected.count, 4)
        for entry in collected {
            let type = entry["NSPrivacyCollectedDataType"] as? String ?? "?"
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, true, type)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false, type)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypePurposes"] as? [String], ["NSPrivacyCollectedDataTypePurposeAnalytics"], type)
        }

        let accessed = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        XCTAssertEqual(accessed.count, 1)
        XCTAssertEqual(accessed.first?["NSPrivacyAccessedAPIType"] as? String, "NSPrivacyAccessedAPICategoryUserDefaults")
        XCTAssertEqual(accessed.first?["NSPrivacyAccessedAPITypeReasons"] as? [String], ["CA92.1"])
    }

    func test_app_extensions_are_recognised_by_their_bundle() {
        XCTAssertTrue(isAppExtension(bundleURL: URL(fileURLWithPath: "/var/containers/Bundle/Application/X/Host.app/PlugIns/Share.appex")))
        XCTAssertFalse(isAppExtension(bundleURL: URL(fileURLWithPath: "/var/containers/Bundle/Application/X/Host.app")))
    }

    func test_queue_directory_is_created_and_excluded_from_backup() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("loop_queue_dir_\(UUID().uuidString)", isDirectory: true)
        directories.append(base)

        let file = try AnalyticsEnvironment.queueURL(in: base)

        XCTAssertEqual(file.lastPathComponent, "analytics-queue.jsonl")
        let directory = file.deletingLastPathComponent()
        XCTAssertEqual(directory.lastPathComponent, "Loop")
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isExcludedFromBackupKey])
        XCTAssertEqual(values.isDirectory, true)
        XCTAssertEqual(values.isExcludedFromBackup, true, "set on the directory: rewrites replace the file")
    }

    func test_production_ids_and_sdk_identity() throws {
        XCTAssertEqual(AnalyticsEnvironment.sdk.name, "loop-ios")
        XCTAssertEqual(AnalyticsEnvironment.sdk.version, "2.0.0")
        let id = AnalyticsEnvironment.newEventId()
        let regex = try NSRegularExpression(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
        XCTAssertEqual(regex.numberOfMatches(in: id, range: NSRange(id.startIndex..., in: id)), 1, id)
        XCTAssertNotEqual(AnalyticsEnvironment.newEventId(), id)
    }

    func test_device_context_is_captured_once_and_read_without_the_main_thread() async {
        let device = await DeviceContext.start()
        XCTAssertEqual(device.current, LoopContext.capture())
    }

    func test_timer_scheduler_ticks_until_cancelled() async throws {
        let ticks = Counter()
        let ticked = expectation(description: "two ticks")
        ticked.expectedFulfillmentCount = 2
        ticked.assertForOverFulfill = false
        let timer = TimerScheduler().every(0.02) {
            _ = ticks.next()
            ticked.fulfill()
        }
        await fulfillment(of: [ticked], timeout: 2)
        timer.cancel()
        // A tick already running when cancel() returns may still finish.
        try await Task.sleep(nanoseconds: 50_000_000)
        let settled = ticks.next()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(ticks.next(), settled + 1, "no ticks after cancel")
    }

    func test_timer_scheduler_ignores_a_non_positive_interval() async throws {
        let ticks = Counter()
        let timer = TimerScheduler().every(0) { _ = ticks.next() }
        try await Task.sleep(nanoseconds: 50_000_000)
        timer.cancel()
        XCTAssertEqual(ticks.next(), 1)
    }
}
