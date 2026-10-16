import XCTest
@testable import LoopFeedback

final class BundleTests: XCTestCase {
    func test_feedback_resources_resolve_to_the_package_bundle_under_swiftpm() {
        XCTAssertEqual(Bundle.loopFeedback.bundleURL, Bundle.module.bundleURL)
    }

    func test_feedback_privacy_manifest_ships_in_the_resource_bundle() {
        XCTAssertNotNil(Bundle.loopFeedback.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
    }
}
