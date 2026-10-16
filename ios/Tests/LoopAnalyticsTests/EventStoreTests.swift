import XCTest
@testable import LoopAnalytics

final class EventStoreTests: XCTestCase {
    private var dir: URL!
    private var file: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("loop_store_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("events.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func open(max: Int = 1000) async -> EventStore {
        await EventStore(fileURL: file, maxQueueSize: max)
    }

    private func ids(_ store: EventStore) async -> [String] {
        await store.peek(Int.max).map(\.id)
    }

    private func fileLines() throws -> [String] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func test_appends_events_and_reloads_them_after_a_restart() async throws {
        let store = await open()
        await store.add(.sample(id: "a"))
        await store.add(.sample(id: "b"))

        let reopened = await open()
        let reloaded = await reopened.peek(10)
        XCTAssertEqual(reloaded.map(\.id), ["a", "b"])
        XCTAssertEqual(reloaded.first?.wireJSON(), LoopEvent.sample(id: "a").wireJSON())
        XCTAssertEqual(reloaded.first, .sample(id: "a"))
    }

    func test_persists_each_events_context_snapshot() async {
        let store = await open()
        await store.add(.sample(id: "a", context: ["platform": .string("ios"), "appVersion": .string("1.0 (1)")]))
        let reloaded = await open().peek(10)
        XCTAssertEqual(reloaded.first?.context, ["platform": .string("ios"), "appVersion": .string("1.0 (1)")])
    }

    func test_stores_one_json_object_per_line() async throws {
        let store = await open()
        await store.add(.sample(id: "a"))
        await store.add(.sample(id: "b"))
        let lines = try fileLines()
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            XCTAssertTrue(try JSONSerialization.jsonObject(with: Data(line.utf8)) is [String: Any])
        }
    }

    func test_when_full_drops_the_oldest_20_events_at_once() async {
        let store = await open(max: 30)
        for i in 0..<30 { await store.add(.sample(id: "\(i)")) }
        var count = await store.count
        XCTAssertEqual(count, 30)
        await store.add(.sample(id: "30"))
        count = await store.count
        XCTAssertEqual(count, 11)
        var current = await ids(store)
        XCTAssertEqual(current.first, "20")
        XCTAssertEqual(current.last, "30")
        await store.add(.sample(id: "31"))
        count = await store.count
        XCTAssertEqual(count, 12, "no further drop until full again")
        current = await ids(store)
        XCTAssertEqual(current, (20...31).map { "\($0)" })

        let reopened = await open(max: 30)
        let reloaded = await ids(reopened)
        XCTAssertEqual(reloaded, (20...31).map { "\($0)" })
    }

    func test_a_cap_below_20_keeps_at_least_the_new_event() async {
        let store = await open(max: 3)
        for id in ["1", "2", "3", "4"] { await store.add(.sample(id: id)) }
        let current = await ids(store)
        XCTAssertEqual(current, ["4"])
        await store.add(.sample(id: "5"))
        let reloaded = await ids(open(max: 3))
        XCTAssertEqual(reloaded, ["4", "5"])
    }

    func test_compacts_the_file_once_it_grows_well_past_the_cap() async throws {
        let store = await open(max: 25)
        for i in 0..<200 { await store.add(.sample(id: "\(i)")) }
        XCTAssertLessThanOrEqual(try fileLines().count, 50)
        let reloaded = await ids(open(max: 25))
        let current = await ids(store)
        XCTAssertEqual(reloaded, current)
    }

    func test_a_lower_cap_on_restart_keeps_only_the_newest_events() async {
        let store = await open(max: 10)
        for id in ["1", "2", "3", "4"] { await store.add(.sample(id: id)) }
        let reloaded = await ids(open(max: 2))
        XCTAssertEqual(reloaded, ["3", "4"])
    }

    func test_skips_corrupt_and_truncated_lines() async throws {
        let good = try String(decoding: JSONEncoder().encode(LoopEvent.sample(id: "ok").storageJSON()), as: UTF8.self)
        try "not json\n{\"id\": 1}\n\(good)\n{\"id\":\"half".write(to: file, atomically: true, encoding: .utf8)
        let store = await open()
        let loaded = await ids(store)
        XCTAssertEqual(loaded, ["ok"])

        // Appends after a corrupt tail must still be readable after restart.
        await store.add(.sample(id: "next"))
        let reloaded = await ids(open())
        XCTAssertEqual(reloaded, ["ok", "next"])
    }

