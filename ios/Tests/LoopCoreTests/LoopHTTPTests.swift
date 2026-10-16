import XCTest
import LoopTestSupport
@testable import LoopCore

final class LoopHTTPTests: XCTestCase {
    private func makeHTTP(handler: @escaping MockURLProtocol.Handler = { req in (.with(status: 200, url: req.url!), Data()) }) -> LoopHTTP {
        LoopHTTP(baseURL: URL(string: "https://example.test")!, apiKey: "loop_pk_pebble_aabbccdd11223344",
                 reporterId: "r_abcd1234abcd", session: MockURLProtocol.install(handler: handler))
    }

    func test_request_carries_auth_reporter_and_json_headers() throws {
        let request = try makeHTTP().makeRequest(method: "POST", path: "/api/ingest/events")
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/api/ingest/events")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer loop_pk_pebble_aabbccdd11223344")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Loop-Reporter-Id"), "r_abcd1234abcd")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func test_query_items_are_encoded() throws {
        let request = try makeHTTP().makeRequest(method: "GET", path: "/api/ingest/bugs",
                                                 query: [URLQueryItem(name: "limit", value: "20")])
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/api/ingest/bugs?limit=20")
    }

    func test_401_maps_to_invalid_api_key() async throws {
        let http = makeHTTP { req in (.with(status: 401, url: req.url!), Data()) }
        do {
            try await http.executeNoContent(try http.makeRequest(method: "POST", path: "/x"))
            XCTFail("expected error")
        } catch let error as LoopError {
            XCTAssertEqual(error, .invalidApiKey)
        }
    }

    func test_400_carries_server_message() async throws {
        let http = makeHTTP { req in (.with(status: 400, url: req.url!), Data(#"{"error":"bad reporter id"}"#.utf8)) }
        struct Empty: Decodable, Sendable {}
        do {
            _ = try await http.execute(try http.makeRequest(method: "GET", path: "/x"), decoding: Empty.self)
            XCTFail("expected error")
        } catch let error as LoopError {
            XCTAssertEqual(error, .badRequest(message: "bad reporter id"))
        }
    }
}
