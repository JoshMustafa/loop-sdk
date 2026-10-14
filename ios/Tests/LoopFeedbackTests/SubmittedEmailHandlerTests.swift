import XCTest
@testable import LoopSDK

/// Covers the handler `LoopSubmittedView` is given, not the view itself —
/// SwiftUI layout is not unit-tested anywhere in this repo.
///
/// Two contracts. The handler exists at all only for a project that has opted
/// into email capture — `collect_email` defaults to false precisely so a
/// routine SDK bump cannot start collecting PII, and an unconditional handler
/// would break that promise on every host. And when it does exist, a failed
/// capture must never surface as a failed report: the report is already filed
/// and safe by the time this runs, so the handler turns every error into a
/// `false` and never throws.
final class SubmittedEmailHandlerTests: XCTestCase {

    private let baseURL = URL(string: "https://example.test")!
    private let apiKey = "loop_pk_pebble_aabbccdd11223344"
    private let reporterId = "r_abcd1234abcd"

    private func makeClient(session: URLSession) -> LoopClient {
        LoopClient(baseURL: baseURL, apiKey: apiKey, reporterId: reporterId, session: session)
    }

    private func project(collectEmail: Bool) -> LoopProject {
        LoopProject(
            id: "pebble",
            name: "Pebble",
            icon: "\u{1FAA8}",
            accent: "#3a2a1f",
            version: "v1.0",
            collectEmail: collectEmail
        )
    }

    private func handler(session: URLSession) -> (String) async -> Bool {
        guard let handler = LoopEmailPrompt.handler(
            client: makeClient(session: session),
            project: project(collectEmail: true)
        ) else {
            XCTFail("an opted-in project must get a handler")
            return { _ in false }
        }
        return handler
    }

    // MARK: - The opt-in gate

    /// The default configuration. Nothing is stored and no mail is sent for a
    /// project that has not opted in — POST /api/ingest/contact answers 202
    /// regardless, so that a binary-extracted key cannot enumerate which
    /// projects collect email — and the prompt would render "Check your inbox
    /// to confirm." over an email that is never coming.
    func test_no_handler_for_a_project_that_has_not_opted_in() {
        let session = MockURLProtocol.install { _ in (.with(status: 202), Data()) }

        XCTAssertNil(
            LoopEmailPrompt.handler(client: makeClient(session: session), project: project(collectEmail: false))
        )
    }

    /// Project metadata has not loaded, or the fetch failed. Silence is the
    /// safe answer: never prompt for PII on an assumption.
    func test_no_handler_before_the_project_is_known() {
        let session = MockURLProtocol.install { _ in (.with(status: 202), Data()) }

        XCTAssertNil(LoopEmailPrompt.handler(client: makeClient(session: session), project: nil))
    }

    func test_a_handler_is_built_for_a_project_that_opted_in() {
        let session = MockURLProtocol.install { _ in (.with(status: 202), Data()) }

        XCTAssertNotNil(
            LoopEmailPrompt.handler(client: makeClient(session: session), project: project(collectEmail: true))
        )
    }

    // MARK: - The swallow-the-error contract

    func test_reports_success_when_the_address_is_accepted() async {
        let session = MockURLProtocol.install { _ in (.with(status: 202), Data()) }
        let handler = self.handler(session: session)

        let accepted = await handler("reporter@example.com")

        XCTAssertTrue(accepted)
    }

    func test_a_rejected_address_returns_false_instead_of_throwing() async {
        let session = MockURLProtocol.install { _ in (.with(status: 422), Data()) }
        let handler = self.handler(session: session)

        let accepted = await handler("nope")

        XCTAssertFalse(accepted)
    }

    func test_a_server_failure_returns_false_instead_of_throwing() async {
        let session = MockURLProtocol.install { _ in (.with(status: 500), Data()) }
        let handler = self.handler(session: session)

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

        _ = await handler(session: session)("reporter@example.com")

        XCTAssertEqual(capturedPath, "/api/ingest/contact")

        let json = try? JSONSerialization.jsonObject(with: capturedBody ?? Data()) as? [String: Any]
        XCTAssertEqual((json ?? nil)?["email"] as? String, "reporter@example.com")
    }
}
