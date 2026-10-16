import XCTest
@testable import LoopAnalytics

final class EventTests: XCTestCase {
    private let event = LoopEvent(
        id: "6f1c2a9e-0000-4000-8000-000000000001",
        name: "Purchase Completed",
        occurredAtMillis: 1_791_969_118_402, // 2026-10-14T09:11:58.402Z
        sessionId: 1_760_432_400_000,
        deviceId: "B3F1",
        userId: "12345",
        props: ["Plan": .string("annual"), "Restored": .bool(false)],
        userProps: ["Total Diary Entries": .int(412)]
    )

    func test_encodes_the_contract_field_names_with_ms_precision_utc_time() {
        XCTAssertEqual(event.wireJSON(), [
            "id": .string("6f1c2a9e-0000-4000-8000-000000000001"),
            "name": .string("Purchase Completed"),
            "occurredAt": .string("2026-10-14T09:11:58.402Z"),
            "sessionId": .int(1_760_432_400_000),
            "deviceId": .string("B3F1"),
            "userId": .string("12345"),
            "props": .object(["Plan": .string("annual"), "Restored": .bool(false)]),
            "userProps": .object(["Total Diary Entries": .int(412)]),
        ])
    }

    func test_keeps_null_session_id_and_user_id_as_explicit_nulls() {
        let anon = LoopEvent(
            id: "x", name: "App Opened", occurredAtMillis: 1_767_225_600_000,
            sessionId: nil, deviceId: "d", userId: nil, props: [:], userProps: [:]
        )
        let json = anon.wireJSON()
        XCTAssertEqual(json["sessionId"], .null)
        XCTAssertEqual(json["userId"], .null)
        XCTAssertEqual(json["occurredAt"], .string("2026-01-01T00:00:00.000Z"))
    }

    func test_round_trips_through_json() throws {
        let data = try JSONEncoder().encode(event.wireJSON())
        let decoded = try LoopEvent(storageJSON: JSONDecoder().decode(JSONObject.self, from: data))
        XCTAssertEqual(decoded, event)
        XCTAssertEqual(decoded.wireJSON(), event.wireJSON())
    }

    func test_the_context_snapshot_is_stored_but_not_part_of_the_wire_event() throws {
        let withContext = LoopEvent(
            id: "x", name: "A", occurredAtMillis: 1_767_225_600_000,
            sessionId: nil, deviceId: "d", userId: nil, props: [:], userProps: [:],
            context: ["platform": .string("ios"), "appVersion": .string("5.2.0 (812)")]
        )
        XCTAssertNil(withContext.wireJSON()["context"])
        let stored = withContext.storageJSON()
        XCTAssertEqual(stored["context"], .object(["platform": .string("ios"), "appVersion": .string("5.2.0 (812)")]))
        let data = try JSONEncoder().encode(stored)
        let decoded = try LoopEvent(storageJSON: JSONDecoder().decode(JSONObject.self, from: data))
        XCTAssertEqual(decoded.context, withContext.context)
        XCTAssertEqual(decoded.wireJSON(), withContext.wireJSON())
    }

    func test_a_stored_event_without_a_context_snapshot_loads_with_null() throws {
        XCTAssertNil(try LoopEvent(storageJSON: event.wireJSON()).context)
    }

    func test_from_json_rejects_malformed_input() {
        XCTAssertThrowsError(try LoopEvent(storageJSON: ["name": .string("x")]))
        var badTime = event.wireJSON()
        badTime["occurredAt"] = .string("yesterday")
        XCTAssertThrowsError(try LoopEvent(storageJSON: badTime))
        var badSession = event.wireJSON()
        badSession["sessionId"] = .string("1")
        XCTAssertThrowsError(try LoopEvent(storageJSON: badSession))
    }

    func test_missing_props_load_as_empty_maps() throws {
        var json = event.wireJSON()
        json["props"] = nil
        json["userProps"] = nil
        let decoded = try LoopEvent(storageJSON: json)
        XCTAssertEqual(decoded.props, [:])
        XCTAssertEqual(decoded.userProps, [:])
    }

    func test_json_value_keeps_ints_and_doubles_distinct() throws {
        let value: JSONValue = .array([.int(1), .number(1.5), .bool(true), .null, .string("s"), .object(["k": .int(-2)])])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"[1,1.5,true,null,"s",{"k":-2}]"#)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
    }

    func test_timestamps_before_1970_and_far_future_format_correctly() {
        XCTAssertEqual(LoopTimestamp.format(millis: -1), "1969-12-31T23:59:59.999Z")
        XCTAssertEqual(LoopTimestamp.format(millis: 951_782_400_000), "2000-02-29T00:00:00.000Z")
        XCTAssertEqual(LoopTimestamp.parse("2000-02-29T00:00:00.000Z"), 951_782_400_000)
        XCTAssertEqual(LoopTimestamp.parse("2026-10-14T09:11:58Z"), 1_791_969_118_000)
        XCTAssertEqual(LoopTimestamp.parse("2026-10-14T09:11:58.4Z"), 1_791_969_118_400)
        XCTAssertNil(LoopTimestamp.parse("2026-02-30T00:00:00.000Z"))
        XCTAssertNil(LoopTimestamp.parse("2026-10-14T09:11:58.402+01:00"))
    }
}
