import XCTest
import LoopCore
import LoopTestSupport
@testable import LoopDiagnostics

final class DiagnosticsTests: XCTestCase {

    // MARK: - Behavior 1: ring-buffer cap + recency

    func test_breadcrumb_buffer_caps_at_20_keeping_most_recent() {
        let buffer = BreadcrumbBuffer()
        for i in 0..<25 {
            buffer.record(message: "crumb-\(i)", fail: false)
        }
        let crumbs = buffer.snapshot()
        XCTAssertEqual(crumbs.count, 20)
        // Oldest (crumb-0 … crumb-4) dropped; most recent kept.
        XCTAssertEqual(crumbs.first?.message, "crumb-5")
        XCTAssertEqual(crumbs.last?.message, "crumb-24")
    }

    // MARK: - Behavior 2: relative-`t` formatting

    func test_relative_t_formats_seconds_before_capture() {
        let capture = Date(timeIntervalSince1970: 1_000_000)
        let crumb = Breadcrumb(
            message: "tapped save",
            fail: true,
            timestamp: capture.addingTimeInterval(-6.1)
        )
        let rendered = BreadcrumbFormatter.render(crumb, relativeTo: capture)
        XCTAssertEqual(rendered["t"] as? String, "-6.1s")
        XCTAssertEqual(rendered["msg"] as? String, "tapped save")
        XCTAssertEqual(rendered["fail"] as? Bool, true)
    }

    func test_relative_t_most_recent_is_near_zero_and_omits_false_fail() {
        let capture = Date(timeIntervalSince1970: 1_000_000)
        let crumb = Breadcrumb(
            message: "loaded screen",
            fail: false,
            timestamp: capture.addingTimeInterval(-0.04)
        )
        let rendered = BreadcrumbFormatter.render(crumb, relativeTo: capture)
        XCTAssertEqual(rendered["t"] as? String, "0.0s")
        XCTAssertEqual(rendered["msg"] as? String, "loaded screen")
        // fail omitted when false
        XCTAssertNil(rendered["fail"])
    }

    // MARK: - Behavior 3: payload shape

    /// Builds an engine wired to the mock session and a fixed configuration.
    private func makeEngine(
        session: URLSession,
        tier: String? = "paid"
    ) -> DiagnosticsEngine {
        let provider: LoopOptions.TierProvider? = tier.map { value in { value } }
        let client = DiagnosticsClient(http: LoopHTTP(
            baseURL: URL(string: "https://example.test")!,
            apiKey: "loop_pk_test_aabbccdd11223344",
            reporterId: "r_abcd1234abcd",
            session: session
        ))
        return DiagnosticsEngine(
            sender: client,
            sessionId: "sess_test_1234",
            tierProvider: provider,
            store: OfflineBufferStore(directory: makeTempDir())
        )
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("loop-diag-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_capture_posts_expected_payload_shape() async throws {
        let captured = CapturedRequest()
        let session = MockURLProtocol.install { req in
            captured.body = req.httpBodyStreamData()
            captured.path = req.url?.path
            captured.method = req.httpMethod
            captured.auth = req.value(forHTTPHeaderField: "Authorization")
            captured.reporter = req.value(forHTTPHeaderField: "X-Loop-Reporter-Id")
            return (.with(status: 202), Data("{}".utf8))
        }

        let engine = makeEngine(session: session)
        engine.breadcrumb("opened settings", fail: false)
        engine.breadcrumb("tapped export", fail: true)

        try await engine.capture(
            "ExportFailed",
            severity: .error,
            title: "Export failed",
            culprit: "ExportService.run",
            context: ["screen": "settings"]
        )

        XCTAssertEqual(captured.path, "/api/ingest/events")
        XCTAssertEqual(captured.method, "POST")
        XCTAssertEqual(captured.auth, "Bearer loop_pk_test_aabbccdd11223344")
        XCTAssertEqual(captured.reporter, "r_abcd1234abcd")

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: captured.body ?? Data()) as? [String: Any]
        )
        XCTAssertEqual(json["fingerprint"] as? String, "ExportFailed")
        XCTAssertEqual(json["title"] as? String, "Export failed")
        XCTAssertEqual(json["culprit"] as? String, "ExportService.run")
        XCTAssertEqual(json["severity"] as? String, "error")

