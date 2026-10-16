package io.loop.analytics

import io.loop.core.Gzip
import io.loop.core.LoopClock
import io.loop.core.LoopContext
import io.loop.core.MemoryKeyValueStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.Locale
import java.util.concurrent.atomic.AtomicInteger
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

// Engine harness (port of the Swift Support.swift)

/** A thread-safe counter for sequential ids (shared across restarts). */
internal class Counter {
    private val value = AtomicInteger()

    fun next(): Int = value.incrementAndGet()
}

/** A request as the server would see it: URL, headers and the gzip-decoded JSON body. */
internal class RecordedRequest(val url: String, val headers: Map<String, String>, rawBody: ByteArray) {
    val body: JsonObject = JsonValue.parseObject(String(Gzip.decompress(rawBody), Charsets.UTF_8))

    val events: List<JsonObject>
        get() = (body["events"] as? JsonValue.Arr)?.values.orEmpty().mapNotNull { (it as? JsonValue.Obj)?.values }

    /** The batch `context` object. */
    val context: JsonObject
        get() = (body["context"] as? JsonValue.Obj)?.values.orEmpty()

    val names: List<String>
        get() = events.mapNotNull { (it["name"] as? JsonValue.Str)?.value }
}

/**
 * Records every upload and answers with the queued replies (default:
 * `202 {"accepted":<n>,"dropped":0}`). Thread-safe.
 */
internal class RecordingTransport : AnalyticsTransport {
    private sealed interface Reply {
        class Status(val status: Int, val headers: Map<String, String>, val body: String) : Reply
        object NetworkError : Reply
    }

    private val lock = Any()
    private val recorded = ArrayList<RecordedRequest>()
    private val replies = ArrayDeque<Reply>()

    /** How long the next request hangs, in ms (real time). */
    private var holdNext: Long? = null

    /** Every request so far, gzip-decoded. */
    val requests: List<RecordedRequest>
        get() = synchronized(lock) { recorded.toList() }

    /** Every event sent so far, in order. */
    val sentEvents: List<JsonObject>
        get() = requests.flatMap { it.events }

    /** The names of every event sent so far, in order. */
    val sentNames: List<String>
        get() = requests.flatMap { it.names }

    /** Queues the reply for the next request. */
    fun respond(status: Int, headers: Map<String, String> = emptyMap(), body: String = "") {
        synchronized(lock) { replies.addLast(Reply.Status(status, headers, body)) }
    }

    /** The next request fails with a network error. */
    fun failNext() {
        synchronized(lock) { replies.addLast(Reply.NetworkError) }
    }

    /** The next request never completes on its own: it hangs until the uploader gives up on it and cancels it. */
    fun hold() = hold(3_600_000)

    /** The next request is answered only after [millis] (real time). */
    fun hold(millis: Long) {
        synchronized(lock) { holdNext = millis }
    }

    override suspend fun send(url: String, headers: Map<String, String>, body: ByteArray): TransportResponse {
        val sent = RecordedRequest(url, headers, body)
        val (reply, held) = synchronized(lock) {
            recorded.add(sent)
            val held = holdNext
            holdNext = null
            replies.removeFirstOrNull() to held
        }
        if (held != null) delay(held)
        return when (reply) {
            null -> TransportResponse(
                202,
                emptyMap(),
                """{"accepted":${sent.events.size},"dropped":0}""".toByteArray(Charsets.UTF_8),
            )
            is Reply.Status -> TransportResponse(
                reply.status,
                reply.headers.mapKeys { it.key.lowercase(Locale.ROOT) },
                reply.body.toByteArray(Charsets.UTF_8),
            )
            Reply.NetworkError -> throw IOException("The Internet connection appears to be offline")
        }
    }

    /** Polls (real time) until at least [n] requests were recorded. */
    suspend fun waitForRequests(n: Int, timeoutMillis: Long = 2_000) {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000
        while (requests.size < n) {
            if (System.nanoTime() > deadline) throw AssertionError("Timed out waiting for $n request(s); got ${requests.size}")
            delay(5)
        }
    }
}

