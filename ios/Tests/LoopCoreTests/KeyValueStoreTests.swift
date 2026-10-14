import XCTest
@testable import LoopCore

final class KeyValueStoreTests: XCTestCase {
    func test_user_defaults_store_round_trips_and_nil_removes() {
        let suite = "io.loop.tests.\(UUID().uuidString)"
        let store = UserDefaultsStore(suiteName: suite)
        store.set("a", for: "s"); store.set(Int64(1_767_225_600_000), for: "i"); store.set(true, for: "b")
        XCTAssertEqual(store.string("s"), "a")
        XCTAssertEqual(store.int64("i"), 1_767_225_600_000)
        XCTAssertEqual(store.bool("b"), true)
        store.set(nil as String?, for: "s")
        XCTAssertNil(store.string("s"))
        UserDefaults().removePersistentDomain(forName: suite)
    }
}