        let occurred = try XCTUnwrap(json["occurred_at"] as? String)
        // ISO8601 millis, UTC: ends with Z and has a .mmm fractional part.
        XCTAssertTrue(occurred.hasSuffix("Z"), "got \(occurred)")
        XCTAssertTrue(occurred.contains("."), "expected millis: \(occurred)")

        let context = try XCTUnwrap(json["context"] as? [String: Any])
        XCTAssertEqual(context["screen"] as? String, "settings")

        let crumbs = try XCTUnwrap(json["breadcrumbs"] as? [[String: Any]])
        XCTAssertEqual(crumbs.count, 2)
        XCTAssertEqual(crumbs.first?["msg"] as? String, "opened settings")
        XCTAssertEqual(crumbs.last?["msg"] as? String, "tapped export")
        XCTAssertEqual(crumbs.last?["fail"] as? Bool, true)
        XCTAssertNil(crumbs.first?["fail"]) // false omitted

        let device = try XCTUnwrap(json["device_meta"] as? [String: Any])
        XCTAssertEqual(device["sessionId"] as? String, "sess_test_1234")
        XCTAssertFalse((device["device"] as? String ?? "").isEmpty)

        let user = try XCTUnwrap(json["user"] as? [String: Any])
        XCTAssertEqual(user["tier"] as? String, "paid")
    }

    func test_capture_severity_defaults_to_error() async throws {
        let captured = CapturedRequest()
        let session = MockURLProtocol.install { req in
            captured.body = req.httpBodyStreamData()
            return (.with(status: 202), Data("{}".utf8))
        }
        let engine = makeEngine(session: session)
        try await engine.capture("SomethingHappened")

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: captured.body ?? Data()) as? [String: Any]
        )
        XCTAssertEqual(json["severity"] as? String, "error")
    }

    // MARK: - Behavior 5: rate-limit drop per fingerprint

    func test_rate_limit_drops_rapid_repeat_of_same_fingerprint() async throws {
        let counter = RequestCounter()
        let session = MockURLProtocol.install { _ in
            counter.increment()
            return (.with(status: 202), Data("{}".utf8))
        }
        let engine = makeEngine(session: session)

        // Three rapid captures of the same fingerprint — only the first
        // should hit the network.
        try await engine.capture("Boom")
        try await engine.capture("Boom")
        try await engine.capture("Boom")

        XCTAssertEqual(counter.value, 1)

        // A different fingerprint is not rate-limited against "Boom".
        try await engine.capture("OtherBoom")
        XCTAssertEqual(counter.value, 2)
    }

    // MARK: - Public API surface

    func test_calls_before_configure_do_not_crash_or_send() async throws {
        // Must never crash or send if Loop.configure was never called.
        LoopRuntime.shared.resetForTesting(store: ReporterStore(service: "io.loop.sdk.tests.\(UUID().uuidString)"))
        XCTAssertNil(DiagnosticsRuntime.shared.engine())
        LoopDiagnostics.breadcrumb("no config yet")
        LoopDiagnostics.capture("NoConfig", severity: .warning)
        XCTAssertNil(DiagnosticsRuntime.shared.engine())
    }

    func test_offline_buffer_directory_is_unchanged_for_upgrades() {
        XCTAssertEqual(OfflineBufferStore.defaultDirectoryName, "LoopSDKDiagnostics")
    }

    func test_diagnostics_post_to_events_route() async throws {
        var path: String?
        let session = MockURLProtocol.install { req in
            path = req.url?.path
            return (.with(status: 201), Data())
        }
        let client = DiagnosticsClient(http: LoopHTTP(baseURL: URL(string: "https://example.test")!,
            apiKey: "loop_pk_pebble_aabbccdd11223344", reporterId: "r_abcd1234abcd", session: session))
        try await client.send(body: Data("{}".utf8))
        XCTAssertEqual(path, "/api/ingest/events")
    }

    // MARK: - Behavior 6: offline buffer + retry

    func test_failed_post_is_buffered_then_flushed_on_next_capture() async throws {
        let store = OfflineBufferStore(directory: makeTempDir())
        let mode = MockMode()
        let successfulBodies = SentBodies()

        let session = MockURLProtocol.install { req in
            if mode.failNext {
                // First send: server error → triggers offline buffering.
                return (.with(status: 500), Data(#"{"error":"down"}"#.utf8))
            } else {
                successfulBodies.append(req.httpBodyStreamData())
                return (.with(status: 202), Data("{}".utf8))
            }
        }

        let provider: LoopOptions.TierProvider? = { "free" }
        let client = DiagnosticsClient(http: LoopHTTP(
            baseURL: URL(string: "https://example.test")!,
            apiKey: "loop_pk_test_aabbccdd11223344",
            reporterId: "r_abcd1234abcd",
            session: session
        ))
        let engine = DiagnosticsEngine(
            sender: client,
            sessionId: "sess_test_1234",
            tierProvider: provider,
            store: store
        )

        // First capture fails to send → should be buffered.
        mode.failNext = true
        try await engine.capture("OfflineCase", title: "first")
        XCTAssertEqual(store.pendingCount(), 1, "failed payload should be buffered")
        XCTAssertEqual(successfulBodies.count, 0)

        // Second capture (different fingerprint, so not rate-limited) now
        // succeeds → buffered payload is flushed AND the new one is sent.
        mode.failNext = false
        try await engine.capture("SecondCase", title: "second")

        XCTAssertEqual(store.pendingCount(), 0, "buffer should be drained")
        // Two successful sends: the previously-buffered one + the new one.
        XCTAssertEqual(successfulBodies.count, 2)

        // The flushed payload retains its original fingerprint/title.
        let fingerprints = successfulBodies.all.compactMap { data -> String? in
            (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["fingerprint"] as? String
        }
        XCTAssertTrue(fingerprints.contains("OfflineCase"))
        XCTAssertTrue(fingerprints.contains("SecondCase"))
    }
}

final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class MockMode: @unchecked Sendable {
    private let lock = NSLock()
    private var _failNext = false
    var failNext: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failNext }
        set { lock.lock(); _failNext = newValue; lock.unlock() }
    }
}

