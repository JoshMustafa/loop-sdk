import Foundation
import LoopCore

/// Feedback routes. URL building and auth headers live in `LoopHTTP`.
enum FeedbackEndpoint: Sendable {
    case getProject
    case listBugs(cursor: String?, limit: Int)
    case listFeatures(cursor: String?, limit: Int)
    case getItem(itemId: String)
    case vote(itemId: String)
    case postReply(itemId: String)
    case submit
    case submitContact

    var method: String {
        switch self {
        case .getProject, .listBugs, .listFeatures, .getItem: return "GET"
        case .vote, .postReply, .submit, .submitContact: return "POST"
        }
    }

    var path: String {
        switch self {
        case .getProject: return "/api/ingest/project"
        case .listBugs: return "/api/ingest/bugs"
        case .listFeatures: return "/api/ingest/features"
        case .getItem(let itemId): return "/api/ingest/items/\(itemId)"
        case .vote(let itemId): return "/api/ingest/items/\(itemId)/vote"
        case .postReply(let itemId): return "/api/ingest/items/\(itemId)/replies"
        case .submit: return "/api/ingest/submissions"
        case .submitContact: return "/api/ingest/contact"
        }
    }

    var query: [URLQueryItem] {
        switch self {
        case .listBugs(let cursor, let limit), .listFeatures(let cursor, let limit):
            var items: [URLQueryItem] = [.init(name: "limit", value: String(limit))]
            if let cursor, !cursor.isEmpty {
                items.append(.init(name: "cursor", value: cursor))
            }
            return items
        default:
            return []
        }
    }

    func request(using http: LoopHTTP) throws -> URLRequest {
        try http.makeRequest(method: method, path: path, query: query)
    }
}
