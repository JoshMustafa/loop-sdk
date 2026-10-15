package io.loop.analytics

import io.loop.core.KeyValueStore
import io.loop.core.LoopClock

/**
 * Idle-based sessions. The session id is the session's start time in ms since
 * epoch.
 *
 * Each event, resume and pause counts as activity. When more than [gapMillis]
 * passes without activity, the next activity starts a new session. While the
 * app is known to be in the foreground the session does not time out (someone
 * reading a screen is not idle); idle time is counted from the last event or
 * from going to the background. No session events are emitted. The id and
 * last activity time are persisted so a quick relaunch continues the session.
 * Not thread-safe: the engine serialises access.
 */
internal class SessionTracker(
    private val kv: KeyValueStore,
    private val gapMillis: Long,
    private val clock: LoopClock,
) {
    /** The current session id, or null before the first activity. */
    var sessionId: Long? = kv.long(SESSION_ID_KEY)
        private set
    private var lastActivity: Long? = kv.long(LAST_ACTIVITY_KEY)
    private var inForeground = false

    /** Records an event; returns the session it belongs to. */
    fun onEvent(): Long = touch()

    /** The app came to the foreground: extend or roll over the session. */
    fun onForeground() {
        touch()
        inForeground = true
    }

    /** The app is going to the background: the time spent in it counts. */
    fun onBackground() {
        if (sessionId != null) touch()
        inForeground = false
    }

    /** Ends the current session and starts a new one now. */
    fun startNew() {
        val now = clock.nowMillis()
        sessionId = now
        lastActivity = now
        persist()
    }

    private fun touch(): Long {
        val now = clock.nowMillis()
        val current = sessionId
        val last = lastActivity
        val session = if (current != null && last != null && (inForeground || now - last <= gapMillis)) current else now
        sessionId = session
        // A clock that moved backwards must not shorten the idle window.
        if (last == null || now > last) lastActivity = now
        persist()
        return session
    }

    private fun persist() {
        sessionId?.let { kv.setLong(SESSION_ID_KEY, it) }
        lastActivity?.let { kv.setLong(LAST_ACTIVITY_KEY, it) }
    }

    companion object {
        const val SESSION_ID_KEY = "io.loop.analytics.session_id"
        const val LAST_ACTIVITY_KEY = "io.loop.analytics.last_activity"
    }
}
