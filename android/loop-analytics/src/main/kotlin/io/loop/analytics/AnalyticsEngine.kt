package io.loop.analytics

import io.loop.core.LoopContext
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference

/**
 * One running analytics instance: wires the event store, identity,
 * sessions, uploader, flush timer and app lifecycle together (port of the
 * Swift `AnalyticsEngine`).
 *
 * Never throws into the host app; problems are logged. Every call is a
 * no-op after [dispose]. Its state (identity, session, context cache) is
 * confined to [AnalyticsThread]; every call hops there. Background work it
 * starts itself (startup flush, timer ticks, lifecycle changes, flushes at
 * `flushQueueSize`) is tracked so [waitUntilIdle] can wait for it.
 */
internal class AnalyticsEngine private constructor(
    private val options: LoopAnalyticsOptions,
    private val environment: AnalyticsEnvironment,
    private val store: EventStore,
    private val identity: IdentityStore,
    private val session: SessionTracker,
    apiKey: String,
    serverUrl: String,
) {
    private val dispatcher = AnalyticsThread.dispatcher
    private val gate = UploadGate(optedOut = identity.optOut)
    private val work = BackgroundWork(dispatcher)

    /**
     * The batch `context` as of the last change, for the uploader. It reads
     * this while holding its own lock, so it must never call back into the
     * engine (or the uploader) to compute one.
     */
    private val uploaderContext = AtomicReference<JsonObject>(emptyMap())

    private val uploader = Uploader(
        store = store,
        transport = environment.transport,
        serverUrl = serverUrl,
        apiKey = apiKey,
        // Only for queued events stored without a context snapshot.
        context = { uploaderContext.get() },
        maxBatchSize = options.maxBatchSize,
        clock = environment.clock,
        isEnabled = { gate.isOpen },
        requestTimeoutMillis = environment.requestTimeoutMillis,
    )

    // Confined to the analytics thread.
    private var timer: Cancellable? = null
    private var disposed = false
    private var lastContext: ContextSnapshot? = null

    /** Device and session id, readable from any thread without waiting. */
    val published = PublishedIdentity()

    /**
     * Starts lifecycle observation and the flush timer, and fixes the batch
     * left from the previous run before returning, so the app's first
     * `track()` cannot join it; that batch then uploads in the background.
     */
    private suspend fun start() {
        environment.lifecycle.start { foreground, initial ->
            if (!gate.isClosed) work.spawn { onLifecycle(foreground, initial) }
        }
        timer = environment.scheduler.every(options.flushIntervalMillis) {
            work.spawn { onTick() }
        }
        contextSnapshot()
        publish()
        if (store.count > 0) {
            uploader.primePendingBatch()
            flushInBackground()
        }
    }

    // State

    suspend fun deviceId(): String = confined { identity.deviceId }

    suspend fun userId(): String? = confined { identity.userId }

    /** The current session's start time in ms since epoch. */
    suspend fun sessionId(): Long? = confined { session.sessionId }

    suspend fun isOptedOut(): Boolean = confined { identity.optOut }

    /** Events stored and not yet acknowledged by the server. */
    fun queueLength(): Int = store.count

    // Calls

    /**
     * Records an event. Null property values are stripped. The event is on
     * disk when this returns.
     */
    suspend fun track(name: String, properties: JsonObject?) = confined {
        if (disposed) return@confined
        if (!Sanitize.isValidEventName(name)) {
            // Checked before anything that logs the name: an invalid one may
            // not be a name the developer chose, so only its length is logged.
            val length = Sanitize.trimWhitespace(name).length
            Log.warning("Dropped event: its name is $length characters once trimmed; names must be 1–${Sanitize.MAX_NAME}")
            return@confined
        }
        if (identity.optOut) {
            Log.debug("Dropped event \"$name\": analytics is opted out")
            return@confined
        }
        val event = LoopEvent(
            id = environment.newEventId(),
            name = name,
            occurredAtMillis = environment.clock.nowMillis(),
            sessionId = session.onEvent(),
            deviceId = identity.deviceId,
            userId = identity.userId,
            props = Sanitize.props(properties),
            userProps = identity.userProperties,
            context = contextSnapshot(),
        )
        publish()
        val size = try {
            JsonValue.Obj(event.wireJson()).toJson().toByteArray(Charsets.UTF_8).size
        } catch (_: JsonException) {
            Log.error("Dropped event \"$name\": it could not be encoded as JSON")
            return@confined
        }
        if (size > MAX_EVENT_BYTES) {
            Log.warning("Dropped event \"$name\": $size bytes exceeds the $MAX_EVENT_BYTES byte limit")
            return@confined
        }
        store.add(event)
        if (store.count >= options.flushQueueSize) flushInBackground()
    }

    /** The signed-in user's id; null or empty means signed out. */
    suspend fun setUserId(userId: String?) = confined {
        if (disposed) return@confined
        identity.setUserId(nonEmpty(userId))
    }

    /**
     * Merges [properties] into the user-property snapshot sent with every
     * event. A [JsonValue.Null] value removes that property.
     */
    suspend fun setUserProperties(properties: JsonObject) = confined {
        if (disposed) return@confined
        // Sanitising strips nulls (nested ones included), but a top-level
        // null here means "remove", so put those back.
        val merged = LinkedHashMap(Sanitize.props(properties))
        for ((key, value) in properties) {
            if (value == JsonValue.Null) merged[key] = JsonValue.Null
        }
        identity.mergeUserProperties(merged)
    }

    /** The RevenueCat app user id; null or empty clears it. */
    suspend fun setPurchaserId(purchaserId: String?) = confined {
        if (disposed) return@confined
        identity.setPurchaserId(nonEmpty(purchaserId))
        contextSnapshot()
    }

    /**
     * Uploads queued events now. Returns when the queue is empty or an
     * upload failed (the events stay queued and are retried with backoff).
     */
    suspend fun flush() {
        if (confined { disposed }) return
        uploader.flush()
    }

    /**
     * A new random device id, no user id, user properties or purchaser id,
     * and a new session. Queued events keep the identity they were tracked
     * with. Opt-out is kept.
     */
    suspend fun reset() = confined {
        if (disposed) return@confined
        identity.reset()
        session.startNew()
        contextSnapshot()
        publish()
    }

    /**
     * When true, new events are dropped and nothing is uploaded; queued
     * events are kept and uploaded (at once) after opting back in.
     * Persisted.
     */
    suspend fun setOptOut(optOut: Boolean) = confined {
        if (disposed) return@confined
        identity.setOptOut(optOut)
        gate.setOptedOut(optOut)
        if (!optOut && store.count > 0) flushInBackground()
    }

    /** Returns once no background work is running and no upload is in flight. */
    suspend fun waitUntilIdle() {
        do {
            work.idle()
            uploader.waitForInFlight()
        } while (work.isBusy)
    }

    /**
     * Stops uploads, the timer and lifecycle handling, then waits for the
     * upload in flight, if any, bounded by the request timeout. Starts no
     * new upload: queued events stay on disk for the next start. For tests.
     */
    suspend fun dispose() {
        val disposing = confined {
            if (disposed) return@confined false
            // The gate first: from here no drain sends another batch.
            gate.close()
            disposed = true
            timer?.cancel()
            timer = null
            true
        }
        if (!disposing) return
        withTimeoutOrNull(environment.requestTimeoutMillis) { waitUntilIdle() }
    }

    // Background work

    private suspend fun onLifecycle(foreground: Boolean, initial: Boolean) {
        if (disposed) return
        if (initial) {
            // Starting in the foreground starts or continues the session but
            // is not itself a lifecycle event: nothing is uploaded for it.
            if (foreground) {
                session.onForeground()
                publish()
            }
            return
        }
        if (foreground) {
            session.onForeground()
            publish()
            if (store.count > 0) uploader.flush()
        } else {
            session.onBackground()
            publish()
            uploader.flush()
        }
    }

    private suspend fun onTick() {
        if (disposed || store.count == 0) return
        uploader.flush()
    }

    private fun flushInBackground() {
        work.spawn { uploader.flush() }
    }

    private fun publish() {
        published.set(identity.deviceId, session.sessionId)
    }

    private suspend fun <T> confined(block: suspend () -> T): T = withContext(dispatcher) { block() }

    // Context

    private class ContextSnapshot(val context: LoopContext, val purchaserId: String?, val json: JsonObject)

    /** The batch `context` as of now. Reused while nothing changes. */
    private fun contextSnapshot(): JsonObject {
        val context = environment.context()
        val purchaserId = identity.purchaserId
        lastContext?.let { last ->
            if (last.context == context && last.purchaserId == purchaserId) return last.json
        }
        val json = contextJson(context, purchaserId)
        lastContext = ContextSnapshot(context, purchaserId, json)
        uploaderContext.set(json)
        return json
    }

    /** [LoopContext.json] as JSON values. */
    private fun contextJson(context: LoopContext, purchaserId: String?): JsonObject {
        val json = context.json(purchaserId, environment.sdk)
        val fields = LinkedHashMap<String, Any?>()
        for (key in json.keys()) fields[key] = json.opt(key)
        // Sanitising turns the org.json values into JSON values but also
        // strips the JSONObject.NULL used for a missing purchaser id, which
        // the wire keeps as an explicit null.
        val out = LinkedHashMap(Sanitize.props(fields))
        out["purchaserId"] = purchaserId?.let { JsonValue.Str(it) } ?: JsonValue.Null
        return out
    }

    companion object {
        /** Server limit on one event's wire JSON. */
        const val MAX_EVENT_BYTES = 32 * 1024

        /**
         * Loads the queue and identity, starts lifecycle observation and the
         * flush timer, and fixes the batch left from the previous run (then
         * uploads it in the background). Runs on [AnalyticsThread]: the
         * queue and preferences are read from disk here.
         */
        suspend fun create(
            apiKey: String,
            serverUrl: String,
            options: LoopAnalyticsOptions,
            environment: AnalyticsEnvironment,
        ): AnalyticsEngine = withContext(AnalyticsThread.dispatcher) {
            val key = Sanitize.trimWhitespace(apiKey)
            if (key.isEmpty()) Log.error("The Loop API key is empty; analytics uploads will fail")
            val engine = AnalyticsEngine(
                options = options,
                environment = environment,
                store = EventStore(environment.queueFile, options.maxQueueSize),
                identity = IdentityStore(environment.kv, options.legacyDeviceId, environment.newDeviceId),
                session = SessionTracker(
                    environment.kv,
                    maxOf(0L, options.minTimeBetweenSessionsMillis),
                    environment.clock,
                ),
                apiKey = key,
                serverUrl = serverUrl,
            )
            engine.start()
            engine
        }

        private fun nonEmpty(id: String?): String? = id?.takeIf { it.isNotEmpty() }
    }
}