/** A lifecycle the test drives with [emit]. Reports its state as the initial one when started. */
internal class FakeLifecycle(isForeground: Boolean = true) : LifecycleSource {
    private val lock = Any()
    private var foreground = isForeground
    private var onState: ((Boolean, Boolean) -> Unit)? = null

    val isForeground: Boolean
        get() = synchronized(lock) { foreground }

    override fun start(onState: (foreground: Boolean, initial: Boolean) -> Unit) {
        val initial = synchronized(lock) {
            this.onState = onState
            foreground
        }
        onState(initial, true)
    }

    /** The app moves to the foreground (`true`) or the background. */
    fun emit(foreground: Boolean) {
        val onState = synchronized(lock) {
            this.foreground = foreground
            onState
        }
        onState?.invoke(foreground, false)
    }
}

/**
 * Periodic timers that fire only when the test advances the fake clock.
 * Every timer's state is read and written under one lock: cancelling (from
 * the engine) and advancing (from the test) come from different threads.
 */
internal class FakeScheduler(private val clock: FakeClock) : Scheduler {
    private class Entry(val interval: Long, var due: Long, val tick: () -> Unit) {
        var cancelled = false
    }

    private val lock = Any()

    /** Entries are never removed, so an index stays valid. */
    private val entries = ArrayList<Entry>()

    /** Timers scheduled and not cancelled. */
    val activeTimers: Int
        get() = synchronized(lock) { entries.count { !it.cancelled } }

    /** The interval of every timer scheduled so far, in ms. */
    val intervals: List<Long>
        get() = synchronized(lock) { entries.map { it.interval } }

    override fun every(intervalMillis: Long, tick: () -> Unit): Cancellable {
        val interval = maxOf(1L, intervalMillis)
        val entry = Entry(interval, clock.now + interval, tick)
        synchronized(lock) { entries.add(entry) }
        return Cancellable { synchronized(lock) { entry.cancelled = true } }
    }

    /**
     * Moves the clock forward by [ms], firing every periodic tick that comes
     * due, in time order, with the clock set to the tick's due time. [settle]
     * runs after each tick (e.g. `engine.waitUntilIdle()`).
     */
    suspend fun advance(ms: Long, settle: suspend () -> Unit) {
        val target = clock.now + ms
        while (true) {
            val (due, tick) = takeNextDue(target) ?: break
            clock.now = due
            tick()
            settle()
        }
        clock.now = target
    }

    /**
     * The earliest tick due at or before [target] (ties in the order the
     * timers were scheduled), with that timer already moved to its next due time.
     */
    private fun takeNextDue(target: Long): Pair<Long, () -> Unit>? = synchronized(lock) {
        val entry = entries.filter { !it.cancelled && it.due <= target }.minByOrNull { it.due } ?: return null
        val due = entry.due
        entry.due += entry.interval
        due to entry.tick
    }
}

/** The device context the engine reads, settable per test. */
internal class ContextBox {
    @Volatile var value: LoopContext = CONFORMANCE

    companion object {
        /** The conformance runner's fixed context (`conformance/README.md`). */
        val CONFORMANCE = LoopContext(
            platform = "iOS",
            osName = "ios",
            osVersion = "18.0",
            appVersion = "1.0.0",
            appBuild = "1",
            deviceModel = "iPhone15,3",
            deviceManufacturer = "Apple",
            isTablet = false,
            locale = "en-GB",
        )
    }
}

/**
 * One engine over a fake environment: a temp-directory queue file, an
 * in-memory key-value store, a fake clock, transport, lifecycle and
 * scheduler, and sequential ids. [restarted] builds a new engine over the
 * same storage, clock and id counters with a fresh lifecycle, scheduler and
 * (unless one is passed) transport.
 */
