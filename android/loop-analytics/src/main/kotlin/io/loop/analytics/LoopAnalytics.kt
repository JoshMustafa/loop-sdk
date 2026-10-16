package io.loop.analytics

import android.os.Handler
import android.os.Looper
import io.loop.core.Loop
import io.loop.core.LoopConfiguration
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Options for [LoopAnalytics.start]. Any option left out keeps its default.
 *
 * A data class for apps to build: a library that wraps Loop should not
 * expose it in its own binary API, since its constructor and `copy` change
 * whenever an option is added.
 */
public data class LoopAnalyticsOptions @JvmOverloads constructor(
    /** Upload as soon as this many events are queued. */
    val flushQueueSize: Int = 30,
    /** Upload queued events at least this often (ms) while the app runs. */
    val flushIntervalMillis: Long = 30_000,
    /** Idle time (ms) after which the next event or return to the app starts a new session. */
    val minTimeBetweenSessionsMillis: Long = 300_000,
    /** Most events kept on disk; when full, the oldest 20 are dropped. */
    val maxQueueSize: Int = 1000,
    /** Most events sent in one request. */
    val maxBatchSize: Int = 100,
    /**
     * A device id to adopt on first run (e.g. the one your previous
     * analytics SDK generated) so existing anonymous users carry over.
     * Ignored once a device id is stored, and after [LoopAnalytics.reset].
     */
    val legacyDeviceId: String? = null,
)

/**
 * Product analytics for Loop.
 *
 *     Loop.configure(this, apiKey = "loop_pk_…")
 *     LoopAnalytics.start()                  // optional: defaults otherwise
 *     LoopAnalytics.track("Item Viewed", mapOf("Index" to 1))
 *
 * Calls are fire-and-forget: they return at once, from any thread, run in
 * the order they were made, and never throw into the app. Calls made before
 * `Loop.configure` are dropped, as are calls with a null name, options or
 * properties map (possible from Java), which are logged. Events are queued
 * on disk and uploaded in batches in the background; no call does disk or
 * network work on the caller's thread.
 */
public object LoopAnalytics {
    /**
     * Starts analytics with [options]. Call it once, after `Loop.configure`
     * (options passed earlier are kept until then). Without it, the first
     * call after `Loop.configure` starts analytics with the default options.
     * Later calls are ignored.
     *
     * Analytics keeps the API key and server it started with: calling
     * `Loop.configure` again later does not change them.
     */
    @JvmStatic
    @JvmOverloads
    public fun start(options: LoopAnalyticsOptions? = LoopAnalyticsOptions()) {
        if (options == null) return Log.error("LoopAnalytics.start ignored: options is null")
        AnalyticsRuntime.shared.start(options)
    }

    /**
     * Records an event. [properties] may hold strings, numbers, booleans,
     * lists, arrays and nested maps; null values are dropped, dates become
     * ISO 8601 strings and anything else its `toString()`. The properties
     * are read before this returns.
     */
    @JvmStatic
    @JvmOverloads
    public fun track(name: String?, properties: Map<String, Any?>? = null) {
        if (name == null) return Log.error("LoopAnalytics.track ignored: the event name is null")
        val props = if (properties == null) null else (readProperties { Sanitize.props(properties) } ?: return)
        AnalyticsRuntime.shared.enqueue { it.track(name, props) }
    }

    /** The signed-in user's id; null (or empty) means signed out. */
    @JvmStatic
    public fun setUserId(userId: String?) {
        AnalyticsRuntime.shared.enqueue { it.setUserId(userId) }
    }

    /**
     * Merges [properties] into the user properties sent with every event.
     * A null (or `JSONObject.NULL`) value removes that property.
     */
    @JvmStatic
    public fun setUserProperties(properties: Map<String, Any?>?) {
        if (properties == null) return Log.error("LoopAnalytics.setUserProperties ignored: properties is null")
        val update = readProperties { userPropertiesUpdate(properties) } ?: return
        AnalyticsRuntime.shared.enqueue { it.setUserProperties(update) }
    }

