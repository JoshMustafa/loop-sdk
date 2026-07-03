import XCTest
@testable import LoopSDK

final class RetentionSanitizerTests: XCTestCase {

    // MARK: - Event names: lowercase snake_case, ≤64 chars

    func test_valid_snake_case_name_passes_through() {
        XCTAssertEqual(RetentionSanitizer.sanitizeName("set_logged"), "set_logged")
        XCTAssertEqual(RetentionSanitizer.sanitizeName("app_opened"), "app_opened")
        XCTAssertEqual(RetentionSanitizer.sanitizeName("step2_done"), "step2_done")
    }

    func test_name_is_lowercased_and_separators_become_underscores() {
        XCTAssertEqual(RetentionSanitizer.sanitizeName("Set Logged"), "set_logged")
        XCTAssertEqual(RetentionSanitizer.sanitizeName("sign-up.completed"), "sign_up_completed")
        XCTAssertEqual(RetentionSanitizer.sanitizeName("  Onboarding Completed  "), "onboarding_completed")
    }

    func test_name_strips_invalid_characters_and_collapses_underscores() {
        XCTAssertEqual(RetentionSanitizer.sanitizeName("reps!!(30)"), "reps30")
        // Double space must not survive as a double underscore.
        XCTAssertEqual(RetentionSanitizer.sanitizeName("hello  world"), "hello_world")
        // Leading/trailing separators trimmed.
        XCTAssertEqual(RetentionSanitizer.sanitizeName("_private_"), "private")
    }

    func test_empty_or_symbol_only_names_are_dropped() {
        XCTAssertNil(RetentionSanitizer.sanitizeName(""))
        XCTAssertNil(RetentionSanitizer.sanitizeName("   "))
        XCTAssertNil(RetentionSanitizer.sanitizeName("💥🎉"))
        XCTAssertNil(RetentionSanitizer.sanitizeName("!!!"))
    }

    func test_name_longer_than_64_chars_is_dropped() {
        let long = String(repeating: "a", count: 65)
        XCTAssertNil(RetentionSanitizer.sanitizeName(long))
    }

    func test_name_of_exactly_64_chars_is_kept() {
        let name = String(repeating: "a", count: 64)
        XCTAssertEqual(RetentionSanitizer.sanitizeName(name), name)
    }

    // MARK: - Props: scalars only, ≤16 keys, strings ≤256 chars

    func test_nil_props_stay_nil() {
        XCTAssertNil(RetentionSanitizer.sanitizeProps(nil))
    }

    func test_scalar_props_preserve_their_types() {
        let props = RetentionSanitizer.sanitizeProps([
            "reps": 30,
            "weight": 72.5,
            "pro": true,
            "plan": "monthly"
        ])
        XCTAssertEqual(props?["reps"], .int(30))
        XCTAssertEqual(props?["weight"], .double(72.5))
        XCTAssertEqual(props?["pro"], .bool(true))
        XCTAssertEqual(props?["plan"], .string("monthly"))
    }

    func test_non_scalar_props_are_dropped() {
        let props = RetentionSanitizer.sanitizeProps([
            "ok": 1,
            "array": [1, 2, 3],
            "dict": ["nested": true],
            "date": Date(),
            "null": NSNull()
        ])
        XCTAssertEqual(props?.count, 1)
        XCTAssertEqual(props?["ok"], .int(1))
    }

    func test_string_props_are_truncated_to_256_chars() {
        let long = String(repeating: "x", count: 300)
        let props = RetentionSanitizer.sanitizeProps(["note": long])
        guard case .string(let value)? = props?["note"] else {
            return XCTFail("expected a string prop")
        }
        XCTAssertEqual(value.count, 256)
    }

    func test_props_are_capped_at_16_keeping_alphabetically_first_keys() {
        var raw: [String: Any] = [:]
        for i in 0..<20 {
            raw[String(format: "key_%02d", i)] = i
        }
        let props = RetentionSanitizer.sanitizeProps(raw)
        XCTAssertEqual(props?.count, 16)
        // Deterministic cap: alphabetically-first keys survive.
        XCTAssertEqual(props?["key_00"], .int(0))
        XCTAssertEqual(props?["key_15"], .int(15))
        XCTAssertNil(props?["key_16"])
        XCTAssertNil(props?["key_19"])
    }
}
