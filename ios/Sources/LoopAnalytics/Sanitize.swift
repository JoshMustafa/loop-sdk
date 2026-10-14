import Foundation

/// Event-name validation and property sanitising.
enum Sanitize {
    /// Server limit on event names (after trimming).
    static let maxEventNameLength = 128

    /// True when `name` is accepted by the server: 1–128 characters once
    /// trimmed (counted in UTF-16 code units, as the reference SDK does). The
    /// name itself is sent verbatim; it is never rewritten.
    static func isValidEventName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf16.count <= maxEventNameLength
    }

    /// Makes event/user properties safe to JSON-encode.
    ///
    /// Null values (`nil`, `NSNull`, `JSONValue.null`) are stripped from maps;
    /// lists keep their positions. Strings, bools, finite numbers, arrays and
    /// dictionaries pass through; sets become arrays, map keys become strings,
    /// `Date` becomes an ISO 8601 UTC string, `URL` its absolute string,
    /// non-finite numbers and anything else their `description`. Nothing is
    /// truncated.
    static func props(_ props: [String: Any?]?) -> JSONObject {
        guard let props else { return [:] }
        var out: JSONObject = [:]
        for (key, value) in props {
            guard let value = value.flatMap(unwrap) else { continue }
            let sanitized = sanitize(value)
            if sanitized != .null { out[key] = sanitized }
        }
        return out
    }

    private static func sanitize(_ value: Any) -> JSONValue {
        guard let value = unwrap(value) else { return .null }

        // An Objective-C NSNumber (e.g. from JSONSerialization or a bridged
        // collection) would also match `as Bool` / `as Int` below, so read its
        // real type first. Native Swift numbers are not NSNumber subclasses.
        if type(of: value) is NSNumber.Type, let number = value as? NSNumber {
            return sanitize(number)
        }

        switch value {
        case let json as JSONValue:
            return json
        case let string as String:
            return .string(string)
        case let bool as Bool:
            return .bool(bool)
        case let integer as any BinaryInteger:
            return integerValue(integer)
        case let double as Double:
            return double.isFinite ? .number(double) : .string("\(double)")
        case let float as any BinaryFloatingPoint:
            return floatingValue(float)
        case let decimal as Decimal:
            return sanitize(NSDecimalNumber(decimal: decimal))
        case let date as Date:
            return dateValue(date)
        case let url as URL:
            return .string(url.absoluteString)
        case let dictionary as [AnyHashable: Any]:
            var out: JSONObject = [:]
            for (key, element) in dictionary {
                let sanitized = sanitize(element)
                if sanitized != .null { out[String(describing: key.base)] = sanitized }
            }
            return .object(out)
        case let array as [Any]:
            return .array(array.map(sanitize))
        case let set as NSSet:
            return .array(set.allObjects.map(sanitize))
        default:
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .collection || mirror.displayStyle == .set {
                return .array(mirror.children.map { sanitize($0.value) })
            }
            return .string(String(describing: value))
        }
    }

    private static func sanitize(_ number: NSNumber) -> JSONValue {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .bool(number.boolValue)
        }
        switch String(cString: number.objCType) {
        case "f", "d":
            let double = number.doubleValue
            return double.isFinite ? .number(double) : .string("\(double)")
        case "Q", "L", "I":
            let unsigned = number.uint64Value
            return unsigned <= UInt64(Int64.max) ? .int(Int64(unsigned)) : .number(Double(unsigned))
        default:
            return .int(number.int64Value)
        }
    }

    private static func integerValue(_ integer: some BinaryInteger) -> JSONValue {
        if let exact = Int64(exactly: integer) { return .int(exact) }
        return .number(Double(integer))
    }

    /// Float, CGFloat, Float16…: via the shortest decimal form so `Float(9.99)`
    /// stays 9.99 instead of 9.989999771118164.
    private static func floatingValue(_ float: some BinaryFloatingPoint) -> JSONValue {
        guard float.isFinite else { return .string("\(float)") }
        return .number(Double("\(float)") ?? Double(float))
    }

    private static func dateValue(_ date: Date) -> JSONValue {
        let micros = (date.timeIntervalSince1970 * 1_000_000).rounded()
        guard let millis = Int64(exactly: (micros / 1000).rounded(.down)) else {
            return .string(String(describing: date))
        }
        return .string(LoopTimestamp.format(millis: millis))
    }

    /// The wrapped value of an `Optional` hidden inside `Any`, recursively;
    /// nil for `nil` and `NSNull`.
    private static func unwrap(_ value: Any) -> Any? {
        if value is NSNull { return nil }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        guard let wrapped = mirror.children.first?.value else { return nil }
        return unwrap(wrapped)
    }
}