    /** The RevenueCat app user id (may be `$RCAnonymousID:…`); null clears it. */
    @JvmStatic
    public fun setPurchaserId(purchaserId: String?) {
        AnalyticsRuntime.shared.enqueue { it.setPurchaserId(purchaserId) }
    }

    /**
     * Uploads queued events now. Returns when the queue is empty or an
     * upload failed (events stay queued and are retried later).
     *
     * For Kotlin coroutines. From Java, use [flushAsync] with a callback.
     */
    @JvmSynthetic
    public suspend fun flush() {
        flushAsync().join()
    }

    /**
     * Forgets the current person: a new random device id, no user id, user
     * properties or purchaser id, and a new session. Events already queued
     * keep the identity they were tracked with. Opt-out is kept.
     *
     * For Kotlin coroutines. From Java, use [resetAsync] with a callback.
     */
    @JvmSynthetic
    public suspend fun reset() {
        resetAsync().join()
    }

    /** [flush] without a coroutine: the job completes when the flush does. */
    @JvmStatic
    public fun flushAsync(): Job {
        val done = Job()
        val runtime = AnalyticsRuntime.shared
        val queued = runtime.enqueueOperation(onDropped = { done.complete() }) { engine ->
            if (engine == null) {
                done.complete()
            } else {
                // Ordered with the other calls, but the upload itself runs
                // outside the call queue so a slow network never holds up
                // later calls.
                runtime.launch {
                    try {
                        engine.flush()
                    } finally {
                        done.complete()
                    }
                }
            }
        }
        if (!queued) done.complete()
        return done
    }

    /** [reset] without a coroutine: the job completes when the new identity is in place. */
    @JvmStatic
    public fun resetAsync(): Job {
        val done = Job()
        val queued = AnalyticsRuntime.shared.enqueueOperation(onDropped = { done.complete() }) { engine ->
            try {
                engine?.reset()
            } finally {
                done.complete()
            }
        }
        if (!queued) done.complete()
        return done
    }

    /**
     * [flush] for Java and other callers without coroutines: starts the
     * flush and returns at once. [callback], if any, runs on the main thread
     * when the flush is done (also when the call was dropped, e.g. before
     * `Loop.configure`).
     */
    @JvmStatic
    public fun flushAsync(callback: Runnable?) {
        callBackOnMainThread(flushAsync(), callback)
    }

    /**
     * [reset] for Java and other callers without coroutines: starts the
     * reset and returns at once. [callback], if any, runs on the main thread
     * once the new identity is in place.
     */
    @JvmStatic
    public fun resetAsync(callback: Runnable?) {
        callBackOnMainThread(resetAsync(), callback)
    }

    /**
     * When true, new events are dropped and nothing is uploaded until it is
     * set back to false. Queued events are kept and uploaded after opting
     * back in. Persisted across launches.
     */
    @JvmStatic
    public fun setOptOut(optOut: Boolean) {
        AnalyticsRuntime.shared.enqueue { it.setOptOut(optOut) }
    }

    /** The id events are attributed to; null until analytics has started. */
    @JvmStatic
    public val deviceId: String?
        get() = AnalyticsRuntime.shared.published?.deviceId

    /** The current session's start time in ms since epoch; null until analytics has started. */
    @JvmStatic
    public val sessionId: Long?
        get() = AnalyticsRuntime.shared.published?.sessionId

    /**
     * Test hook: disposes the shared engine and forgets [start]. The next
     * engine is built from [environment] (default: the real one).
     */
    internal fun resetForTesting(environment: ((LoopConfiguration) -> AnalyticsEnvironment)? = null) {
        AnalyticsRuntime.shared.resetForTesting(environment)
    }

    /**
     * A `setUserProperties` map as JSON: a key whose value is null or
     * `JSONObject.NULL` maps to [JsonValue.Null], which removes it.
     * Sanitising would strip those keys, so they are collected first.
     */
    internal fun userPropertiesUpdate(properties: Map<String, Any?>): JsonObject {
        val removed = properties.filterValues { it == null || it == JSONObject.NULL || it == JsonValue.Null }.keys
        val sanitized = Sanitize.props(properties)
        val update = LinkedHashMap<String, JsonValue>()
        for (key in properties.keys) {
            if (key in removed) update[key] = JsonValue.Null else sanitized[key]?.let { update[key] = it }
        }
        return update
    }

