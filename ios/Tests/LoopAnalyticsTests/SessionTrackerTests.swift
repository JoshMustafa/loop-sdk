import XCTest
import LoopCore
@testable import LoopAnalytics

final class SessionTrackerTests: XCTestCase {
    private let gap: Int64 = 300_000
    private let minute: Int64 = 60_000
    private var kv = MemoryKeyValueStore()
    private var clock = FakeClock(1_791_968_400_000)

    override func setUp() {
        kv = MemoryKeyValueStore()
        clock = FakeClock(1_791_968_400_000)
    }

    private func load() -> SessionTracker {
        SessionTracker(kv: kv, minTimeBetweenSessionsMillis: gap, clock: clock)
    }

    func test_first_event_starts_a_session_whose_id_is_the_start_time_in_ms() {
        let s = load()
        XCTAssertNil(s.sessionId)
        XCTAssertEqual(s.onEvent(), clock.now)
    }

    func test_events_within_the_gap_extend_the_session() {
        let s = load()
        let first = s.onEvent()
        clock.now += 4 * minute
        XCTAssertEqual(s.onEvent(), first)
        clock.now += 4 * minute
        XCTAssertEqual(s.onEvent(), first, "the gap is measured from the last activity")
    }

    func test_idle_longer_than_the_gap_rolls_over_to_a_new_session() {
        let s = load()
        let first = s.onEvent()
        clock.now += gap + 1
        let second = s.onEvent()
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(second, clock.now)
    }

    func test_exactly_the_gap_still_counts_as_the_same_session() {
        let s = load()
        let first = s.onEvent()
        clock.now += gap
        XCTAssertEqual(s.onEvent(), first)
    }

    func test_resume_extends_a_live_session_and_starts_a_new_one_after_idle() {
        let s = load()
        let first = s.onEvent()
        clock.now += 3 * minute
        s.onForeground()
        XCTAssertEqual(s.sessionId, first)
        clock.now += 3 * minute
        XCTAssertEqual(s.onEvent(), first)
        s.onBackground()

        clock.now += 10 * minute
        s.onForeground()
        XCTAssertEqual(s.sessionId, clock.now)
    }

    func test_while_in_the_foreground_the_session_does_not_time_out() {
        let s = load()
        s.onForeground()
        let first = s.sessionId
        clock.now += 20 * minute
        XCTAssertEqual(s.onEvent(), first)
        clock.now += 20 * minute
        s.onBackground()
        clock.now += 2 * minute
        s.onForeground()
        XCTAssertEqual(s.sessionId, first, "idle is measured from backgrounding")
    }

    func test_idle_in_the_background_longer_than_the_gap_rolls_over() {
        let s = load()
        s.onForeground()
        let first = s.onEvent()
        s.onBackground()
        clock.now += 6 * minute
        XCTAssertNotEqual(s.onEvent(), first, "event while still backgrounded")
    }

    func test_background_before_any_session_does_not_start_one() {
        let s = load()
        s.onBackground()
        XCTAssertNil(s.sessionId)
    }

    func test_session_survives_a_restart_within_the_gap() {
        let first = load().onEvent()
        clock.now += 2 * minute
        XCTAssertEqual(load().onEvent(), first)
        clock.now += 6 * minute
        XCTAssertNotEqual(load().onEvent(), first)
    }

    func test_start_new_begins_a_fresh_session_immediately() {
        let s = load()
        let first = s.onEvent()
        clock.now += 1_000
        s.startNew()
        XCTAssertNotEqual(s.sessionId, first)
        XCTAssertEqual(s.sessionId, clock.now)
        XCTAssertEqual(load().sessionId, s.sessionId)
    }

    func test_a_clock_moving_backwards_does_not_break_the_session() {
        let s = load()
        let first = s.onEvent()
        clock.now -= minute
        XCTAssertEqual(s.onEvent(), first)
    }

    func test_clock_moving_backwards_keeps_session() {
        let clock = FakeClock(1_767_225_600_000)
        let tracker = SessionTracker(kv: MemoryKeyValueStore(), minTimeBetweenSessionsMillis: 300_000, clock: clock)
        let first = tracker.onEvent()
        clock.now -= 600_000
        XCTAssertEqual(tracker.onEvent(), first)
        tracker.onBackground()
        clock.now += 300_000          // still within the gap measured from the later timestamp
        tracker.onForeground()
        XCTAssertEqual(tracker.sessionId, first)
    }

    func test_uses_the_documented_storage_keys() {
        let s = load()
        let id = s.onEvent()
        clock.now += minute
        _ = s.onEvent()
        XCTAssertEqual(kv.int64("io.loop.analytics.session_id"), id)
        XCTAssertEqual(kv.int64("io.loop.analytics.last_activity"), clock.now)
    }
}
