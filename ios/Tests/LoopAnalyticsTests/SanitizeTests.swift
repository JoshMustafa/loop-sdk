import XCTest
@testable import LoopAnalytics

final class SanitizeTests: XCTestCase {
    // MARK: props

    func test_strips_null_values_and_keeps_json_values_incl_lists_and_maps() {
        let out = Sanitize.props([
            "a": nil,
            "b": 1,
            "c": 2.5,
            "d": true,
            "e": "x",
            "foods": ["apple", 1, nil] as [Any?],
            "nested": ["k": "v", "gone": nil] as [String: Any?],
        ])
        XCTAssertEqual(out, [
            "b": .int(1),
            "c": .number(2.5),
            "d": .bool(true),
            "e": .string("x"),
            "foods": .array([.string("apple"), .int(1), .null]),
            "nested": .object(["k": .string("v")]),
        ])
    }

    func test_stringifies_values_that_are_not_json_encodable() throws {
        struct Thing: CustomStringConvertible { var description: String { "Thing!" } }
        let out = Sanitize.props([
            "when": Date(timeIntervalSince1970: 1_791_968_400), // 2026-10-14T09:00:00Z
            "obj": Thing(),
            "nan": Double.nan,
            "set": Set([1, 2]),
            "intKeys": [1: "one"],
        ])
        XCTAssertEqual(out["when"], .string("2026-10-14T09:00:00.000Z"))
        XCTAssertEqual(out["obj"], .string("Thing!"))
        XCTAssertEqual(out["nan"], .string("nan"))
        guard case .array(let set) = out["set"] else { return XCTFail("set is not an array: \(String(describing: out["set"]))") }
        XCTAssertEqual(set.count, 2) // a Set has no order
        XCTAssertTrue(set.contains(.int(1)) && set.contains(.int(2)))
        XCTAssertEqual(out["intKeys"], .object(["1": .string("one")]))
        XCTAssertNoThrow(try JSONEncoder().encode(out))
    }

    func test_does_not_truncate_strings_or_cap_the_number_of_keys() {
        let long = String(repeating: "x", count: 5000)
        var many: [String: Any] = [:]
        for i in 0..<1500 { many["k\(i)"] = i }
        let out = Sanitize.props(["long": long, "many": many, "list": [long]])
        XCTAssertEqual(out["long"], .string(long))
        guard case .object(let manyOut) = out["many"] else { return XCTFail("many is not an object") }
        XCTAssertEqual(manyOut.count, 1500)
        XCTAssertEqual(out["list"], .array([.string(long)]))
    }

    func test_null_input_gives_an_empty_map() {
        XCTAssertEqual(Sanitize.props(nil), [:])
    }

    func test_sanitize_converts_non_json_values() {
        struct Custom: CustomStringConvertible { var description: String { "custom!" } }
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        let out = Sanitize.props(["d": date, "u": URL(string: "https://x.test")!, "c": Custom(), "n": Double.nan, "i": 3, "f": 1.5, "nil": nil])
        XCTAssertEqual(out["d"], .string("2026-01-01T00:00:00.000Z"))
        XCTAssertEqual(out["u"], .string("https://x.test"))
        XCTAssertEqual(out["c"], .string("custom!"))
        XCTAssertEqual(out["n"], .string("nan"))
        XCTAssertEqual(out["i"], .int(3))
        XCTAssertEqual(out["f"], .number(1.5))
        XCTAssertNil(out["nil"])
    }

    func test_bools_stay_bools_including_bridged_ns_numbers() throws {
        let decoded = try JSONSerialization.jsonObject(with: Data(#"{"t":true,"one":1,"half":0.5}"#.utf8)) as! [String: Any]
        let out = Sanitize.props([
            "swiftBool": false,
            "nsBool": NSNumber(value: true),
            "nsInt": NSNumber(value: 1),
            "nsDouble": NSNumber(value: 2.5),
            "json": decoded,
        ])
        XCTAssertEqual(out["swiftBool"], .bool(false))
        XCTAssertEqual(out["nsBool"], .bool(true))
        XCTAssertEqual(out["nsInt"], .int(1))
        XCTAssertEqual(out["nsDouble"], .number(2.5))
        XCTAssertEqual(out["json"], .object(["t": .bool(true), "one": .int(1), "half": .number(0.5)]))
    }

    func test_optionals_nested_in_any_are_unwrapped_or_stripped() {
        let some: Int? = 7
        let none: String? = nil
        let out = Sanitize.props(["some": some as Any, "none": none as Any, "list": [some as Any, none as Any]])
        XCTAssertEqual(out["some"], .int(7))
        XCTAssertNil(out["none"])
        XCTAssertEqual(out["list"], .array([.int(7), .null]))
    }

    func test_infinite_numbers_are_stringified() {
        let out = Sanitize.props(["inf": Double.infinity, "ninf": -Double.infinity, "f": Float.nan])
        XCTAssertEqual(out["inf"], .string("inf"))
        XCTAssertEqual(out["ninf"], .string("-inf"))
        XCTAssertEqual(out["f"], .string("nan"))
    }

    // MARK: isValidEventName

    func test_accepts_title_case_with_spaces_and_rejects_blank_or_too_long() {
        XCTAssertTrue(Sanitize.isValidEventName("Purchase Completed"))
        XCTAssertFalse(Sanitize.isValidEventName("   "))
        XCTAssertFalse(Sanitize.isValidEventName(""))
        XCTAssertTrue(Sanitize.isValidEventName(String(repeating: "a", count: 128)))
        XCTAssertFalse(Sanitize.isValidEventName(String(repeating: "a", count: 129)))
        XCTAssertTrue(Sanitize.isValidEventName("  \(String(repeating: "a", count: 128))  "))
        XCTAssertEqual(Sanitize.maxEventNameLength, 128)
    }
}
