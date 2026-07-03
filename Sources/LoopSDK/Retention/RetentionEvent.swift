import Foundation

/// A sanitized scalar property value attached to an analytics event.
/// Only String/Int/Double/Bool survive sanitization — everything else is
/// dropped before an event is buffered (see `RetentionSanitizer`).
enum RetentionPropValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

extension RetentionPropValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Order matters: JSON `true` must not decode as Int, and `30`
        // must stay an Int rather than widening to Double.
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}

/// One buffered analytics event, exactly as it rides on the wire inside
/// `POST /api/ingest/track`'s `events` array. `occurredAt` is frozen to an
/// ISO8601 string at track time so buffered events keep their original
/// timestamp across retries and relaunches.
struct RetentionEvent: Codable, Equatable, Sendable {
    let name: String
    let occurredAt: String
    let sessionId: String
    let props: [String: RetentionPropValue]
    let userId: String?

    enum CodingKeys: String, CodingKey {
        case name, occurredAt, sessionId, props, userId
    }

    /// Custom encode so `userId` serializes as an explicit `null` (the
    /// frozen wire contract shows `"userId":null`) instead of being
    /// omitted like Codable's default optional handling would.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(occurredAt, forKey: .occurredAt)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(props, forKey: .props)
        try container.encode(userId, forKey: .userId)
    }
}

/// A funnel declaration queued by `LoopSDK.defineFunnel` and upserted
/// server-side via `POST /api/ingest/funnels`. Field names match the wire
/// contract exactly.
struct FunnelDefinition: Codable, Equatable, Sendable {
    let key: String
    let name: String
    let steps: [String]
    let windowDays: Int
    let activation: Bool
}

/// Body of `POST /api/ingest/track`.
struct RetentionTrackBatch: Encodable {
    let platform: String
    let appVersion: String
    let events: [RetentionEvent]
}

/// Body of `POST /api/ingest/funnels`.
struct RetentionFunnelBatch: Encodable {
    let funnels: [FunnelDefinition]
}