    private fun callBackOnMainThread(job: Job, callback: Runnable?) {
        if (callback == null) return
        job.invokeOnCompletion { Handler(Looper.getMainLooper()).post(callback) }
    }

    /**
     * Runs [read] on the caller's thread, so a map the app changes later is
     * not seen half-changed. Null (logged) if reading the map throws (e.g.
     * the app changes it on another thread meanwhile, or a map contains
     * itself and overflows the stack). Only an [OutOfMemoryError] is rethrown.
     */
    private inline fun <T : Any> readProperties(read: () -> T?): T? = try {
        read()
    } catch (e: Throwable) {
        if (e is OutOfMemoryError) throw e
        Log.error("Dropped a LoopAnalytics call: its properties could not be read (${e.javaClass.name})")
        null
    }
}

/**
 * Owns the shared engine and the serial call queue: one unlimited [Channel]
 * of operations consumed by a single coroutine on [AnalyticsThread], so
 * calls run in the order they were made.
 */
internal class AnalyticsRuntime {
    /** A queued call. [onDropped] runs instead of [run] if the queue stops first. */
    private class Operation(val run: suspend () -> Unit, val onDropped: () -> Unit)

    private val operations = Channel<Operation>(Channel.UNLIMITED, onUndeliveredElement = { it.onDropped() })
    private val scope = CoroutineScope(
        SupervisorJob() + AnalyticsThread.dispatcher + CoroutineExceptionHandler { _, error ->
            Log.error("LoopAnalytics stopped a task on an unexpected ${error.javaClass.name}")
        },
    )
    private val lock = Any()

    /** The engine for this run, once something started it. Guarded by [lock]. */
    private var slot: EngineSlot? = null

    /** Options from [start]. Guarded by [lock]. */
    private var startOptions: LoopAnalyticsOptions? = null

    /** Builds the next engine's environment. Guarded by [lock]. */
    private var makeEnvironment: (LoopConfiguration) -> AnalyticsEnvironment = PRODUCTION_ENVIRONMENT

    /** Whether the current run of failed engine starts was logged. Only touched on [AnalyticsThread]. */
    private var warnedAboutStartFailure = false

    init {
        // The consumer reports its own end below, so its handler only keeps
        // an Error away from the app's uncaught-exception handler.
        val consumer = scope.launch(CoroutineExceptionHandler { _, _ -> }) {
            for (operation in operations) {
                try {
                    operation.run()
                } catch (e: Exception) {
                    currentCoroutineContext().ensureActive()
                    Log.error("A LoopAnalytics call failed on an unexpected ${e.javaClass.name}")
                }
            }
        }
        // If the consumer ever ends (an Error in a call), calls queued behind
        // it are dropped and later ones refused, never buffered for the rest
        // of the process.
        consumer.invokeOnCompletion { cause ->
            // Logged before the queue closes, so whoever sees a call refused
            // can already see why.
            val reason = cause?.let { " on an unexpected ${it.javaClass.name}" }.orEmpty()
            Log.error("LoopAnalytics call queue stopped$reason; later calls are dropped")
            operations.cancel()
        }
    }

    val published: PublishedIdentity?
        get() = synchronized(lock) { slot }?.engine?.published

    fun start(options: LoopAnalyticsOptions) {
        synchronized(lock) {
            if (slot != null || startOptions != null) {
                Log.warning("LoopAnalytics.start(options) ignored: analytics was already started")
                slot?.warnIfReconfigured()
                return
            }
            startOptions = options
            startedSlot()
        }
    }

    /** Queues [body] to run on the engine after every earlier call. Dropped before `Loop.configure`. */
    fun enqueue(body: suspend (AnalyticsEngine) -> Unit) {
        enqueueOperation { engine -> if (engine != null) body(engine) }
    }