    func test_truncated_last_line_is_skipped() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let good = LoopEvent.sample(id: "e1")
        let line = try JSONSerialization.data(withJSONObject: good.storageJSON().foundation()) + Data("\n".utf8)
        try (line + Data(#"{"id":"e2","name":"Tru"#.utf8)).write(to: url)
        let store = await EventStore(fileURL: url, maxQueueSize: 1000)
        let peeked = await store.peek(10)
        XCTAssertEqual(peeked.map(\.id), ["e1"])
    }

    func test_peek_returns_the_oldest_events_once_they_are_persisted() async {
        let store = await open()
        for id in ["a", "b", "c"] { await store.add(.sample(id: id)) }
        let batch = await store.peek(2)
        XCTAssertEqual(batch.map(\.id), ["a", "b"])
        // Durable before upload: the peeked events are already on disk.
        let reloaded = await ids(open())
        XCTAssertEqual(reloaded, ["a", "b", "c"])
    }

    func test_remove_deletes_by_id_in_memory_and_on_disk() async {
        let store = await open()
        for id in ["a", "b", "c"] { await store.add(.sample(id: id)) }
        await store.remove(ids: ["a", "c"])
        let current = await ids(store)
        XCTAssertEqual(current, ["b"])
        let reloaded = await ids(open())
        XCTAssertEqual(reloaded, ["b"])
    }

    func test_rewrites_leave_the_right_content_and_no_temp_files() async throws {
        let store = await open(max: 25)
        for i in 1...26 { await store.add(.sample(id: "e\(i)")) } // drop-20 rewrite
        await store.remove(ids: ["e21"])                           // remove rewrite
        await store.add(.sample(id: "e27"))                         // append after rewrite
        let lines = try fileLines()
        let decoded = try lines.map { try LoopEvent(storageJSON: JSONDecoder().decode(JSONObject.self, from: Data($0.utf8))).id }
        XCTAssertEqual(decoded, ["e22", "e23", "e24", "e25", "e26", "e27"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["events.jsonl"])
    }

    func test_events_added_during_a_remove_are_not_lost() async {
        let store = await open()
        await store.add(.sample(id: "a"))
        async let removing: Void = store.remove(ids: ["a"])
        async let adding: Void = store.add(.sample(id: "b"))
        _ = await (removing, adding)
        let current = await ids(store)
        XCTAssertEqual(current, ["b"])
        let reloaded = await ids(open())
        XCTAssertEqual(reloaded, ["b"])
    }

    func test_a_missing_file_opens_as_an_empty_queue() async {
        let nested = dir.appendingPathComponent("nested/dir/events.jsonl")
        let store = await EventStore(fileURL: nested, maxQueueSize: 10)
        var count = await store.count
        XCTAssertEqual(count, 0)
        await store.add(.sample(id: "a"))
        count = await store.count
        XCTAssertEqual(count, 1)
        let reloaded = await EventStore(fileURL: nested, maxQueueSize: 10).peek(10)
        XCTAssertEqual(reloaded.map(\.id), ["a"])
    }

    func test_works_without_a_file() async {
        let store = await EventStore(fileURL: nil, maxQueueSize: 10)
        await store.add(.sample(id: "a"))
        await store.add(.sample(id: "b"))
        await store.remove(ids: ["a"])
        let current = await ids(store)
        XCTAssertEqual(current, ["b"])
    }

    func test_full_queue_drops_oldest_20_and_keeps_new_event() async {
        let store = await EventStore(fileURL: nil, maxQueueSize: 25)
        for i in 1...26 { await store.add(.sample(id: "e\(i)")) }
        let ids = await store.peek(100).map(\.id)
        XCTAssertEqual(ids, (21...26).map { "e\($0)" })
    }

    func test_unicode_line_separators_inside_values_survive_a_restart() async {
        let store = await open()
        await store.add(.sample(id: "a", props: ["text": .string("one\u{2028}two\u{0085}three\r\nfour")]))
        let reloaded = await open().peek(10)
        XCTAssertEqual(reloaded.first?.props["text"], .string("one\u{2028}two\u{0085}three\r\nfour"))
    }

    func test_an_unencodable_event_is_not_queued() async throws {
        let store = await open()
        await store.add(.sample(id: "bad", props: ["n": .number(.nan)]))
        await store.add(.sample(id: "good"))
        let current = await ids(store)
        XCTAssertEqual(current, ["good"])
        XCTAssertEqual(try fileLines().count, 1)
    }

    // MARK: Logging

    func test_write_failures_are_logged_and_the_events_stay_in_memory() async throws {
        let log = LogRecorder()
        defer { log.stop() }
        // A regular file where the queue's directory should be: every write fails.
        let blocker = dir.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let store = await EventStore(fileURL: blocker.appendingPathComponent("events.jsonl"), maxQueueSize: 10)

        await store.add(.sample(id: "a")) // appended
        await store.add(.sample(id: "b")) // the failed append makes this a rewrite

        let count = await store.count
        XCTAssertEqual(count, 2)
        let errors = log.messages(.error)
        XCTAssertEqual(errors.count, 2, "\(errors)")
        XCTAssertTrue(errors.first?.contains("append") == true, "\(errors)")
        XCTAssertTrue(errors.last?.contains("rewrite") == true, "\(errors)")
    }

    func test_an_unencodable_event_is_logged_by_name() async {
        let log = LogRecorder()
        defer { log.stop() }
        let store = await open()

        await store.add(.sample(id: "nan", name: "Score Posted", props: ["score": .number(.nan)]))

        let count = await store.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(log.messages(.error).count, 1)
        XCTAssertTrue(log.messages(.error).first?.contains("Score Posted") == true, "\(log.messages(.error))")
    }
}
