package io.loop.analytics

import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Stops a scheduled timer. */
internal fun interface Cancellable {
    fun cancel()
}

/** Runs the periodic flush. Injectable so tests fire ticks themselves. */
internal fun interface Scheduler {
    /** Calls [tick] every [intervalMillis] until the returned handle is cancelled. */
    fun every(intervalMillis: Long, tick: () -> Unit): Cancellable
}

/**
 * [Scheduler] over a coroutine `delay` loop on [Dispatchers.Default]. The
 * tick only hands work to the engine, so it never blocks the timer.
 */
internal class TimerScheduler : Scheduler {
    private val scope = CoroutineScope(
        SupervisorJob() + Dispatchers.Default + CoroutineExceptionHandler { _, error ->
            Log.error("The analytics flush timer stopped on an unexpected ${error.javaClass.name}")
        },
    )

    override fun every(intervalMillis: Long, tick: () -> Unit): Cancellable {
        // A zero or negative interval means no periodic flush rather than a
        // timer that spins.
        if (intervalMillis <= 0) return Cancellable {}
        val interval = minOf(intervalMillis, MAX_INTERVAL_MILLIS)
        val job = scope.launch {
            while (true) {
                delay(interval)
                tick()
            }
        }
        return Cancellable { job.cancel() }
    }

    companion object {
        /** Longest interval honoured (a year), matching the iOS timer. */
        const val MAX_INTERVAL_MILLIS = 365L * 24 * 3600 * 1000
    }
}
