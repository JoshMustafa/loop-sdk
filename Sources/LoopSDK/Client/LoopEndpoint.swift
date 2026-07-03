import Foundation

/// All public endpoints the SDK calls. Keeps URL construction in one place.
enum LoopEndpoint: Sendable {
    case getProject
    case listBugs(cursor: String?, limit: Int)
    case listFeatures(cursor: String?, limit: Int)
    case getItem(itemId: String)
    case vote(itemId: String)
    case postReply(itemId: String)
    case submit
    case captureEvent
    case trackEvents
    case defineFunnels

    var method: String {
        switch self {
        case .getProject, .listBugs, .listFeatures, .getItem: return "GET"
        case .vote, .postReply, .submit, .captureEvent, .trackEvents, .defineFunnels: return "POST"
        }
    }

    func buildRequest(baseURL: URL, apiKey: String, reporterId: String) throws -> URLRequest {
        var components = URLComponents()
        components.path = path

        switch self {
        case .listBugs(let cursor, let limit), .listFeatures(let cursor, let limit):
            var items: [URLQueryItem] = [.init(name: "limit", value: String(limit))]
            if let cursor, !cursor.isEmpty {
                items.append(.init(name: "cursor", value: cursor))
            }
            components.queryItems = items
        default:
            break
        }

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

    private var path: String {
        switch self {
        case .getProject: return "/api/ingest/project"
        case .listBugs: return "/api/ingest/bugs"
        case .listFeatures: return "/api/ingest/features"
        case .getItem(let itemId): return "/api/ingest/items/\(itemId)"
        case .vote(let itemId): return "/api/ingest/items/\(itemId)/vote"
        case .postReply(let itemId): return "/api/ingest/items/\(itemId)/replies"
        case .submit: return "/api/ingest/submissions"
        case .captureEvent: return "/api/ingest/events"
        case .trackEvents: return "/api/ingest/track"
        case .defineFunnels: return "/api/ingest/funnels"
        }
    }
}
