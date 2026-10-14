import XCTest
@testable import LoopCore

final class ReporterIdTests: XCTestCase {
    func test_generate_produces_well_formed_id() {
        for _ in 0..<32 {
            let id = ReporterId.generate()
            XCTAssertTrue(ReporterId.looksValid(id), "rejected: \(id)")
            XCTAssertTrue(id.hasPrefix("r_"))
            XCTAssertEqual(id.count, 14)  // "r_" + 12 hex
        }
    }

    func test_looksValid_rejects_garbage() {
        XCTAssertFalse(ReporterId.looksValid(""))
        XCTAssertFalse(ReporterId.looksValid("hello"))
        XCTAssertFalse(ReporterId.looksValid("r_"))           // empty body
        XCTAssertFalse(ReporterId.looksValid("r_short"))      // < 8 chars body
        XCTAssertFalse(ReporterId.looksValid("r_HASUPPER"))   // upper hex
        XCTAssertFalse(ReporterId.looksValid("r_!@#$%^&*"))   // symbols
        XCTAssertTrue(ReporterId.looksValid("r_abcd1234abcd"))
    }
}

final class ReporterStoreTests: XCTestCase {
    /// Use a unique service per test run so that we don't collide with any
    /// real entry on this Mac/dev keychain, and clean up after.
    private func makeStore() -> ReporterStore {
        let service = "io.loop.sdk.tests.\(UUID().uuidString)"
        return ReporterStore(service: service, account: "reporter_id")
    }

    func test_returns_same_id_across_calls() throws {
        let store = makeStore()
        defer { store.reset() }

        let first = store.ensureId()
        let second = store.ensureId()
        XCTAssertEqual(first, second)
        XCTAssertTrue(ReporterId.looksValid(first))
    }

    func test_reset_rotates_the_id() throws {
        let store = makeStore()
        defer { store.reset() }

        let first = store.ensureId()
        store.reset()
        let second = store.ensureId()
        XCTAssertNotEqual(first, second)
    }

    func test_each_store_instance_with_same_service_sees_same_id() throws {
        let service = "io.loop.sdk.tests.\(UUID().uuidString)"
        let a = ReporterStore(service: service, account: "reporter_id")
        let b = ReporterStore(service: service, account: "reporter_id")
        defer { a.reset() }

        let firstFromA = a.ensureId()
        let firstFromB = b.ensureId()
        XCTAssertEqual(firstFromA, firstFromB)
    }
}

final class ReporterStoreUpgradeTests: XCTestCase {
    func test_keychain_location_is_unchanged_for_upgrades() {
        XCTAssertEqual(ReporterStore.defaultService, "io.loop.sdk")
        XCTAssertEqual(ReporterStore.defaultAccount, "reporter_id")
    }
}