    /**
     * Queues [operation] with the engine it should run on (null if the
     * engine could not be built). Returns false, queuing nothing, before
     * `Loop.configure` or once the queue has stopped. [onDropped] runs
     * instead of [operation] if the queue stops before reaching it.
     */
    fun enqueueOperation(
        onDropped: () -> Unit = {},
        operation: suspend (AnalyticsEngine?) -> Unit,
    ): Boolean = synchronized(lock) {
        val slot = startedSlot() ?: return false
        slot.warnIfReconfigured()
        operations.trySend(Operation({ operation(slot.engine) }, onDropped)).isSuccess
    }

    /** Runs [body] in the runtime's scope, outside the call queue. */
    fun launch(body: suspend () -> Unit): Job = scope.launch { body() }

    /** Test hook: returns once every call queued so far has run (or was dropped). */
    suspend fun waitForPendingCalls() {
        val done = CompletableDeferred<Unit>()
        val finish = { done.complete(Unit) }
        if (operations.trySend(Operation({ finish() }, { finish() })).isFailure) return
        done.await()
    }

    fun resetForTesting(environment: ((LoopConfiguration) -> AnalyticsEnvironment)?) {
        synchronized(lock) {
            val previous = slot
            slot = null
            startOptions = null
            makeEnvironment = environment ?: PRODUCTION_ENVIRONMENT
            operations.trySend(Operation({ previous?.engine?.dispose() }, {}))
        }
    }

    /**
     * The running engine's slot, starting the engine if `Loop.configure` has
     * been called and nothing started it yet. Call with [lock] held.
     */
    private fun startedSlot(): EngineSlot? {
        slot?.let { return it }
        // Read before the configuration, so a `Loop.configure` racing with
        // this can only cause a needless warning, never hide a real one.
        val version = Loop.configurationVersion
        val configuration = Loop.configuration ?: return null
        val slot = EngineSlot(version)
        this.slot = slot
        val options = startOptions ?: LoopAnalyticsOptions()
        val makeEnvironment = this.makeEnvironment
        // Queued first, so every call queued after it finds the engine built.
        val create = Operation(
            run = {
                try {
                    slot.engine = AnalyticsEngine.create(
                        apiKey = configuration.apiKey,
                        serverUrl = configuration.options.serverUrl,
                        options = options,
                        environment = makeEnvironment(configuration),
                    )
                    warnedAboutStartFailure = false
                } catch (e: Exception) {
                    currentCoroutineContext().ensureActive()
                    // Calls already queued for this slot are dropped; the
                    // next call makes a new slot and tries again.
                    synchronized(lock) { if (this.slot === slot) this.slot = null }
                    if (!warnedAboutStartFailure) {
                        warnedAboutStartFailure = true
                        Log.warning("LoopAnalytics could not start (${e.javaClass.name}); the next call tries again")
                    }
                }
            },
            onDropped = {},
        )
        operations.trySend(create)
        return slot
    }

    companion object {
        /** Runs on [AnalyticsThread], so its disk work stays off the main thread. */
        private val PRODUCTION_ENVIRONMENT: (LoopConfiguration) -> AnalyticsEnvironment = { configuration ->
            AnalyticsEnvironment.production(configuration.applicationContext)
        }

        // After PRODUCTION_ENVIRONMENT, which the constructor reads.
        val shared = AnalyticsRuntime()
    }
}

/**
 * Holds the engine once its (asynchronous) start has run, and the
 * `Loop.configure` it was built from.
 */
internal class EngineSlot(private val configurationVersion: Int) {
    @Volatile var engine: AnalyticsEngine? = null
    private val warnedAboutReconfigure = AtomicBoolean(false)

    /**
     * Logs once if `Loop.configure` was called again after this engine was
     * built: the engine keeps its original key and server.
     */
    fun warnIfReconfigured() {
        if (Loop.configurationVersion == configurationVersion) return
        if (!warnedAboutReconfigure.compareAndSet(false, true)) return
        Log.warning(
            "Loop.configure was called again after analytics started; analytics keeps the API key and server it " +
                "started with. Call Loop.configure once, at launch.",
        )
    }
}
