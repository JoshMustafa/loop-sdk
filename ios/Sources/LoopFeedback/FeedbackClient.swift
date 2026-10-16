import Foundation
import LoopCore

/// Talks to the feedback routes: project, items, votes, replies,
/// submissions and the optional post-submit email.
package actor FeedbackClient {
    package struct VotePayload: Codable, Sendable {
        package let dir: VoteDir?
    }

    package struct SubmitPayload: Codable, Sendable {
        package let type: String
        package let title: String
        package let body: String
        package let reporter_id: String
        package let device_meta: DeviceMetaPayload
        // Optional dev-set business context. Phoenix's ingest treats absent
        // and explicit-null identically — both store NULL on `user_tier`.
        package let user: UserPayload?

        package init(
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

    package struct DeviceMetaPayload: Codable, Sendable {
        package let device: String
        package let os: String
        package let appVersion: String
        package let locale: String
        package let network: String
        package let sessionId: String

        package init(device: String, os: String, appVersion: String, locale: String, network: String, sessionId: String) {
            self.device = device
            self.os = os
            self.appVersion = appVersion
            self.locale = locale
            self.network = network
            self.sessionId = sessionId
        }
    }

    package struct UserPayload: Codable, Sendable {
        package let tier: String?

        package init(tier: String?) {
            self.tier = tier
        }
    }

    package struct ReplyPayload: Codable, Sendable {
        package let body: String
    }

    private let http: LoopHTTP

    package init(http: LoopHTTP) {
        self.http = http
    }

    // MARK: - Routes

    package func fetchProject() async throws -> LoopProject {
        try await http.execute(try FeedbackEndpoint.getProject.request(using: http), decoding: LoopProject.self)
    }

    package func fetchBugs(cursor: String? = nil, limit: Int = 20) async throws -> LoopItemPage {
        try await http.execute(
            try FeedbackEndpoint.listBugs(cursor: cursor, limit: limit).request(using: http),
            decoding: LoopItemPage.self
        )
    }

    package func fetchFeatures(cursor: String? = nil, limit: Int = 20) async throws -> LoopItemPage {
        try await http.execute(
            try FeedbackEndpoint.listFeatures(cursor: cursor, limit: limit).request(using: http),
            decoding: LoopItemPage.self
        )
    }

    package func fetchItem(itemId: String) async throws -> LoopItemDetail {
        try await http.execute(
            try FeedbackEndpoint.getItem(itemId: itemId).request(using: http),
            decoding: LoopItemDetail.self
        )
    }

    package func vote(itemId: String, dir: VoteDir?) async throws -> LoopVoteResult {
        try await post(.vote(itemId: itemId), body: VotePayload(dir: dir), decoding: LoopVoteResult.self)
    }

    package func postReply(itemId: String, body: String) async throws -> LoopReply {
        try await post(.postReply(itemId: itemId), body: ReplyPayload(body: body), decoding: LoopReply.self)
    }

    package func submit(payload: SubmitPayload) async throws -> LoopSubmissionResult {
        try await post(.submit, body: payload, decoding: LoopSubmissionResult.self)
    }

    /// Attaches an optional email address to this device's anonymous reporter id.
    ///
    /// Deliberately separate from `submit(payload:)`: the prompt appears AFTER a
    /// report is filed, so the report path stays frictionless and a rejected
    /// address never costs someone their bug report.
    ///
    /// The SDK does not keep the address. It posts it and forgets it — Keychain
    /// holds only the anonymous reporter id, as it always has.
    package func submitContact(email: String) async throws {
        struct ContactPayload: Encodable { let email: String }
        var request = try FeedbackEndpoint.submitContact.request(using: http)
        request.httpBody = try JSONEncoder().encode(ContactPayload(email: email))
        try await http.executeNoContent(request)
    }

    // MARK: - Internal

    private func post<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ endpoint: FeedbackEndpoint,
        body: Body,
        decoding: T.Type
    ) async throws -> T {
        var request = try endpoint.request(using: http)
        request.httpBody = try JSONEncoder().encode(body)
        return try await http.execute(request, decoding: decoding)
    }
}
