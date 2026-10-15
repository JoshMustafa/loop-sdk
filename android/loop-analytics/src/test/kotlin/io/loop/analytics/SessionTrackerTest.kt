package io.loop.analytics

import io.loop.core.MemoryKeyValueStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SessionTrackerTest {
    private val gap = 300_000L
    private val minute = 60_000L
    private val kv = MemoryKeyValueStore()
    private val clock = FakeClock(1_791_968_400_000)

    private fun load() = SessionTracker(kv, gap, clock)

    @Test
    fun first_event_starts_a_session_whose_id_is_the_start_time_in_ms() {
        val s = load()
        assertNull(s.sessionId)
        assertEquals(clock.now, s.onEvent())
    }

    @Test
    fun events_within_the_gap_extend_the_session() {
        val s = load()
        val first = s.onEvent()
        clock.now += 4 * minute
        assertEquals(first, s.onEvent())
        clock.now += 4 * minute
        assertEquals("the gap is measured from the last activity", first, s.onEvent())
    }

    @Test
    fun idle_longer_than_the_gap_rolls_over_to_a_new_session() {
        val s = load()
        val first = s.onEvent()
        clock.now += gap + 1
        val second = s.onEvent()
        assertNotEquals(first, second)
        assertEquals(clock.now, second)
    }

    @Test
    fun exactly_the_gap_still_counts_as_the_same_session() {
        val s = load()
        val first = s.onEvent()
        clock.now += gap
        assertEquals(first, s.onEvent())
    }

    @Test
    fun resume_extends_a_live_session_and_starts_a_new_one_after_idle() {
        val s = load()
        val first = s.onEvent()
        clock.now += 3 * minute
        s.onForeground()
        assertEquals(first, s.sessionId)
        clock.now += 3 * minute
        assertEquals(first, s.onEvent())
        s.onBackground()

        clock.now += 10 * minute
        s.onForeground()
        assertEquals(clock.now, s.sessionId)
    }

    @Test
    fun while_in_the_foreground_the_session_does_not_time_out() {
        val s = load()
        s.onForeground()
        val first = s.sessionId
        clock.now += 20 * minute
        assertEquals(first, s.onEvent())
        clock.now += 20 * minute
        s.onBackground()
        clock.now += 2 * minute
        s.onForeground()
        assertEquals("idle is measured from backgrounding", first, s.sessionId)
    }

    @Test
    fun idle_in_the_background_longer_than_the_gap_rolls_over() {
        val s = load()
        s.onForeground()
        val first = s.onEvent()
        s.onBackground()
        clock.now += 6 * minute
        assertNotEquals("event while still backgrounded", first, s.onEvent())
    }

    @Test
    fun background_before_any_session_does_not_start_one() {
        val s = load()
        s.onBackground()
        assertNull(s.sessionId)
    }

    @Test
    fun session_survives_a_restart_within_the_gap() {
        val first = load().onEvent()
        clock.now += 2 * minute
        assertEquals(first, load().onEvent())
        clock.now += 6 * minute
        assertNotEquals(first, load().onEvent())
    }

    @Test
    fun start_new_begins_a_fresh_session_immediately() {
        val s = load()
        val first = s.onEvent()
        clock.now += 1_000
        s.startNew()
        assertNotEquals(first, s.sessionId)
        assertEquals(clock.now, s.sessionId)
        assertEquals(s.sessionId, load().sessionId)
    }

    @Test
    fun a_clock_moving_backwards_does_not_break_the_session() {
        val s = load()
        val first = s.onEvent()
        clock.now -= minute
        assertEquals(first, s.onEvent())
    }

    @Test
    fun clock_moving_backwards_keeps_session() {
        val clock = FakeClock(1_767_225_600_000)
        val tracker = SessionTracker(MemoryKeyValueStore(), 300_000, clock)
        val first = tracker.onEvent()
        clock.now -= 600_000
        assertEquals(first, tracker.onEvent())
        tracker.onBackground()
        clock.now += 300_000 // still within the gap measured from the later timestamp
        tracker.onForeground()
        assertEquals(first, tracker.sessionId)
    }

    /** Kotlin-only: pins the "never move last activity backwards" rule the two tests above do not tell apart. */
    @Test
    fun a_backwards_clock_does_not_shorten_the_idle_window() {
        val s = load()
        val first = s.onEvent()
        clock.now -= 10 * minute
        s.onEvent()
        clock.now += 6 * minute // 6 min after the backwards event, still before the first one
        assertEquals(first, s.onEvent())
    }

    @Test
    fun uses_the_documented_storage_keys() {
        val s = load()
        val id = s.onEvent()
        clock.now += minute
        s.onEvent()
        assertEquals(id, kv.long("io.loop.analytics.session_id"))
        assertEquals(clock.now, kv.long("io.loop.analytics.last_activity"))
    }
}
