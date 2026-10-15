package io.loop.analytics

import android.util.Log as AndroidLog

/**
 * The module's internal log, written to logcat under the tag `LoopAnalytics`
 * (`adb logcat -s LoopAnalytics`); there is no public log-level setting yet.
 *
 * Messages are for the app's developer: event names (which the developer
 * chooses), status codes, counts and error descriptions. Never put property
 * values, user ids or device ids in one.
 */
internal object Log {
    const val TAG = "LoopAnalytics"

    enum class Level { DEBUG, WARNING, ERROR }

    private val observers = LinkedHashMap<Int, (Level, String) -> Unit>()
    private var nextToken = 0

    fun debug(message: String) {
        AndroidLog.d(TAG, message)
        notify(Level.DEBUG, message)
    }

    fun warning(message: String) {
        AndroidLog.w(TAG, message)
        notify(Level.WARNING, message)
    }

    fun error(message: String) {
        AndroidLog.e(TAG, message)
        notify(Level.ERROR, message)
    }

    /** Test hook: [observer] receives every message until [removeObserver] is called with the returned token. */
    fun addObserver(observer: (Level, String) -> Unit): Int = synchronized(observers) {
        nextToken += 1
        observers[nextToken] = observer
        nextToken
    }

    fun removeObserver(token: Int) {
        synchronized(observers) { observers.remove(token) }
    }

    private fun notify(level: Level, message: String) {
        val current = synchronized(observers) { observers.values.toList() }
        for (observer in current) observer(level, message)
    }
}
