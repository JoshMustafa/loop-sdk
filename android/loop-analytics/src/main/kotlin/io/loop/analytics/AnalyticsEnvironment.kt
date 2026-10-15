package io.loop.analytics

import android.content.ComponentCallbacks
import android.content.Context
import android.content.res.Configuration
import io.loop.core.KeyValueStore
import io.loop.core.LoopClock
import io.loop.core.LoopContext
import io.loop.core.SharedPreferencesStore
import io.loop.core.SystemClock
import java.io.File
import java.util.UUID

/**
 * The engine's platform dependencies. [production] builds the real ones;
 * tests and the conformance runner pass fakes.
 */
internal data class AnalyticsEnvironment(
    val clock: LoopClock,
    val transport: AnalyticsTransport,
    /** The queue file; null keeps the queue in memory only. */
    val queueFile: File?,
    val kv: KeyValueStore,
    /** The device and app facts as of now; read for every event. */
    val context: () -> LoopContext,
    val lifecycle: LifecycleSource,
    val newEventId: () -> String,
    val newDeviceId: () -> String,
    val scheduler: Scheduler,
    /** Sent as `context.sdk`: name and version. */
    val sdk: Pair<String, String>,
    /**
     * How long one upload request may take. Also bounds how long
     * `AnalyticsEngine.dispose()` waits for the request in flight.
     */
    val requestTimeoutMillis: Long = Uploader.DEFAULT_REQUEST_TIMEOUT_MILLIS,
) {
    companion object {
        val SDK: Pair<String, String> = "loop-android" to "2.0.0"
        const val PREFERENCES_NAME = "io.loop.analytics"

        /**
         * The real environment: system clock, `HttpURLConnection`, the queue
         * file in no-backup storage, the `io.loop.analytics`
         * SharedPreferences, the process lifecycle and a coroutine timer.
         *
         * Touches the disk (the no-backup directory, the preferences file),
         * so call it off the main thread.
         */
        fun production(context: Context): AnalyticsEnvironment {
            val app = context.applicationContext ?: context
            val device = DeviceContext.start(app)
            return AnalyticsEnvironment(
                clock = SystemClock,
                transport = HttpUrlConnectionTransport(),
                queueFile = queueFile(app),
                kv = SharedPreferencesStore(app, PREFERENCES_NAME),
                context = device::current,
                lifecycle = ProcessLifecycleSource(),
                newEventId = ::newEventId,
                newDeviceId = ::generateDeviceId,
                scheduler = TimerScheduler(),
                sdk = SDK,
            )
        }

        /** A random UUID v4, lower-case: the server's dedup key for an event. */
        fun newEventId(): String = UUID.randomUUID().toString()

        /**
         * `<noBackupFilesDir>/loop/analytics-queue.jsonl`: kept out of Auto
         * Backup and device transfer without any rules in the app's
         * manifest. Null (the queue then lives in memory only) when the
         * directory is unavailable. The queue creates `loop/` on first write.
         */
        fun queueFile(context: Context): File? = try {
            File(File(context.noBackupFilesDir, "loop"), "analytics-queue.jsonl")
        } catch (e: RuntimeException) {
            Log.error("No directory for the analytics queue; events will not persist: ${e.javaClass.name}")
            null
        }
    }
}

/**
 * The device context, read from any thread. Captured on first use and again
 * after a configuration change (e.g. the user changes the locale): the
 * change only marks it stale, so the main thread does no work and the next
 * event, off the main thread, recaptures it.
 */
internal class DeviceContext private constructor(private val context: Context) : ComponentCallbacks {
    private val lock = Any()
    private var cached: LoopContext? = null

    val current: LoopContext
        get() = synchronized(lock) {
            cached ?: LoopContext.capture(context).also { cached = it }
        }

    override fun onConfigurationChanged(newConfig: Configuration) {
        synchronized(lock) { cached = null }
    }

    @Deprecated("Deprecated in Java")
    override fun onLowMemory() = Unit

    companion object {
        /** A device context for [context]'s app, kept current from its configuration changes. */
        fun start(context: Context): DeviceContext {
            val device = DeviceContext(context)
            context.registerComponentCallbacks(device)
            return device
        }
    }
}
