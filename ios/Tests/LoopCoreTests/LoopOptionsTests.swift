import XCTest
@testable import LoopCore

final class LoopOptionsTests: XCTestCase {

    func test_resolveTier_returns_nil_when_provider_is_nil() {
        XCTAssertNil(LoopOptions.resolveTier(from: nil))
    }

    func test_resolveTier_returns_nil_when_provider_returns_nil() {
        XCTAssertNil(LoopOptions.resolveTier(from: { nil }))
    }

    func test_resolveTier_returns_nil_for_empty_or_whitespace() {
        XCTAssertNil(LoopOptions.resolveTier(from: { "" }))
        XCTAssertNil(LoopOptions.resolveTier(from: { "   " }))
        XCTAssertNil(LoopOptions.resolveTier(from: { "\n\t" }))
    }

    func test_resolveTier_passes_through_non_empty_values() {
        XCTAssertEqual(LoopOptions.resolveTier(from: { "paid" }), "paid")
        XCTAssertEqual(LoopOptions.resolveTier(from: { "pro" }), "pro")
        // Trims surrounding whitespace but preserves internal characters
        // and host-chosen casing (e.g. 'Founder', 'Free Trial').
        XCTAssertEqual(LoopOptions.resolveTier(from: { "  paid  " }), "paid")
        XCTAssertEqual(LoopOptions.resolveTier(from: { "Founder" }), "Founder")
    }

    func test_init_stores_tierProvider() {
        let options = LoopOptions(tierProvider: { "paid" })
        XCTAssertEqual(LoopOptions.resolveTier(from: options.tierProvider), "paid")
    }

    func test_default_init_installs_auto_tier_detector() {
        // Without an explicit `tierProvider`, the default init wires up the
        // built-in auto-detector. In a unit-test environment where RevenueCat
        // isn't linked, the detector returns nil — but the provider itself
        // must not be nil, otherwise tier reporting silently disables.
        let options = LoopOptions()
        XCTAssertNotNil(options.tierProvider)
        XCTAssertNil(LoopOptions.resolveTier(from: options.tierProvider))
    }

    func test_explicit_nil_tierProvider_disables_reporting() {
        let options = LoopOptions(tierProvider: nil)
        XCTAssertNil(options.tierProvider)
    }
}
