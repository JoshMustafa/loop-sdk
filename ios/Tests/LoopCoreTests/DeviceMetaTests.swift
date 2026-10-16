import XCTest
@testable import LoopCore

final class DeviceMetaTests: XCTestCase {

    func test_capture_populates_every_field() {
        let meta = DeviceMeta.capture(sessionId: "sess_test_1234")
        XCTAssertFalse(meta.device.isEmpty)
        XCTAssertFalse(meta.os.isEmpty)
        XCTAssertFalse(meta.appVersion.isEmpty)
        XCTAssertFalse(meta.locale.isEmpty)
        XCTAssertFalse(meta.network.isEmpty)
        XCTAssertEqual(meta.sessionId, "sess_test_1234")
    }

    func test_friendly_device_name_lookup() {
        XCTAssertEqual(DeviceMeta.friendlyDeviceName(for: "iPhone15,2"), "iPhone 14 Pro")
        XCTAssertEqual(DeviceMeta.friendlyDeviceName(for: "arm64"), "Simulator")
        XCTAssertNil(DeviceMeta.friendlyDeviceName(for: "iPhone99,99"))
    }

    func test_locale_uses_dash_separator() {
        // Locale.current.identifier returns e.g. "en_GB" — we want BCP-47-ish "en-GB".
        let locale = DeviceMeta.localeIdentifier()
        XCTAssertFalse(locale.contains("_"), "expected no underscores: \(locale)")
    }

    func test_bundle_version_has_short_and_build() {
        let v = DeviceMeta.bundleVersion()
        // shape: "X.Y.Z (N)"
        XCTAssertTrue(v.contains(" ("), "got \(v)")
        XCTAssertTrue(v.hasSuffix(")"), "got \(v)")
    }
}
