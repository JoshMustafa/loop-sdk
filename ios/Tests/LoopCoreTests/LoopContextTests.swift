import XCTest
@testable import LoopCore

final class LoopContextTests: XCTestCase {
    func test_json_omits_nil_fields_but_always_has_purchaser_and_sdk() {
        let ctx = LoopContext(platform: "iOS", osName: "ios", osVersion: "18.0", appVersion: "1.0.0",
                              appBuild: nil, deviceModel: "iPhone15,3", deviceManufacturer: "Apple",
                              deviceBrand: nil, isTablet: false, locale: "en-GB")
        let json = ctx.json(purchaserId: nil, sdk: (name: "loop-ios", version: "2.0.0"))
        XCTAssertNil(json["appBuild"])
        XCTAssertNil(json["deviceBrand"])
        XCTAssertTrue(json["purchaserId"] is NSNull)
        XCTAssertEqual(json["sdk"] as? [String: String], ["name": "loop-ios", "version": "2.0.0"])
        XCTAssertEqual(json["isTablet"] as? Bool, false)
    }

    func test_capture_on_this_platform_fills_platform_and_locale() {
        let ctx = LoopContext.capture()
        #if os(iOS)
        XCTAssertEqual(ctx.platform, "iOS")
        XCTAssertEqual(ctx.osName, "ios")
        XCTAssertEqual(ctx.deviceManufacturer, "Apple")
        #endif
        XCTAssertNotNil(ctx.locale)
        XCTAssertFalse(ctx.locale!.contains("_"), "BCP 47 uses '-' not '_'")
    }

    func test_locale_tag_is_bcp47() {
        XCTAssertEqual(LoopContext.localeTag(Locale(identifier: "en_GB")), "en-GB")
        let withCalendar = LoopContext.localeTag(Locale(identifier: "en_GB@calendar=buddhist"))
        XCTAssertNotNil(withCalendar)
        XCTAssertFalse(withCalendar!.contains("@"), "got \(withCalendar!)")
        XCTAssertFalse(withCalendar!.contains("_"), "got \(withCalendar!)")
        XCTAssertTrue(withCalendar!.hasPrefix("en-GB"), "got \(withCalendar!)")
    }
}