final class SentBodies: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []
    func append(_ data: Data?) { lock.lock(); if let data { bodies.append(data) }; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return bodies.count }
    var all: [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
}

/// Mutable box so the mock handler closure (non-escaping capture rules) can
/// hand captured request fields back to the test body.
final class CapturedRequest: @unchecked Sendable {
    var body: Data?
    var path: String?
    var method: String?
    var auth: String?
    var reporter: String?
}

final class DiagnosticsRuntimeTests: XCTestCase {
    private var store: ReporterStore!

    override func setUp() {
        store = ReporterStore(service: "io.loop.sdk.tests.\(UUID().uuidString)")
        LoopRuntime.shared.resetForTesting(store: store)
    }

    override func tearDown() { store.reset() }

    func test_reconfiguring_with_a_new_tier_provider_rebuilds_the_engine() throws {
        Loop.configure(apiKey: "loop_pk_pebble_aabbccdd11223344", options: LoopOptions(tierProvider: { "free" }))
        let first = try XCTUnwrap(DiagnosticsRuntime.shared.engine())
        Loop.configure(apiKey: "loop_pk_pebble_aabbccdd11223344", options: LoopOptions(tierProvider: { "paid" }))
        let second = try XCTUnwrap(DiagnosticsRuntime.shared.engine())
        XCTAssertFalse(first === second)
    }

    func test_engine_is_reused_while_configuration_is_unchanged() throws {
        Loop.configure(apiKey: "loop_pk_pebble_aabbccdd11223344")
        let first = try XCTUnwrap(DiagnosticsRuntime.shared.engine())
        XCTAssertTrue(first === DiagnosticsRuntime.shared.engine())
    }
}

