import Foundation

/// Lightweight URLProtocol stub. Tests register a handler that maps a
/// `URLRequest` to a `(HTTPURLResponse, Data)` pair before exercising
/// Loop clients. No network ever happens.
public final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    public typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) public static var handler: Handler?

    public static func install(handler: @escaping Handler) -> URLSession {
        Self.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    public override class func canInit(with request: URLRequest) -> Bool { true }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        guard let handler = Self.handler else {
            fatalError("MockURLProtocol used without a registered handler")
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    public override func stopLoading() {}
}

extension HTTPURLResponse {
    public static func with(status: Int, url: URL = URL(string: "https://example.test")!) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}
