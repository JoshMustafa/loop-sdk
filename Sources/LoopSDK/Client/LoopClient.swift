import Foundation

/// Async API client for the public Loop ingest surface.
///
/// Wraps `URLSession` with the `Authorization` and `X-Loop-Reporter-Id`
/// headers populated from the SDK configuration. Decodes responses with
/// ISO-8601 dates and explicit camelCase keys (no `convertFromSnakeCase`,
/// the backend already returns camelCase).
public actor LoopClient {
    public struct VotePayload: Codable, Sendable {
        public let dir: VoteDir?
    }

    public struct SubmitPayload: Codable, Sendable {
        public let type: String
        public let title: String
        public let body: String
        public let reporter_id: String
        public let device_meta: DeviceMetaPayload
        // Optional dev-set business context. Phoenix's ingest treats absent
        // and explicit-null identically — both store NULL on `user_tier`.
        public let user: UserPayload?

        public init(
            type: String,
            title: String,
            body: String,
            reporter_id: String,
            device_meta: DeviceMetaPayload,
            user: UserPayload? = nil
        ) {
            self.type = type
            self.title = title
            self.body = body
            self.reporter_id = reporter_id
            self.device_meta = device_meta
            self.user = user
        }
    }

    public struct DeviceMetaPayload: Codable, Sendable {
        public let device: String
        public let os: String
        public let appVersion: String
        public let locale: String
        public let network: String
        public let sessionId: String

        public init(device: String, os: String, appVersion: String, locale: String, network: String, sessionId: String) {
            self.device = device
            self.os = os
            self.appVersion = appVersion
            self.locale = locale
            self.network = network
            self.sessionId = sessionId
        }
    }

    public struct UserPayload: Codable, Sendable {
        public let tier: String?

        public init(tier: String?) {
            self.tier = tier
        }
    }

    private let baseURL: URL
    private let apiKey: String
    private let reporterId: String
    private let session: URLSession

    public init(baseURL: URL, apiKey: String, reporterId: String, session: URLSession? = nil) {
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

    // MARK: - Public methods

    public func fetchProject() async throws -> LoopProject {
        try await send(.getProject, decoding: LoopProject.self)
    }

    public func fetchBugs(cursor: String? = nil, limit: Int = 20) async throws -> LoopItemPage {
        try await send(.listBugs(cursor: cursor, limit: limit), decoding: LoopItemPage.self)
    }

    public func fetchFeatures(cursor: String? = nil, limit: Int = 20) async throws -> LoopItemPage {
        try await send(.listFeatures(cursor: cursor, limit: limit), decoding: LoopItemPage.self)
    }

    public func vote(itemId: String, dir: VoteDir?) async throws -> LoopVoteResult {
        try await send(
            .vote(itemId: itemId),
            body: VotePayload(dir: dir),
            decoding: LoopVoteResult.self
        )
    }

    public func fetchItem(itemId: String) async throws -> LoopItemDetail {
        try await send(.getItem(itemId: itemId), decoding: LoopItemDetail.self)
    }

    public struct ReplyPayload: Codable, Sendable {
        public let body: String
    }

    public func postReply(itemId: String, body: String) async throws -> LoopReply {
        try await send(
            .postReply(itemId: itemId),
            body: ReplyPayload(body: body),
            decoding: LoopReply.self
        )
    }

    public func submit(payload: SubmitPayload) async throws -> LoopSubmissionResult {
        try await send(.submit, body: payload, decoding: LoopSubmissionResult.self)
    }

    /// Fire-and-forget POST of a pre-serialized diagnostic event body to
    /// `/api/ingest/events`. The body is built upstream with
    /// `JSONSerialization` (the payload carries arbitrary developer-supplied
    /// `context` / `breadcrumbs` maps, so we don't model it with Codable).
    /// Throws on transport failure or any non-2xx status so the caller can
    /// decide to buffer offline and retry.
    public func sendDiagnostic(body: Data) async throws {
        var request = try LoopEndpoint.captureEvent.buildRequest(
            baseURL: baseURL,
            apiKey: apiKey,
            reporterId: reporterId
        )
        request.httpBody = body
        try await executeNoContent(request)
    }

    /// Fire-and-forget POST of a pre-serialized analytics event batch to
    /// `/api/ingest/track` (expects `202 {"accepted": N}`; the body is
    /// discarded). Throws on transport failure or non-2xx so the retention
    /// engine can decide between retry (5xx/offline) and drop (4xx).
    public func sendTrackBatch(body: Data) async throws {
        var request = try LoopEndpoint.trackEvents.buildRequest(
            baseURL: baseURL,
            apiKey: apiKey,
            reporterId: reporterId
        )
        request.httpBody = body
        try await executeNoContent(request)
    }

    /// Fire-and-forget POST of funnel declarations to
    /// `/api/ingest/funnels` (idempotent server-side upsert, expects 202).
    public func sendFunnels(body: Data) async throws {
        var request = try LoopEndpoint.defineFunnels.buildRequest(
            baseURL: baseURL,
            apiKey: apiKey,
            reporterId: reporterId
        )
        request.httpBody = body
        try await executeNoContent(request)
    }

    // MARK: - Internal

    private func send<T: Decodable & Sendable>(
        _ endpoint: LoopEndpoint,
        decoding: T.Type
    ) async throws -> T {
        let request = try endpoint.buildRequest(
            baseURL: baseURL,
            apiKey: apiKey,
            reporterId: reporterId
        )
        return try await execute(request, decoding: decoding)
    }

    private func send<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ endpoint: LoopEndpoint,
        body: Body,
        decoding: T.Type
    ) async throws -> T {
        var request = try endpoint.buildRequest(
            baseURL: baseURL,
            apiKey: apiKey,
            reporterId: reporterId
        )
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(body)
        return try await execute(request, decoding: decoding)
    }

    /// Like `execute(_:decoding:)` but discards the body — used for the
    /// fire-and-forget diagnostic ingest, which returns an empty 2xx.
    private func executeNoContent(_ request: URLRequest) async throws {
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

    private func execute<T: Decodable & Sendable>(
        _ request: URLRequest,
        decoding: T.Type
    ) async throws -> T {
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
}
