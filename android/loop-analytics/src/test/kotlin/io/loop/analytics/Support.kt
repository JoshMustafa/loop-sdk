package io.loop.analytics

import io.loop.core.LoopClock
import java.util.concurrent.atomic.AtomicLong

/** A fixed event for queue tests (port of the Swift `LoopEvent.sample` helper). */
internal fun sampleEvent(
    id: String,
    name: String = "Test Event",
    props: JsonObject = emptyMap(),
    context: JsonObject? = null,
): LoopEvent = LoopEvent(
    id = id,
    name = name,
    occurredAtMillis = 1_791_968_400_000, // 2026-10-14T09:00:00.000Z
    sessionId = 1_760_432_400_000,
    deviceId = "device-1",
    userId = null,
    props = props,
    userProps = emptyMap(),
    context = context,
)

/** A settable clock. Thread-safe: a test sets it while other code reads it. */
internal class FakeClock(start: Long) : LoopClock {
    private val value = AtomicLong(start)

    var now: Long
        get() = value.get()
        set(newValue) = value.set(newValue)

    override fun nowMillis(): Long = now
}

/** Records what the module logs while it is alive (until [stop]). */
internal class LogRecorder {
    private val entries = mutableListOf<Pair<Log.Level, String>>()
    private var token: Int? = Log.addObserver { level, message ->
        synchronized(entries) { entries.add(level to message) }
    }

    fun stop() {
        token?.let(Log::removeObserver)
        token = null
    }

    fun messages(level: Log.Level): List<String> =
        synchronized(entries) { entries.filter { it.first == level }.map { it.second } }
}
