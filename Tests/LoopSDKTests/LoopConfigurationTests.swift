import XCTest
@testable import LoopSDK

final class LoopConfigurationTests: XCTestCase {

    func test_resolveTier_returns_nil_when_provider_is_nil() {
        XCTAssertNil(LoopConfiguration.resolveTier(from: nil))
    }

    func test_resolveTier_returns_nil_when_provider_returns_nil() {
        XCTAssertNil(LoopConfiguration.resolveTier(from: { nil }))
    }

    func test_resolveTier_returns_nil_for_empty_or_whitespace() {
        XCTAssertNil(LoopConfiguration.resolveTier(from: { "" }))
        XCTAssertNil(LoopConfiguration.resolveTier(from: { "   " }))
        XCTAssertNil(LoopConfiguration.resolveTier(from: { "\n\t" }))
    }

    func test_resolveTier_passes_through_non_empty_values() {
        XCTAssertEqual(LoopConfiguration.resolveTier(from: { "paid" }), "paid")
        XCTAssertEqual(LoopConfiguration.resolveTier(from: { "pro" }), "pro")
        // Trims surrounding whitespace but preserves internal characters
        // and host-chosen casing (e.g. 'Founder', 'Free Trial').
        XCTAssertEqual(LoopConfiguration.resolveTier(from: { "  paid  " }), "paid")
        XCTAssertEqual(LoopConfiguration.resolveTier(from: { "Founder" }), "Founder")
    }

    func test_init_stores_tierProvider() {
        let config = LoopConfiguration(apiKey: "loop_pk_test", tierProvider: { "paid" })
        XCTAssertEqual(LoopConfiguration.resolveTier(from: config.tierProvider), "paid")
    }

    func test_default_init_installs_auto_tier_detector() {
        // Without an explicit `tierProvider`, the default init wires up
        // the built-in auto-detector. In a unit-test environment where
        // RevenueCat isn't linked, the detector returns nil — but the
        // provider itself must not be nil, otherwise the wire-up is
        // wrong and tier reporting silently disables.
        let config = LoopConfiguration(apiKey: "loop_pk_test")
        XCTAssertNotNil(config.tierProvider)
        XCTAssertNil(LoopConfiguration.resolveTier(from: config.tierProvider))
    }

    func test_explicit_nil_tierProvider_disables_reporting() {
        // The override init with explicit `nil` is the documented opt-out.
        let config = LoopConfiguration(apiKey: "loop_pk_test", tierProvider: nil)
        XCTAssertNil(config.tierProvider)
    }

    func test_analyticsEnabled_defaults_to_true() {
        XCTAssertTrue(LoopConfiguration(apiKey: "loop_pk_test").analyticsEnabled)
        XCTAssertTrue(LoopConfiguration(apiKey: "loop_pk_test", tierProvider: nil).analyticsEnabled)
    }

    func test_analyticsEnabled_can_be_disabled() {
        let config = LoopConfiguration(apiKey: "loop_pk_test", analyticsEnabled: false)
        XCTAssertFalse(config.analyticsEnabled)
    }
}
