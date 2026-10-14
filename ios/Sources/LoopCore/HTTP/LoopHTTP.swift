import Foundation

/// Authenticated JSON HTTP for every Loop module: builds requests with the
/// `Authorization` and `X-Loop-Reporter-Id` headers and maps status codes to
/// `LoopError`. Responses decode with ISO-8601 dates and the backend's
/// camelCase keys as-is.
package struct LoopHTTP: Sendable {
    package let baseURL: URL
    package let apiKey: String
    package let reporterId: String
    private let session: URLSession

    package init(baseURL: URL, apiKey: String, reporterId: String, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.reporterId = reporterId
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 300
            config.waitsForConnectivity = true
            self.session = URLSession(configuration: config)
        }
    }

    package func makeRequest(method: String, path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        var components = URLComponents()
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url(relativeTo: baseURL)?.absoluteURL else {
            throw LoopError.unknown(status: -1)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(reporterId, forHTTPHeaderField: "X-Loop-Reporter-Id")
        return request
    }

    package func execute<T: Decodable & Sendable>(_ request: URLRequest, decoding: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw LoopError.transport(error.code)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LoopError.unknown(status: -1)
        }

        switch http.statusCode {
        case 200..<300:
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(T.self, from: data)
            } catch {
                throw LoopError.decoding(String(describing: error))
            }

        case 400:
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw LoopError.badRequest(message: message)

        case 401, 403:
            throw LoopError.invalidApiKey

        case 404:
            throw LoopError.notFound

        case 500..<600:
            throw LoopError.serverError(status: http.statusCode)

        default:
            throw LoopError.unknown(status: http.statusCode)
        }
    }

    /// Like `execute(_:decoding:)` but discards the body — for fire-and-forget
    /// posts that return an empty 2xx.
    package func executeNoContent(_ request: URLRequest) async throws {
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw LoopError.transport(error.code)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LoopError.unknown(status: -1)
        }

        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw LoopError.invalidApiKey
        case 400..<500:
            throw LoopError.unknown(status: http.statusCode)
        default:
            throw LoopError.serverError(status: http.statusCode)
        }
    }
}
