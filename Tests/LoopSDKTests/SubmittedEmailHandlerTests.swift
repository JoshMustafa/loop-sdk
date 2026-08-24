import XCTest
@testable import LoopSDK

/// Covers the handler `LoopSubmittedView` is given, not the view itself —
/// SwiftUI layout is not unit-tested anywhere in this repo.
///
/// The contract that matters: a failed capture must never surface as a failed
/// report. The report is already filed and safe by the time this runs, so the
/// handler turns every error into a `false` and never throws.
final class SubmittedEmailHandlerTests: XCTestCase {

    private let baseURL = URL(string: "https://example.test")!
    private let apiKey = "loop_pk_pebble_aabbccdd11223344"
    private let reporterId = "r_abcd1234abcd"

    private func makeClient(session: URLSession) -> LoopClient {
        LoopClient(baseURL: baseURL, apiKey: apiKey, reporterId: reporterId, session: session)
    }

    func test_reports_success_when_the_address_is_accepted() async {
        let session = MockURLProtocol.install { _ in (.with(status: 202), Data()) }
        let handler = LoopEmailPrompt.handler(client: makeClient(session: session))

        let accepted = await handler("reporter@example.com")

        XCTAssertTrue(accepted)
    }

    func test_a_rejected_address_returns_false_instead_of_throwing() async {
        let session = MockURLProtocol.install { _ in (.with(status: 422), Data()) }
        let handler = LoopEmailPrompt.handler(client: makeClient(session: session))

        let accepted = await handler("nope")

        XCTAssertFalse(accepted)
    }

    func test_a_server_failure_returns_false_instead_of_throwing() async {
        let session = MockURLProtocol.install { _ in (.with(status: 500), Data()) }
        let handler = LoopEmailPrompt.handler(client: makeClient(session: session))

        let accepted = await handler("reporter@example.com")

        XCTAssertFalse(accepted)
    }

    /// The handler posts the address it is handed, unmangled, to the contact
    /// endpoint. Trimming is the prompt's job, not the handler's.
    func test_posts_the_address_to_the_contact_endpoint() async {
        var capturedPath: String?
        var capturedBody: Data?

        let session = MockURLProtocol.install { req in
            capturedPath = req.url?.path
            capturedBody = req.httpBodyStreamData()
            return (.with(status: 202), Data())
        }

        _ = await LoopEmailPrompt.handler(client: makeClient(session: session))("reporter@example.com")

        XCTAssertEqual(capturedPath, "/api/ingest/contact")

        let json = try? JSONSerialization.jsonObject(with: capturedBody ?? Data()) as? [String: Any]
        XCTAssertEqual((json ?? nil)?["email"] as? String, "reporter@example.com")
    }
}
