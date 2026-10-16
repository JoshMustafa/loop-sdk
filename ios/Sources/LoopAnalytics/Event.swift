import Foundation

/// A JSON object: event props, user properties, the context snapshot.
typealias JSONObject = [String: JSONValue]

/// A JSON value. Integers and doubles are kept apart so `1` is written as
/// `1`, never `1.0`.
enum JSONValue: Equatable, Sendable, Codable {
    case string(String)
    case number(Double)
    case int(Int64)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// One queued analytics event, exactly as it goes on the wire.
///
/// Immutable: once tracked, an event is never rewritten, so a retried batch
/// carries the same events and server-side dedup applies.
struct LoopEvent: Equatable, Sendable {
    /// UUID v4, unique per event; the server's dedup key.
    let id: String
    let name: String
    let occurredAtMillis: Int64
    /// Session start in ms since epoch, or nil.
    let sessionId: Int64?
    let deviceId: String
    let userId: String?
    let props: JSONObject
    /// The full merged user-property snapshot at the time of the event.
    let userProps: JSONObject
    /// Snapshot of the batch-level `context` taken when the event was
    /// tracked. Stored with the event but not part of the wire event: the
    /// uploader sends it as the batch context. Nil for events stored without
    /// one.
    let context: JSONObject?

    init(
        id: String,
        name: String,
        occurredAtMillis: Int64,
        sessionId: Int64?,
        deviceId: String,
        userId: String?,
        props: JSONObject,
        userProps: JSONObject,
        context: JSONObject? = nil
    ) {
        self.id = id
        self.name = name
        self.occurredAtMillis = occurredAtMillis
        self.sessionId = sessionId
        self.deviceId = deviceId
        self.userId = userId
        self.props = props
        self.userProps = userProps
        self.context = context
    }

    /// The event as sent on the wire. `sessionId` and `userId` are explicit
    /// nulls when absent.
    func wireJSON() -> JSONObject {
        [
            "id": .string(id),
            "name": .string(name),
            "occurredAt": .string(LoopTimestamp.format(millis: occurredAtMillis)),
            "sessionId": sessionId.map(JSONValue.int) ?? .null,
            "deviceId": .string(deviceId),
            "userId": userId.map(JSONValue.string) ?? .null,
            "props": .object(props),
            "userProps": .object(userProps),
        ]
    }

    /// The event as stored in the queue file: the wire event plus `context`.
    func storageJSON() -> JSONObject {
        var json = wireJSON()
        if let context { json["context"] = .object(context) }
        return json
    }

    /// Reads `wireJSON()` or `storageJSON()` output. Throws when a required
    /// field is missing or mistyped (used to skip corrupt queue lines).
    init(storageJSON json: JSONObject) throws {
        guard case .string(let id)? = json["id"],
              case .string(let name)? = json["name"],
              case .string(let occurredAt)? = json["occurredAt"],
              let occurredAtMillis = LoopTimestamp.parse(occurredAt),
              case .string(let deviceId)? = json["deviceId"]
        else { throw MalformedEventError() }

        let sessionId: Int64?
        switch json["sessionId"] {
        case nil, .null?: sessionId = nil
        case .int(let value)?: sessionId = value
        default: throw MalformedEventError()
        }

        let userId: String?
        switch json["userId"] {
        case nil, .null?: userId = nil
        case .string(let value)?: userId = value
        default: throw MalformedEventError()
        }

        let context: JSONObject?
        switch json["context"] {
        case nil, .null?: context = nil
        case .object(let value)?: context = value
        default: throw MalformedEventError()
        }

        self.init(
            id: id,
            name: name,
            occurredAtMillis: occurredAtMillis,
            sessionId: sessionId,
            deviceId: deviceId,
            userId: userId,
            props: try Self.object(json["props"]),
            userProps: try Self.object(json["userProps"]),
            context: context
        )
    }

    /// A missing or null map reads as empty; anything else must be an object.
    private static func object(_ value: JSONValue?) throws -> JSONObject {
        switch value {
        case nil, .null?: return [:]
        case .object(let object)?: return object
        default: throw MalformedEventError()
        }
    }
}

struct MalformedEventError: Error {}

/// ISO 8601 UTC timestamps with millisecond precision, e.g.
/// `2026-10-14T09:11:58.402Z`. Integer arithmetic only, so the millisecond
/// is exact.
enum LoopTimestamp {
    private static let msPerDay: Int64 = 86_400_000

    static func format(millis: Int64) -> String {
        let days = floorDiv(millis, msPerDay)
        let msOfDay = millis - days * msPerDay
        let (year, month, day) = civil(fromDays: days)
        let hour = msOfDay / 3_600_000
        let minute = msOfDay / 60_000 % 60
        let second = msOfDay / 1000 % 60
        let ms = msOfDay % 1000
        return pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2)
            + "T" + pad(hour, 2) + ":" + pad(minute, 2) + ":" + pad(second, 2)
            + "." + pad(ms, 3) + "Z"
    }

    /// Milliseconds since epoch for `YYYY-MM-DDTHH:MM:SS[.fff…]Z`, or nil.
    /// Digits past the millisecond are ignored.
    static func parse(_ string: String) -> Int64? {
        let chars = Array(string.utf8)
        guard chars.count >= 20, chars.last == UInt8(ascii: "Z"),
              chars[4] == UInt8(ascii: "-"), chars[7] == UInt8(ascii: "-"),
              chars[10] == UInt8(ascii: "T"),
              chars[13] == UInt8(ascii: ":"), chars[16] == UInt8(ascii: ":"),
              let year = number(chars[0..<4]), let month = number(chars[5..<7]),
              let day = number(chars[8..<10]), let hour = number(chars[11..<13]),
              let minute = number(chars[14..<16]), let second = number(chars[17..<19])
        else { return nil }

        var ms: Int64 = 0
        let fraction = chars[19..<(chars.count - 1)]
        if !fraction.isEmpty {
            guard fraction.first == UInt8(ascii: "."), fraction.count >= 2 else { return nil }
            let digits = fraction.dropFirst()
            guard digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else { return nil }
            for (index, byte) in digits.prefix(3).enumerated() {
                ms += Int64(byte - UInt8(ascii: "0")) * [100, 10, 1][index]
            }
        }

        guard (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second < 60 else { return nil }
        let days = days(fromCivil: year, month, day)
        // Rejects days past the end of the month (e.g. 30 February).
        guard civil(fromDays: days) == (year, month, day) else { return nil }
        return days * msPerDay + hour * 3_600_000 + minute * 60_000 + second * 1000 + ms
    }

    private static func number(_ digits: ArraySlice<UInt8>) -> Int64? {
        guard !digits.isEmpty, digits.count <= 18 else { return nil }
        var value: Int64 = 0
        for byte in digits {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int64(byte - UInt8(ascii: "0"))
        }
        return value
    }

    private static func pad(_ value: Int64, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    // Days since 1970-01-01 ↔ proleptic Gregorian date (H. Hinnant's algorithms).

    private static func civil(fromDays days: Int64) -> (Int64, Int64, Int64) {
        let z = days + 719_468
        let era = floorDiv(z, 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }

    private static func days(fromCivil year: Int64, _ month: Int64, _ day: Int64) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = floorDiv(y, 400)
        let yoe = y - era * 400
        let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