/**
 * The one thread analytics state lives on: the facade's call queue and the
 * engine run here, so identity, sessions and the call order need no locks.
 * Uploads run on `Dispatchers.IO`, never here.
 */
internal object AnalyticsThread {
    val dispatcher: CoroutineDispatcher = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "LoopAnalytics").apply { isDaemon = true }
    }.asCoroutineDispatcher()
}

/** Whether uploads may run: not opted out and not disposed. Read by the uploader from any thread. */
internal class UploadGate(optedOut: Boolean) {
    @Volatile private var optedOut = optedOut

    /** True once the engine is disposed. */
    @Volatile var isClosed = false
        private set

    val isOpen: Boolean
        get() = !optedOut && !isClosed

    fun setOptedOut(optedOut: Boolean) {
        this.optedOut = optedOut
    }

    fun close() {
        isClosed = true
    }
}

/** Coroutines the engine starts on its own, so [idle] can await them. */
internal class BackgroundWork(dispatcher: CoroutineDispatcher) {
    private val parent = SupervisorJob()
    private val scope = CoroutineScope(
        parent + dispatcher + CoroutineExceptionHandler { _, error ->
            Log.error("Analytics background work stopped by an unexpected ${error.javaClass.name}")
        },
    )

    val isBusy: Boolean
        get() = parent.children.any()

    /** Runs [body] on the engine's thread. Registered at once, so [idle] sees it. */
    fun spawn(body: suspend () -> Unit) {
        scope.launch { body() }
    }

    /** Returns once every coroutine, including ones started meanwhile, is done. */
    suspend fun idle() {
        while (true) {
            val running = parent.children.toList()
            if (running.isEmpty()) return
            running.joinAll()
        }
    }
}

/** The engine's device and session id for synchronous readers. */
internal class PublishedIdentity {
    private class Snapshot(val deviceId: String, val sessionId: Long?)

    @Volatile private var snapshot: Snapshot? = null

    val deviceId: String?
        get() = snapshot?.deviceId

    val sessionId: Long?
        get() = snapshot?.sessionId

    fun set(deviceId: String, sessionId: Long?) {
        snapshot = Snapshot(deviceId, sessionId)
    }
}
