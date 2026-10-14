import Foundation
import LoopCore
@testable import LoopAnalytics

extension LoopEvent {
    /// A fixed event for queue tests (port of the Dart `testEvent` helper).
    static func sample(
        id: String,
        name: String = "Test Event",
        props: JSONObject = [:],
        context: JSONObject? = nil
    ) -> LoopEvent {
        LoopEvent(
            id: id,
            name: name,
            occurredAtMillis: 1_791_968_400_000, // 2026-10-14T09:00:00.000Z
            sessionId: 1_760_432_400_000,
            deviceId: "device-1",
            userId: nil,
            props: props,
            userProps: [:],
            context: context
        )
    }
}

extension JSONValue {
    /// The value as a Foundation object for `JSONSerialization`.
    func foundation() -> Any {
        switch self {
        case .string(let s): return s
        case .number(let d): return NSNumber(value: d)
        case .int(let i): return NSNumber(value: i)
        case .bool(let b): return NSNumber(value: b)
        case .null: return NSNull()
        case .array(let a): return a.map { $0.foundation() }
        case .object(let o): return o.foundation()
        }
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    /// The object as a Foundation dictionary for `JSONSerialization`.
    func foundation() -> [String: Any] {
        mapValues { $0.foundation() }
    }
}

/// A settable clock.
final class FakeClock: LoopClock, @unchecked Sendable {
    var now: Int64

    init(_ now: Int64) { self.now = now }

    func nowMillis() -> Int64 { now }
}
