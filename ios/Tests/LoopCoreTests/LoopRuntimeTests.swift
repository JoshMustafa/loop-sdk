import XCTest
@testable import LoopCore

final class LoopRuntimeTests: XCTestCase {
    override func setUp() { LoopRuntime.shared.resetForTesting() }

    func test_default_server_is_loop_analytics_api() {
        XCTAssertEqual(LoopOptions.defaultServerURL.absoluteString, "https://loop-analytics-api.fly.dev")
        XCTAssertEqual(LoopOptions().serverUrl, LoopOptions.defaultServerURL)
    }

    func test_http_is_nil_before_configure() {
        XCTAssertNil(LoopRuntime.shared.http())
    }

    func test_configure_twice_replaces_key_but_keeps_ids() {
        Loop.configure(apiKey: "loop_pk_first_11111111")
        let reporter = Loop.reporterId
        let session = LoopRuntime.shared.sessionId
        Loop.configure(apiKey: "loop_pk_second_2222222", options: LoopOptions(serverUrl: URL(string: "https://example.test")!))
        XCTAssertEqual(LoopRuntime.shared.configuration?.apiKey, "loop_pk_second_2222222")
        XCTAssertEqual(LoopRuntime.shared.configuration?.options.serverUrl.absoluteString, "https://example.test")
        XCTAssertEqual(Loop.reporterId, reporter)
        XCTAssertEqual(LoopRuntime.shared.sessionId, session)
    }

    func test_http_uses_configured_server_and_key() throws {
        Loop.configure(apiKey: "loop_pk_first_11111111", options: LoopOptions(serverUrl: URL(string: "https://example.test")!))
        let request = try XCTUnwrap(LoopRuntime.shared.http()).makeRequest(method: "GET", path: "/api/ingest/project")
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/api/ingest/project")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer loop_pk_first_11111111")
    }

    func test_session_id_format() {
        XCTAssertTrue(LoopRuntime.shared.sessionId.hasPrefix("sess_"))
        XCTAssertEqual(LoopRuntime.shared.sessionId.count, 17)
    }
}
