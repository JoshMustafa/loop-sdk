import XCTest
import LoopCore
@testable import LoopAnalytics

final class IdentityStoreTests: XCTestCase {
    private var kv = MemoryKeyValueStore()
    private var counter = 0

    override func setUp() {
        kv = MemoryKeyValueStore()
        counter = 0
    }

    private func load(legacy: String? = nil) -> IdentityStore {
        IdentityStore(kv: kv, legacyDeviceId: legacy, newDeviceId: { [unowned self] in
            counter += 1
            return "uuid-\(counter)"
        })
    }

    // MARK: generateDeviceId

    func test_ios_upper_case_uuid_v4_plus_r() throws {
        let id = generateDeviceId()
        let regex = try NSRegularExpression(pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}R$")
        XCTAssertEqual(regex.numberOfMatches(in: id, range: NSRange(id.startIndex..., in: id)), 1, id)
        XCTAssertNotEqual(generateDeviceId(), id)
    }

    // MARK: deviceId

    func test_generates_a_uuid_on_first_run_and_keeps_it_across_restarts() {
        XCTAssertEqual(load().deviceId, "uuid-1")
        XCTAssertEqual(load().deviceId, "uuid-1")
    }

    func test_adopts_the_legacy_id_on_first_run_only() {
        XCTAssertEqual(load(legacy: "amp-device").deviceId, "amp-device")
        XCTAssertEqual(load(legacy: "other").deviceId, "amp-device")
    }

    func test_ignores_a_blank_or_over_long_legacy_id() {
        XCTAssertEqual(load(legacy: "  ").deviceId, "uuid-1")
        kv = MemoryKeyValueStore()
        XCTAssertEqual(load(legacy: String(repeating: "x", count: 201)).deviceId, "uuid-2")
    }

    func test_trims_the_legacy_id() {
        XCTAssertEqual(load(legacy: "  amp-device \n").deviceId, "amp-device")
    }

    func test_persists_user_id_and_purchaser_id_null_clears_them() {
        let id = load()
        id.setUserId("12345")
        id.setPurchaserId("$RCAnonymousID:abc")
        let again = load()
        XCTAssertEqual(again.userId, "12345")
        XCTAssertEqual(again.purchaserId, "$RCAnonymousID:abc")

        again.setUserId(nil)
        again.setPurchaserId(nil)
        XCTAssertNil(load().userId)
        XCTAssertNil(load().purchaserId)
    }

    // MARK: user properties

    func test_merge_into_the_snapshot_null_removes_a_key_persisted() {
        let id = load()
        id.mergeUserProperties(["Plan": .string("free"), "Entries": .int(1), "Tags": .array([.string("a")])])
        id.mergeUserProperties(["Plan": .string("annual"), "Entries": .null])
        let expected: JSONObject = ["Plan": .string("annual"), "Tags": .array([.string("a")])]
        XCTAssertEqual(id.userProperties, expected)
        XCTAssertEqual(load().userProperties, expected)
    }

    func test_snapshot_is_a_copy_that_later_merges_do_not_change() {
        let id = load()
        id.mergeUserProperties(["Plan": .string("free")])
        let snapshot = id.userProperties
        id.mergeUserProperties(["Plan": .string("annual")])
        XCTAssertEqual(snapshot, ["Plan": .string("free")])
    }

    func test_non_json_values_are_stringified() {
        let id = load()
        id.mergeUserProperties(Sanitize.props(["Since": Date(timeIntervalSince1970: 1_767_312_000)]))
        XCTAssertEqual(id.userProperties["Since"], .string("2026-01-02T00:00:00.000Z"))
    }

    func test_a_corrupt_stored_snapshot_loads_as_empty() {
        kv.set("{not json", for: IdentityStore.userPropsKey)
        XCTAssertEqual(load().userProperties, [:])
    }

    func test_opt_out_is_persisted() {
        let id = load()
        XCTAssertFalse(id.optOut)
        id.setOptOut(true)
        XCTAssertTrue(load().optOut)
    }

    func test_reset_gives_a_fresh_device_id_and_clears_user_props_purchaser() {
        let id = load(legacy: "amp-device")
        id.setUserId("12345")
        id.setPurchaserId("rc")
        id.mergeUserProperties(["Plan": .string("annual")])
        id.setOptOut(true)

        id.reset()

        XCTAssertEqual(id.deviceId, "uuid-1")
        XCTAssertNil(id.userId)
        XCTAssertNil(id.purchaserId)
        XCTAssertEqual(id.userProperties, [:])
        XCTAssertTrue(id.optOut, "opt-out is a user choice; reset keeps it")

        let again = load(legacy: "amp-device")
        XCTAssertEqual(again.deviceId, "uuid-1")
        XCTAssertNil(again.userId)
        XCTAssertNil(again.purchaserId)
        XCTAssertEqual(again.userProperties, [:])
        XCTAssertTrue(again.optOut)
    }

    func test_uses_the_documented_storage_keys() {
        let id = load()
        id.setUserId("u")
        id.setPurchaserId("p")
        id.mergeUserProperties(["k": .int(1)])
        id.setOptOut(true)
        XCTAssertEqual(kv.string("io.loop.analytics.device_id"), "uuid-1")
        XCTAssertEqual(kv.string("io.loop.analytics.user_id"), "u")
        XCTAssertEqual(kv.string("io.loop.analytics.purchaser_id"), "p")
        XCTAssertEqual(kv.string("io.loop.analytics.user_props"), #"{"k":1}"#)
        XCTAssertEqual(kv.bool("io.loop.analytics.opt_out"), true)
    }
}