internal class EngineHarness private constructor(
    val directory: File,
    val kv: MemoryKeyValueStore,
    val clock: FakeClock,
    val eventIds: Counter,
    val deviceIds: Counter,
    val context: ContextBox,
    val transport: RecordingTransport,
    val options: LoopAnalyticsOptions,
    val requestTimeoutMillis: Long,
    startsInForeground: Boolean = true,
) {
    val queueFile = File(directory, "analytics-queue.jsonl")

    /** In the foreground at start unless the restart said otherwise. */
    val lifecycle = FakeLifecycle(startsInForeground)
    val scheduler = FakeScheduler(clock)

    /** The running engine; set once started (see [create]'s `startEngine`). */
    lateinit var engine: AnalyticsEngine
        private set

    val hasEngine: Boolean
        get() = this::engine.isInitialized

    fun environment(): AnalyticsEnvironment = AnalyticsEnvironment(
        clock = clock,
        transport = transport,
        queueFile = queueFile,
        kv = kv,
        context = { context.value },
        lifecycle = lifecycle,
        newEventId = { String.format(Locale.ROOT, "00000000-0000-4000-8000-%012d", eventIds.next()) },
        newDeviceId = { "DEVICE-${deviceIds.next()}R" },
        scheduler = scheduler,
        sdk = AnalyticsEnvironment.SDK,
        requestTimeoutMillis = requestTimeoutMillis,
    )

    private suspend fun start() {
        engine = AnalyticsEngine.create(API_KEY, SERVER_URL, options, environment())
    }

    /**
     * A new engine over the same storage (dispose the previous one first).
     * Every (re)start is in the foreground unless [startsInForeground] is false.
     */
    suspend fun restarted(
        options: LoopAnalyticsOptions? = null,
        context: ContextBox? = null,
        transport: RecordingTransport? = null,
        startsInForeground: Boolean = true,
    ): EngineHarness {
        val next = EngineHarness(
            directory = directory,
            kv = kv,
            clock = clock,
            eventIds = eventIds,
            deviceIds = deviceIds,
            context = context ?: this.context,
            transport = transport ?: RecordingTransport(),
            options = options ?: this.options,
            requestTimeoutMillis = requestTimeoutMillis,
            startsInForeground = startsInForeground,
        )
        next.start()
        return next
    }

    /** Moves the fake clock, firing due flush timers and settling after each. */
    suspend fun advance(ms: Long) {
        scheduler.advance(ms) { engine.waitUntilIdle() }
    }

    /** The lines in the queue file. */
    fun queueFileLines(): List<String> =
        if (queueFile.exists()) queueFile.readText(Charsets.UTF_8).split('\n').filter { it.isNotEmpty() } else emptyList()

    fun removeStorage() {
        directory.deleteRecursively()
    }

    companion object {
        const val API_KEY = "loop_pk_test"
        const val SERVER_URL = "https://loop.test"

        /** 2026-01-01T00:00:00.000Z */
        const val CLOCK_START = 1_767_225_600_000L

        /** [startEngine] false only builds the environment (e.g. to hand it to the facade). */
        suspend fun create(
            options: LoopAnalyticsOptions = LoopAnalyticsOptions(),
            requestTimeoutMillis: Long = 500,
            startEngine: Boolean = true,
        ): EngineHarness {
            val harness = EngineHarness(
                directory = Files.createTempDirectory("loop_engine_test_").toFile(),
                kv = MemoryKeyValueStore(),
                clock = FakeClock(CLOCK_START),
                eventIds = Counter(),
                deviceIds = Counter(),
                context = ContextBox(),
                transport = RecordingTransport(),
                options = options,
                requestTimeoutMillis = requestTimeoutMillis,
            )
            if (startEngine) harness.start()
            return harness
        }
    }
}

/** Runs a coroutine test body with a real-time bound so a hang fails instead of stalling the build. */
internal fun blockingTest(timeoutMillis: Long = 30_000, body: suspend CoroutineScope.() -> Unit) {
    runBlocking { withTimeout(timeoutMillis) { body() } }
}
