import XCTest
@testable import LoopSDK

final class RetentionEventStoreTests: XCTestCase {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("loop-retention-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeEvent(_ name: String, userId: String? = nil) -> RetentionEvent {
        RetentionEvent(
            name: name,
            occurredAt: "2026-07-03T12:00:00Z",
            sessionId: "11111111-2222-3333-4444-555555555555",
            props: ["reps": .int(30), "note": .string("hi"), "pro": .bool(true), "weight": .double(72.5)],
            userId: userId
        )
    }

    // MARK: - Offline persistence round-trip

    func test_buffered_events_survive_relaunch() {
        let dir = makeTempDir()
        let store = RetentionEventStore(directory: dir)
        store.append(makeEvent("first"))
        store.append(makeEvent("second", userId: "u_42"))

        // "Relaunch": a fresh store over the same directory sees the same
        // events, in the same order, with props/userId intact.
        let reloaded = RetentionEventStore(directory: dir)
        let events = reloaded.snapshot().map(\.event)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?.name, "first")
        XCTAssertEqual(events.last?.name, "second")
        XCTAssertEqual(events.last?.userId, "u_42")
        XCTAssertNil(events.first?.userId)
        XCTAssertEqual(events.first?.props["reps"], .int(30))
        XCTAssertEqual(events.first?.props["weight"], .double(72.5))
        XCTAssertEqual(events.first?.props["pro"], .bool(true))
        XCTAssertEqual(events.first?.props["note"], .string("hi"))
    }

    // MARK: - Drop-oldest cap

    func test_appending_beyond_capacity_drops_oldest() {
        let store = RetentionEventStore(directory: makeTempDir(), capacity: 5)
        for i in 0..<8 {
            store.append(makeEvent("event_\(i)"))
        }
        let names = store.snapshot().map(\.event.name)
        XCTAssertEqual(store.count(), 5)
        XCTAssertEqual(names, ["event_3", "event_4", "event_5", "event_6", "event_7"])
    }

    func test_capacity_drop_also_removes_files_on_disk() {
        let dir = makeTempDir()
        let store = RetentionEventStore(directory: dir, capacity: 3)
        for i in 0..<6 {
            store.append(makeEvent("event_\(i)"))
        }
        // A reload sees only what the cap kept.
        let reloaded = RetentionEventStore(directory: dir, capacity: 3)
        XCTAssertEqual(reloaded.snapshot().map(\.event.name), ["event_3", "event_4", "event_5"])
    }

    // MARK: - Removal after successful flush

    func test_remove_ids_deletes_from_memory_and_disk() {
        let dir = makeTempDir()
        let store = RetentionEventStore(directory: dir)
        store.append(makeEvent("keep"))
        store.append(makeEvent("sent_1"))
        store.append(makeEvent("sent_2"))

        let sentIds = store.snapshot().filter { $0.event.name.hasPrefix("sent") }.map(\.id)
        store.remove(ids: sentIds)

        XCTAssertEqual(store.snapshot().map(\.event.name), ["keep"])
        let reloaded = RetentionEventStore(directory: dir)
        XCTAssertEqual(reloaded.snapshot().map(\.event.name), ["keep"])
    }
}
