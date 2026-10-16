import Foundation

/// A bug or feature submission as visible to the SDK end-user. Mirrors the
/// public JSON shape from the backend (camelCase, no device meta).
public struct LoopItem: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, Equatable {
        case bug
        case feature
    }

    /// Per-kind statuses. The set is open-ended on purpose — the backend may
    /// add new statuses without breaking the SDK; unknown values decode to
    /// `.other(rawValue)`.
    public enum Status: Codable, Sendable, Equatable, Hashable {
        case open
        case planned
        case inProgress
        case triaged
        case resolved
        case shipped
        case wontFix
        case other(String)

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Self.from(rawValue: raw)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }

        public var rawValue: String {
            switch self {
            case .open: return "open"
            case .planned: return "planned"
            case .inProgress: return "in-progress"
            case .triaged: return "triaged"
            case .resolved: return "resolved"
            case .shipped: return "shipped"
            case .wontFix: return "wont-fix"
            case .other(let s): return s
            }
        }

        static func from(rawValue: String) -> Status {
            switch rawValue {
            case "open": return .open
            case "planned": return .planned
            case "in-progress": return .inProgress
            case "triaged": return .triaged
            case "resolved": return .resolved
            case "shipped": return .shipped
            case "wont-fix": return .wontFix
            default: return .other(rawValue)
            }
        }

        /// True for terminal states (resolved / shipped / wont-fix).
        public var isClosed: Bool {
            switch self {
            case .resolved, .shipped, .wontFix: return true
            default: return false
            }
        }
    }

    public let id: String          // "LP-####"
    public let kind: Kind
    public let status: Status
    public let title: String
    public let body: String
    public let whenLabel: String
    public let createdAt: Date
    public let votes: Int
    public let my: VoteDir?
    public let replyCount: Int

    public init(
        id: String,
        kind: Kind,
        status: Status,
        title: String,
        body: String,
        whenLabel: String,
        createdAt: Date,
        votes: Int,
        my: VoteDir?,
        replyCount: Int
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.title = title
        self.body = body
        self.whenLabel = whenLabel
        self.createdAt = createdAt
        self.votes = votes
        self.my = my
        self.replyCount = replyCount
    }
}

/// Page returned by the public list endpoints.
public struct LoopItemPage: Codable, Sendable, Equatable {
    public let items: [LoopItem]
    public let nextCursor: String?
}

/// A single entry in an item's reply thread.
public struct LoopReply: Codable, Sendable, Equatable, Identifiable {
    public enum From: String, Codable, Sendable, Equatable {
        case user
        case dev
    }

    public let id: String
    public let itemId: String
    public let from: From
    /// Anonymous reporter id when `from == .user`. Nil when `from == .dev`.
    public let reporter: String?
    /// Dev's display name when `from == .dev`. Nil when `from == .user`.
    public let authorName: String?
    public let body: String
    public let votes: Int
    public let my: VoteDir?
    public let createdAt: Date
    public let whenLabel: String
}

/// Anonymous device meta the original reporter's SDK attached on submit.
public struct LoopItemMeta: Codable, Sendable, Equatable {
    public let device: String?
    public let os: String?
    public let appVersion: String?
    public let locale: String?
    public let network: String?
    public let sessionId: String?
}

/// Full detail response — the item plus its thread and the device meta the
/// original reporter's SDK attached. Returned by `GET /api/ingest/items/:id`.
public struct LoopItemDetail: Codable, Sendable, Equatable {
    public let id: String
    public let kind: LoopItem.Kind
    public let status: LoopItem.Status
    public let title: String
    public let body: String
    public let whenLabel: String
    public let createdAt: Date
    public let votes: Int
    public let my: VoteDir?
    public let replyCount: Int
    public let thread: [LoopReply]
    public let meta: LoopItemMeta?

    /// Convenience getter for embedding the detail back into the list view.
    public var asItem: LoopItem {
        LoopItem(
            id: id, kind: kind, status: status,
            title: title, body: body,
            whenLabel: whenLabel, createdAt: createdAt,
            votes: votes, my: my, replyCount: replyCount
        )
    }
}
