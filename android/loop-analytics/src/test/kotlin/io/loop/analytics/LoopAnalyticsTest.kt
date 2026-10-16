package io.loop.analytics

import android.content.ContextWrapper
import io.loop.core.Loop
import io.loop.core.LoopOptions
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

/**
 * Port of the Swift `LoopAnalyticsTests`: the facade and the engine over a
 * fake environment (plain JVM; Android adapters are in `AndroidPlatformTest`).
 */
class LoopAnalyticsTest {
    private val harnesses = mutableListOf<EngineHarness>()
    private val logs = mutableListOf<LogRecorder>()

    @After
    fun tearDown() = blockingTest {
        LoopAnalytics.resetForTesting()
        AnalyticsRuntime.shared.waitForPendingCalls()
        Loop.resetForTesting()
        for (h in harnesses) {
            if (h.hasEngine) h.engine.dispose()
            h.removeStorage()
        }
        harnesses.clear()
        logs.forEach(LogRecorder::stop)
        logs.clear()
    }

    // Helpers

    private suspend fun harness(
        options: LoopAnalyticsOptions = LoopAnalyticsOptions(),
        requestTimeoutMillis: Long = 500,
        startEngine: Boolean = true,
    ): EngineHarness {
        val h = EngineHarness.create(options, requestTimeoutMillis, startEngine)
        harnesses.add(h)
        return h
    }

    private suspend fun restart(
        h: EngineHarness,
        options: LoopAnalyticsOptions? = null,
        context: ContextBox? = null,
    ): EngineHarness {
        h.engine.dispose()
        val next = h.restarted(options = options, context = context)
        harnesses.add(next)
        return next
    }

    /** The facade over a fake environment, not yet configured. */
    private suspend fun facadeHarness(requestTimeoutMillis: Long = 500): EngineHarness {
        val h = harness(requestTimeoutMillis = requestTimeoutMillis, startEngine = false)
        Loop.resetForTesting()
        LoopAnalytics.resetForTesting { h.environment() }
        return h
    }

    private fun configure(apiKey: String = EngineHarness.API_KEY, serverUrl: String = EngineHarness.SERVER_URL) {
        // A bare Context: the fake environment never uses it.
        Loop.configure(ContextWrapper(null), apiKey, LoopOptions(serverUrl = serverUrl))
    }

    private fun recordLog(): LogRecorder = LogRecorder().also { logs.add(it) }

    private fun str(value: String) = JsonValue.Str(value)

    private fun int(value: Long) = JsonValue.IntV(value)

    private fun obj(vararg pairs: Pair<String, JsonValue>) = JsonValue.Obj(linkedMapOf(*pairs))

    // Facade

    @Test
    fun calls_before_configure_are_dropped_without_crashing() = blockingTest {
        Loop.resetForTesting()
        LoopAnalytics.resetForTesting()
        LoopAnalytics.track("Item Viewed")
        LoopAnalytics.setUserId("u1")
        LoopAnalytics.flush()
        LoopAnalytics.flushAsync().join()
        LoopAnalytics.reset()
        assertNull(LoopAnalytics.deviceId)
    }

    @Test
    fun first_call_after_configure_starts_with_default_options() = blockingTest {
        val h = facadeHarness()
        LoopAnalytics.track("Before Configure")
        LoopAnalytics.setOptOut(true)
        LoopAnalytics.flush()
        assertNull(LoopAnalytics.deviceId)
        assertNull(LoopAnalytics.sessionId)

        configure()
        LoopAnalytics.track("Item Viewed")
        LoopAnalytics.flush()

        assertEquals(listOf("Item Viewed"), h.transport.sentNames)
        assertEquals("DEVICE-1R", LoopAnalytics.deviceId)
        assertEquals(EngineHarness.CLOCK_START, LoopAnalytics.sessionId)
        assertEquals("default flushIntervalMillis", listOf(30_000L), h.scheduler.intervals)

        // The engine is running: a later start is ignored.
        LoopAnalytics.start(LoopAnalyticsOptions(legacyDeviceId = "ignored", flushIntervalMillis = 5_000))
        LoopAnalytics.flush()
        assertEquals("DEVICE-1R", LoopAnalytics.deviceId)
        assertEquals(listOf(30_000L), h.scheduler.intervals)
    }

    @Test
    fun start_options_apply_and_a_second_start_is_ignored() = blockingTest {
        val h = facadeHarness()
        configure()
        LoopAnalytics.start(LoopAnalyticsOptions(flushQueueSize = 2, flushIntervalMillis = 60_000))
        LoopAnalytics.start(LoopAnalyticsOptions(flushQueueSize = 100, flushIntervalMillis = 5_000))

        LoopAnalytics.track("A")
        LoopAnalytics.track("B")
        h.transport.waitForRequests(1)

        assertEquals(listOf("A", "B"), h.transport.sentNames)
        assertEquals(listOf(60_000L), h.scheduler.intervals)
    }

    @Test
    fun options_constructor_takes_any_option_and_defaults_the_rest() {
        val all = LoopAnalyticsOptions(
            flushQueueSize = 5,
            flushIntervalMillis = 10_000,
            minTimeBetweenSessionsMillis = 60_000,
            maxQueueSize = 200,
            maxBatchSize = 50,
            legacyDeviceId = "legacy-1",
        )
        assertEquals(5, all.flushQueueSize)
        assertEquals(10_000L, all.flushIntervalMillis)
        assertEquals(60_000L, all.minTimeBetweenSessionsMillis)
        assertEquals(200, all.maxQueueSize)
        assertEquals(50, all.maxBatchSize)
        assertEquals("legacy-1", all.legacyDeviceId)

        for (options in listOf(LoopAnalyticsOptions(legacyDeviceId = "legacy-1"), LoopAnalyticsOptions())) {
            assertEquals(30, options.flushQueueSize)
            assertEquals(30_000L, options.flushIntervalMillis)
            assertEquals(300_000L, options.minTimeBetweenSessionsMillis)
            assertEquals(1000, options.maxQueueSize)
            assertEquals(100, options.maxBatchSize)
        }
        assertNull(LoopAnalyticsOptions().legacyDeviceId)
    }

    @Test
    fun start_with_an_inline_legacy_device_id() = blockingTest {
        facadeHarness()
        configure()
        LoopAnalytics.start(LoopAnalyticsOptions(legacyDeviceId = "legacy-2"))
        LoopAnalytics.track("A")
        LoopAnalytics.flush()

        assertEquals("legacy-2", LoopAnalytics.deviceId)
    }

    @Test
    fun start_before_configure_keeps_its_options_for_the_engine() = blockingTest {
        facadeHarness()
        LoopAnalytics.start(LoopAnalyticsOptions(legacyDeviceId = "legacy-1"))
        assertNull(LoopAnalytics.deviceId)

        configure()
        LoopAnalytics.track("A")
        LoopAnalytics.flush()

        assertEquals("legacy-1", LoopAnalytics.deviceId)
    }

    @Test
    fun set_user_properties_removes_keys_set_to_null_or_JSONObject_NULL() = blockingTest {
        val h = facadeHarness()
        configure()
        LoopAnalytics.setUserProperties(mapOf("Plan" to "annual", "X" to 1, "Y" to "y", "Z" to true))
        LoopAnalytics.setUserProperties(
            mapOf("X" to null, "Y" to JSONObject.NULL, "Z" to null, "W" to 2, "Nested" to mapOf("gone" to null, "kept" to 1)),
        )
        LoopAnalytics.track("A")
        LoopAnalytics.flush()

        assertEquals(
            "null and JSONObject.NULL remove a key; a nested null is only stripped",
            obj("Plan" to str("annual"), "W" to int(2), "Nested" to obj("kept" to int(1))),
            h.transport.sentEvents.first()["userProps"],
        )
    }

    @Test
    fun user_id_and_merged_user_properties_are_snapshotted_per_event_through_the_facade() = blockingTest {
        // Conformance case 21, driven through the public API.
        val h = facadeHarness()
        configure()
        LoopAnalytics.setUserId("u1")
        LoopAnalytics.setUserProperties(mapOf("Plan" to "annual", "X" to 1))
        LoopAnalytics.setUserProperties(mapOf("X" to null, "Y" to "y"))
        LoopAnalytics.track("A")
        LoopAnalytics.setUserId(null)
        LoopAnalytics.track("B")
        LoopAnalytics.flush()

        val events = h.transport.sentEvents
        assertEquals(listOf("A", "B"), h.transport.sentNames)
        assertEquals(str("u1"), events[0]["userId"])
        assertEquals(JsonValue.Null, events[1]["userId"])
        for (event in events) assertEquals(obj("Plan" to str("annual"), "Y" to str("y")), event["userProps"])
    }

    @Test
    fun fire_and_forget_calls_keep_their_order() = blockingTest {
        val h = facadeHarness()
        configure()
        LoopAnalytics.start(LoopAnalyticsOptions(flushQueueSize = 1000))
        for (i in 0 until 50) {
            LoopAnalytics.setUserId("u$i")
            LoopAnalytics.setUserProperties(mapOf("Step" to i))
            LoopAnalytics.track("E$i", mapOf("Index" to i))
        }
        LoopAnalytics.flush()

        assertEquals((0 until 50).map { "E$it" }, h.transport.sentNames)
        h.transport.sentEvents.forEachIndexed { i, event ->
            assertEquals(str("u$i"), event["userId"])
            assertEquals(obj("Step" to int(i.toLong())), event["userProps"])
            assertEquals(obj("Index" to int(i.toLong())), event["props"])
        }
    }

    @Test
    fun the_properties_are_read_when_track_is_called() = blockingTest {
        val h = facadeHarness()
        configure()
        val props = mutableMapOf<String, Any?>("Index" to 1)
        LoopAnalytics.track("A", props)
        props["Index"] = 2
        props["Later"] = true
        LoopAnalytics.flush()

        assertEquals(obj("Index" to int(1)), h.transport.sentEvents.single()["props"])
    }

    @Test
    fun reset_completes_with_the_new_identity_in_place() = blockingTest {
        facadeHarness()
        configure()
        LoopAnalytics.setUserId("u1")
        LoopAnalytics.track("A")
        LoopAnalytics.flush()
        assertEquals("DEVICE-1R", LoopAnalytics.deviceId)

        LoopAnalytics.reset()

        assertEquals("DEVICE-2R", LoopAnalytics.deviceId)
    }

    @Test
    fun flushAsync_and_resetAsync_complete_their_jobs_for_callers_without_coroutines() = blockingTest {
        val h = facadeHarness()
        configure()
        LoopAnalytics.track("A")
        LoopAnalytics.flushAsync().join()
        assertEquals(listOf("A"), h.transport.sentNames)

        LoopAnalytics.resetAsync().join()
        assertEquals("DEVICE-2R", LoopAnalytics.deviceId)
    }

    @Test
    fun a_slow_flush_does_not_hold_up_later_calls() = blockingTest {
        val h = facadeHarness(requestTimeoutMillis = 1500)
        configure()
        LoopAnalytics.track("A")
        h.transport.hold()
        val flush = launch { LoopAnalytics.flush() }
        h.transport.waitForRequests(1)

        LoopAnalytics.track("B")

        // B reaches the queue file while the request for A still hangs.
        val deadline = System.nanoTime() + 1_000_000_000L
        while (h.queueFileLines().none { it.contains("\"name\":\"B\"") }) {
            if (System.nanoTime() > deadline) fail("B was not queued while the upload hung")
            delay(5)
        }
        assertTrue("the flush still waits for the hung request", flush.isActive)
        flush.join() // returns once the request times out
    }

    @Test
    fun reconfiguring_after_start_warns_once_and_keeps_the_engine() = blockingTest {
        val log = recordLog()
        val h = facadeHarness()
        configure()
        LoopAnalytics.track("A")
        LoopAnalytics.flush()
        assertEquals(emptyList<String>(), log.messages(Log.Level.WARNING).filter { it.contains("Loop.configure") })

        configure(apiKey = "loop_pk_other", serverUrl = "https://other.test")
        LoopAnalytics.track("B")
        LoopAnalytics.setUserId("u1")
        LoopAnalytics.track("C")
        LoopAnalytics.flush()

        assertEquals(1, log.messages(Log.Level.WARNING).count { it.contains("Loop.configure") })
        assertEquals(listOf("A", "B", "C"), h.transport.sentNames)
        for (sent in h.transport.requests) {
            assertEquals("https://loop.test/api/ingest/analytics/batch", sent.url)
            assertEquals("Bearer loop_pk_test", sent.headers["Authorization"])
        }
        assertEquals("DEVICE-1R", LoopAnalytics.deviceId)
    }

    @Test
    fun an_Error_stops_the_call_queue_and_later_calls_are_dropped_not_buffered() = blockingTest {
        val log = recordLog()
        val h = harness(startEngine = false)
        configure()
        // A queue of its own: the shared one must outlive this test.
        val runtime = AnalyticsRuntime()
        runtime.resetForTesting { h.environment() }
        val ran = AtomicInteger()
        val gate = CompletableDeferred<Unit>()
        assertTrue(runtime.enqueueOperation { gate.await() })
        assertTrue(runtime.enqueueOperation { throw StackOverflowError() })
        assertTrue("queued behind the Error", runtime.enqueueOperation { ran.incrementAndGet() })
        val waiting = async { runtime.waitForPendingCalls() }
        gate.complete(Unit)

        waiting.await() // returns although its call is dropped
        assertEquals("calls queued behind the Error are dropped", 0, ran.get())
        assertFalse("later calls are refused, not buffered", runtime.enqueueOperation { ran.incrementAndGet() })
        runtime.waitForPendingCalls()
        assertEquals(0, ran.get())
        val stopped = log.messages(Log.Level.ERROR).filter { it.contains("call queue stopped") }
        assertEquals(log.messages(Log.Level.ERROR).toString(), listOf("LoopAnalytics call queue stopped on an unexpected java.lang.StackOverflowError; later calls are dropped"), stopped)
    }

    @Test
    fun an_Exception_in_a_call_is_logged_and_later_calls_still_run() = blockingTest {
        val log = recordLog()
        val h = harness(startEngine = false)
        configure()
        val runtime = AnalyticsRuntime()
        runtime.resetForTesting { h.environment() }
        val ran = AtomicInteger()
        runtime.enqueueOperation { throw IllegalStateException("boom") }
        runtime.enqueueOperation { ran.incrementAndGet() }
        runtime.waitForPendingCalls()

        assertEquals(1, ran.get())
        assertEquals(
            listOf("A LoopAnalytics call failed on an unexpected java.lang.IllegalStateException"),
            log.messages(Log.Level.ERROR),
        )
        runtime.resetForTesting(null)
        runtime.waitForPendingCalls()
    }

    @Test
    fun a_failed_engine_start_is_retried_by_the_next_call_and_warned_about_once() = blockingTest {
        val log = recordLog()
        val h = harness(startEngine = false)
        Loop.resetForTesting()
        val attempts = AtomicInteger()
        LoopAnalytics.resetForTesting {
            if (attempts.incrementAndGet() <= 2) throw IllegalStateException("disk full") else h.environment()
        }
        configure()

        LoopAnalytics.track("A") // the start fails; A is dropped
        AnalyticsRuntime.shared.waitForPendingCalls()
        assertNull(LoopAnalytics.deviceId)
        LoopAnalytics.track("B") // tries again and fails again; B is dropped
        AnalyticsRuntime.shared.waitForPendingCalls()
        LoopAnalytics.track("C") // tries again and starts
        LoopAnalytics.flush()

        assertEquals(3, attempts.get())
        assertEquals(listOf("C"), h.transport.sentNames)
        assertEquals("DEVICE-1R", LoopAnalytics.deviceId)
        assertEquals(
            listOf("LoopAnalytics could not start (java.lang.IllegalStateException); the next call tries again"),
            log.messages(Log.Level.WARNING),
        )
        assertEquals(emptyList<String>(), log.messages(Log.Level.ERROR))
    }

    /** Calls [name] on `LoopAnalytics` as Java would: no Kotlin null checks at the call site. */
    private fun callFromJava(name: String, parameterTypes: Array<Class<*>>, vararg args: Any?) {
        try {
            LoopAnalytics::class.java.getMethod(name, *parameterTypes).invoke(null, *args)
        } catch (e: java.lang.reflect.InvocationTargetException) {
            throw AssertionError("LoopAnalytics.$name threw ${e.cause}", e.cause)
        }
    }

    @Test
    fun null_arguments_from_java_are_logged_and_dropped_never_thrown() = blockingTest {
        val log = recordLog()
        val h = facadeHarness()
        configure()
        val string = String::class.java
        val map = Map::class.java
        callFromJava("start", arrayOf(LoopAnalyticsOptions::class.java), null)
        callFromJava("track", arrayOf(string), null)
        callFromJava("track", arrayOf(string, map), null, mapOf("Index" to 1))
        callFromJava("setUserProperties", arrayOf(map), null)
        callFromJava("setUserId", arrayOf(string), null)
        callFromJava("setPurchaserId", arrayOf(string), null)
        LoopAnalytics.track("A")
        LoopAnalytics.flush()

        assertEquals(listOf("A"), h.transport.sentNames)
        val event = h.transport.sentEvents.single()
        assertEquals(JsonValue.Null, event["userId"])
        assertEquals(obj(), event["userProps"])
        assertEquals(
            listOf(
                "LoopAnalytics.start ignored: options is null",
                "LoopAnalytics.track ignored: the event name is null",
                "LoopAnalytics.track ignored: the event name is null",
                "LoopAnalytics.setUserProperties ignored: properties is null",
            ),
            log.messages(Log.Level.ERROR),
        )
    }

    @Test
    fun a_map_that_contains_itself_is_logged_and_dropped_never_thrown() = blockingTest {
        val log = recordLog()
        val h = facadeHarness()
        configure()
        val looped = HashMap<String, Any?>()
        looped["Self"] = looped
        LoopAnalytics.track("Looped", looped)
        LoopAnalytics.setUserProperties(looped)
        LoopAnalytics.track("A")
        LoopAnalytics.flush()

        assertEquals(listOf("A"), h.transport.sentNames)
        assertEquals(obj(), h.transport.sentEvents.single()["userProps"])
        assertEquals(
            List(2) { "Dropped a LoopAnalytics call: its properties could not be read (java.lang.StackOverflowError)" },
            log.messages(Log.Level.ERROR),
        )
    }

    @Test
    fun an_empty_api_key_is_logged_as_an_error() = blockingTest {
        val log = recordLog()
        facadeHarness()
        configure(apiKey = "  ")
        LoopAnalytics.track("A")
        AnalyticsRuntime.shared.waitForPendingCalls()

        assertEquals(1, log.messages(Log.Level.ERROR).count { it.contains("API key is empty") })
    }

    // Engine: restart and dispose

    @Test
    fun restart_during_inflight_upload_resends_identical_batch() = blockingTest {
        val h = harness() // fake env over a temp dir
        h.transport.hold() // next request never completes
        h.engine.track("E1", null)
        launch { h.engine.flush() }
        h.transport.waitForRequests(1)
        h.engine.dispose() // app killed: request outcome unknown
        val h2 = h.restarted() // same storage, new engine, startup flush
        harnesses.add(h2)
        h2.transport.waitForRequests(1)
        h2.engine.waitUntilIdle()

        assertEquals(h.transport.requests[0].events, h2.transport.requests[0].events)
        assertEquals(0, h2.engine.queueLength())
    }

    @Test
    fun dispose_waits_for_the_request_in_flight_and_starts_no_upload() = blockingTest {
        val h = harness(LoopAnalyticsOptions(flushQueueSize = 100, maxBatchSize = 1))
        h.engine.track("A", null)
        h.engine.track("B", null)
        h.transport.hold(300)
        val flush = launch { h.engine.flush() }
        h.transport.waitForRequests(1)

        val started = System.nanoTime()
        h.engine.dispose()
        val waitedMillis = (System.nanoTime() - started) / 1_000_000

        assertTrue("dispose waits for the request in flight (waited $waitedMillis ms)", waitedMillis > 100)
        flush.join()
        assertEquals("the next batch is not sent after dispose", listOf("A"), h.transport.sentNames)
        assertEquals("A was acknowledged; B stays queued", 1, h.engine.queueLength())
    }

    @Test
    fun dispose_wait_is_bounded_by_the_request_timeout() = blockingTest {
        val h = harness(requestTimeoutMillis = 300)
        h.engine.track("A", null)
        h.transport.hold() // never answered
        launch { h.engine.flush() }
        h.transport.waitForRequests(1)

        val started = System.nanoTime()
        h.engine.dispose()
        val waitedMillis = (System.nanoTime() - started) / 1_000_000

        assertTrue("waited $waitedMillis ms", waitedMillis > 100)
        assertTrue("bounded by the request timeout (waited $waitedMillis ms)", waitedMillis < 2_000)
        assertEquals(1, h.engine.queueLength())
    }

    @Test
    fun dispose_cancels_the_timer_and_ignores_lifecycle_changes() = blockingTest {
        val h = harness(LoopAnalyticsOptions(flushQueueSize = 100))
        h.engine.track("A", null)
        assertEquals(1, h.scheduler.activeTimers)

        h.engine.dispose()
        assertEquals(0, h.scheduler.activeTimers)
        h.lifecycle.emit(false)
        h.engine.waitUntilIdle()

        assertEquals(0, h.transport.requests.size)
        assertEquals("queued events stay on disk", 1, h.engine.queueLength())
    }

    @Test
    fun calls_after_dispose_are_ignored() = blockingTest {
        val h = harness()
        h.engine.dispose()
        h.engine.track("Late", null)
        h.engine.setUserId("1")
        h.engine.setOptOut(false)
        h.engine.flush()
        h.engine.reset()
        h.engine.waitUntilIdle()

        assertEquals(0, h.transport.requests.size)
        assertEquals(0, h.engine.queueLength())
        assertEquals("DEVICE-1R", h.engine.deviceId())
    }

    @Test
    fun queued_events_survive_a_restart_and_upload_at_startup() = blockingTest {
        val h = harness()
        h.transport.respond(503)
        h.engine.track("Before Crash", null)
        h.engine.flush()
        assertEquals(1, h.transport.requests.size)

        val h2 = restart(h)
        h2.engine.waitUntilIdle()

        assertEquals(listOf("Before Crash"), h2.transport.sentNames)
        assertEquals(h.engine.deviceId(), h2.engine.deviceId())
    }

    @Test
    fun the_startup_batch_is_exactly_the_events_on_disk_even_if_the_app_tracks_at_once() = blockingTest(60_000) {
        // The startup batch must not depend on whether the app's first
        // track() beats the startup upload: a batch resent after a kill has
        // to be the same event set, or server-side dedup misses it. Repeated
        // because a race would lose only some of the runs.
        for (run in 0 until 25) {
            val h = harness(LoopAnalyticsOptions(flushQueueSize = 100))
            h.engine.track("Old 1", null)
            h.engine.track("Old 2", null)

            val h2 = restart(h)
            h2.engine.track("New", null)
            h2.engine.waitUntilIdle()

            val batches = h2.transport.requests.map { it.names }
            assertEquals("run $run: $batches", listOf("Old 1", "Old 2"), batches.firstOrNull())
        }
    }

    @Test
    fun the_initial_lifecycle_state_is_not_an_event() = blockingTest {
        val h = harness()
        h.engine.waitUntilIdle()
        assertEquals("starting in the foreground uploads nothing", 0, h.transport.requests.size)
        assertEquals(EngineHarness.CLOCK_START, h.engine.sessionId())
    }

    @Test
    fun starting_in_the_foreground_keeps_the_session_alive_without_events() = blockingTest {
        val h = harness(LoopAnalyticsOptions(minTimeBetweenSessionsMillis = 300_000))
        h.engine.track("A", null)
        h.clock.now += 600_000 // reading one screen for 10 minutes
        h.engine.track("B", null)

        assertEquals(EngineHarness.CLOCK_START, h.engine.sessionId())
    }

    @Test
    fun starting_in_the_background_is_not_activity_for_the_session() = blockingTest {
        val h = harness(LoopAnalyticsOptions(minTimeBetweenSessionsMillis = 300_000))
        h.engine.track("A", null)
        h.lifecycle.emit(false)
        h.engine.waitUntilIdle()
        h.clock.now += 240_000
        h.engine.dispose()

        // Relaunched in the background (e.g. by a broadcast) 4 minutes later.
        val h2 = h.restarted(startsInForeground = false)
        harnesses.add(h2)
        h2.engine.waitUntilIdle()
        h.clock.now += 120_000
        h2.engine.track("B", null)

        assertEquals("6 minutes without activity: a new session", h.clock.now, h2.engine.sessionId())
    }

    // Engine: wire shape

    @Test
    fun sends_exactly_the_wire_contract_body_gzip_encoded() = blockingTest {
        val h = harness()
        h.engine.setUserId("12345")
        h.engine.setUserProperties(mapOf("Plan" to str("annual"), "Total Diary Entries" to int(412)))
        h.engine.setPurchaserId("\$RCAnonymousID:b47e")
        h.engine.track(
            "Purchase Completed",
            mapOf(
                "Plan" to str("annual"),
                "Restored" to JsonValue.Bool(false),
                "foods" to JsonValue.Arr(listOf(str("apple"))),
                "coupon" to JsonValue.Null,
            ),
        )
        h.clock.now += 4718
        h.engine.flush()

        assertEquals(1, h.transport.requests.size)
        val sent = h.transport.requests.first()
        assertEquals("https://loop.test/api/ingest/analytics/batch", sent.url)
        assertEquals("Bearer loop_pk_test", sent.headers["Authorization"])
        assertEquals("gzip", sent.headers["Content-Encoding"])
        assertEquals("application/json", sent.headers["Content-Type"])

        val expected: JsonObject = mapOf(
            "sentAt" to str("2026-01-01T00:00:04.718Z"),
            "context" to obj(
                "platform" to str("iOS"),
                "osName" to str("ios"),
                "osVersion" to str("18.0"),
                "appVersion" to str("1.0.0"),
                "appBuild" to str("1"),
                "deviceModel" to str("iPhone15,3"),
                "deviceManufacturer" to str("Apple"),
                "isTablet" to JsonValue.Bool(false),
                "locale" to str("en-GB"),
                "purchaserId" to str("\$RCAnonymousID:b47e"),
                "sdk" to obj("name" to str("loop-android"), "version" to str("2.0.0")),
            ),
            "events" to JsonValue.Arr(
                listOf(
                    obj(
                        "id" to str("00000000-0000-4000-8000-000000000001"),
                        "name" to str("Purchase Completed"),
                        "occurredAt" to str("2026-01-01T00:00:00.000Z"),
                        "sessionId" to int(EngineHarness.CLOCK_START),
                        "deviceId" to str("DEVICE-1R"),
                        "userId" to str("12345"),
                        "props" to obj(
                            "Plan" to str("annual"),
                            "Restored" to JsonValue.Bool(false),
                            "foods" to JsonValue.Arr(listOf(str("apple"))),
                        ),
                        "userProps" to obj("Plan" to str("annual"), "Total Diary Entries" to int(412)),
                    ),
                ),
            ),
        )
        assertEquals(expected, sent.body)
    }

    @Test
    fun anonymous_events_carry_a_null_user_id_and_empty_maps() = blockingTest {
        val h = harness()
        h.engine.track("App Opened", null)
        h.engine.flush()

        val sent = h.transport.requests.first()
        val event = sent.events.first()
        assertEquals(JsonValue.Null, event["userId"])
        assertEquals(obj(), event["props"])
        assertEquals(obj(), event["userProps"])
        assertEquals(JsonValue.Null, sent.context["purchaserId"])
    }

    @Test
    fun empty_user_and_purchaser_ids_mean_none() = blockingTest {
        val h = harness()
        h.engine.setUserId("")
        h.engine.setPurchaserId("")
        h.engine.track("A", null)
        h.engine.flush()

        val sent = h.transport.requests.first()
        assertEquals(JsonValue.Null, sent.events.first()["userId"])
        assertEquals(JsonValue.Null, sent.context["purchaserId"])
    }

    @Test
    fun invalid_names_and_oversized_events_are_dropped() = blockingTest {
        val log = recordLog()
        val h = harness()
        val longest = "n".repeat(128)
        h.engine.track("", null)
        h.engine.track("   ", null)
        h.engine.track("x".repeat(129), null)
        h.engine.track("Odd", mapOf("n" to JsonValue.Num(Double.NaN), "inner" to obj("gone" to JsonValue.Null)))
        h.engine.track("Huge", mapOf("blob" to str("x".repeat(40_000))))
        h.engine.track(longest, null)
        h.engine.flush()

        assertEquals(listOf("Odd", longest), h.transport.sentNames)
        assertEquals(obj("n" to str("nan"), "inner" to obj()), h.transport.sentEvents.first()["props"])
        val warnings = log.messages(Log.Level.WARNING)
        assertEquals(warnings.toString(), 4, warnings.count { it.contains("Dropped event") })
        assertTrue(warnings.toString(), warnings.any { it.contains("\"Huge\"") && it.contains("32768") })
    }

    @Test
    fun an_invalid_event_name_is_not_logged_only_its_length() = blockingTest {
        val log = recordLog()
        val h = harness()
        // An app could pass anything here, even user data; it is logged, so only its length is.
        val name = "  " + "secret ".repeat(19) + "  " // 132 once trimmed
        h.engine.track(name, null)
        h.engine.track("  ", null)
        h.engine.setOptOut(true)
        h.engine.track(name, null) // opted out: still only the length

        val messages = log.messages(Log.Level.WARNING) + log.messages(Log.Level.DEBUG) + log.messages(Log.Level.ERROR)
        assertFalse(messages.toString(), messages.any { it.contains("secret") })
        assertEquals(
            listOf(
                "Dropped event: its name is 132 characters once trimmed; names must be 1–128",
                "Dropped event: its name is 0 characters once trimmed; names must be 1–128",
                "Dropped event: its name is 132 characters once trimmed; names must be 1–128",
            ),
            log.messages(Log.Level.WARNING).filter { it.startsWith("Dropped event") },
        )
    }

    @Test
    fun event_size_limit_is_32_kb_of_wire_json() = blockingTest {
        val h = harness()
        // Measure the fixed part of an event's wire JSON with a probe.
        h.engine.track("Probe", mapOf("S" to str("x".repeat(1000))))
        h.engine.flush()
        val probe = h.transport.sentEvents.first()
        val overhead = JsonValue.Obj(probe).toJson().toByteArray(Charsets.UTF_8).size - 1000
        val fits = AnalyticsEngine.MAX_EVENT_BYTES - overhead

        h.engine.track("Probe", mapOf("S" to str("x".repeat(fits + 1))))
        h.engine.track("Probe", mapOf("S" to str("x".repeat(fits))))
        h.engine.flush()

        assertEquals(2, h.transport.sentEvents.size)
        val props = (h.transport.sentEvents.last()["props"] as JsonValue.Obj).values
        assertEquals("the largest event that fits is sent untruncated", fits, (props["S"] as JsonValue.Str).value.length)
    }

    @Test
    fun a_transport_error_is_contained_and_events_stay_queued() = blockingTest {
        val h = harness()
        h.transport.failNext()
        h.engine.track("A", null)
        h.engine.flush()

        assertEquals(1, h.transport.requests.size)
        assertEquals(1, h.engine.queueLength())
    }

    // Engine: identity

    @Test
    fun uses_the_legacy_device_id_on_first_run() = blockingTest {
        val h = harness(LoopAnalyticsOptions(legacyDeviceId = "legacy-device-1"))
        assertEquals("legacy-device-1", h.engine.deviceId())
        h.engine.track("X", null)
        h.engine.flush()
        assertEquals(str("legacy-device-1"), h.transport.sentEvents.first()["deviceId"])
    }

    @Test
    fun each_event_snapshots_the_user_properties_at_that_moment() = blockingTest {
        val h = harness()
        h.engine.setUserProperties(mapOf("Plan" to str("free"), "Streak" to int(3)))
        h.engine.track("A", null)
        h.engine.setUserProperties(
            mapOf("Plan" to str("annual"), "Streak" to JsonValue.Null, "Nested" to obj("x" to JsonValue.Null, "y" to int(1))),
        )
        h.engine.track("B", null)
        h.engine.flush()

        val events = h.transport.sentEvents
        assertEquals(obj("Plan" to str("free"), "Streak" to int(3)), events[0]["userProps"])
        assertEquals(obj("Plan" to str("annual"), "Nested" to obj("y" to int(1))), events[1]["userProps"])
    }

    @Test
    fun reset_gives_a_new_identity_and_session() = blockingTest {
        val h = harness(LoopAnalyticsOptions(legacyDeviceId = "legacy-device"))
        h.engine.setUserId("12345")
        h.engine.setUserProperties(mapOf("Plan" to str("annual")))
        h.engine.setPurchaserId("rc-1")
        h.engine.track("Before", null)
        val oldSession = h.engine.sessionId()
        h.clock.now += 1000

        h.engine.reset()

        assertEquals("a new random id, never the legacy one", "DEVICE-1R", h.engine.deviceId())
        assertNull(h.engine.userId())
        assertEquals(h.clock.now, h.engine.sessionId())
        assertNotEquals(oldSession, h.engine.sessionId())

        h.engine.track("After", null)
        h.engine.flush()
        val events = h.transport.sentEvents
        assertEquals(str("legacy-device"), events[0]["deviceId"])
        assertEquals(str("12345"), events[0]["userId"])
        assertEquals(str("DEVICE-1R"), events[1]["deviceId"])
        assertEquals(JsonValue.Null, events[1]["userId"])
        assertEquals(obj(), events[1]["userProps"])
        assertEquals(int(h.clock.now), events[1]["sessionId"])
        assertEquals(JsonValue.Null, h.transport.requests.last().context["purchaserId"])
    }

    @Test
    fun opt_out_drops_new_events_and_pauses_uploads_but_keeps_the_queue() = blockingTest {
        val h = harness()
        h.engine.track("Queued Before", null)
        h.engine.setOptOut(true)
        assertTrue(h.engine.isOptedOut())
        h.engine.track("Ignored", null)
        h.engine.flush()
        assertEquals(0, h.transport.requests.size)

        val h2 = restart(h)
        assertEquals("queued events stay on disk", 1, h.queueFileLines().size)
        assertTrue("opt-out is persisted", h2.engine.isOptedOut())
        h2.engine.track("Still Ignored", null)
        h2.engine.flush()
        h2.engine.waitUntilIdle()
        assertEquals(0, h2.transport.requests.size)

        h2.engine.setOptOut(false)
        h2.engine.waitUntilIdle()
        assertEquals("opting back in uploads at once", listOf("Queued Before"), h2.transport.sentNames)
        h2.engine.track("After", null)
        h2.engine.flush()
        assertEquals(listOf("Queued Before", "After"), h2.transport.sentNames)
    }

    // Engine: when uploads happen

    @Test
    fun uploads_once_flush_queue_size_events_are_queued() = blockingTest {
        val h = harness(LoopAnalyticsOptions(flushQueueSize = 3))
        h.engine.track("A", null)
        h.engine.track("B", null)
        h.engine.waitUntilIdle()
        assertEquals(0, h.transport.requests.size)

        h.engine.track("C", null)
        h.engine.waitUntilIdle()

        assertEquals(1, h.transport.requests.size)
        assertEquals(listOf("A", "B", "C"), h.transport.sentNames)
    }

    @Test
    fun uploads_every_flush_interval_and_the_timer_retries_failures() = blockingTest {
        val h = harness(LoopAnalyticsOptions(flushIntervalMillis = 30_000))
        h.engine.track("A", null)
        h.advance(29_000)
        assertEquals(0, h.transport.requests.size)
        h.advance(1_000)
        assertEquals(1, h.transport.requests.size)

        h.transport.respond(503)
        h.engine.track("B", null)
        h.advance(30_000)
        assertEquals(2, h.transport.requests.size)
        h.advance(30_000)
        assertEquals(3, h.transport.requests.size)
        assertEquals("B", h.transport.sentNames.last())
    }

    @Test
    fun the_flush_timer_pauses_in_the_background_and_resumes_in_the_foreground() = blockingTest {
        val h = harness(LoopAnalyticsOptions(flushQueueSize = 100, flushIntervalMillis = 30_000))
        h.engine.track("A", null)
        h.lifecycle.emit(false)
        h.engine.waitUntilIdle()
        assertEquals("the background flush still runs", listOf("A"), h.transport.sentNames)
        assertEquals("no timer while in the background", 0, h.scheduler.activeTimers)

        h.engine.track("B", null)
        h.advance(120_000)
        assertEquals("no ticks in the background", listOf("A"), h.transport.sentNames)

        h.lifecycle.emit(true)
        h.engine.waitUntilIdle()
        assertEquals(1, h.scheduler.activeTimers)
        assertEquals("the foreground flush sends what was queued", listOf("A", "B"), h.transport.sentNames)
        h.engine.track("C", null)
        h.advance(30_000)
        assertEquals("ticks resume in the foreground", listOf("A", "B", "C"), h.transport.sentNames)

        h.lifecycle.emit(true) // already in the foreground: no second timer
        h.engine.waitUntilIdle()
        assertEquals(1, h.scheduler.activeTimers)
    }

    @Test
    fun a_process_started_in_the_background_runs_no_flush_timer_until_the_foreground() = blockingTest {
        val h = harness(LoopAnalyticsOptions(flushQueueSize = 100))
        h.engine.dispose()
        val h2 = h.restarted(startsInForeground = false)
        harnesses.add(h2)
        h2.engine.waitUntilIdle()
        assertEquals(0, h2.scheduler.activeTimers)

        h2.engine.track("A", null)
        h2.advance(60_000)
        assertEquals(0, h2.transport.requests.size)

        h2.lifecycle.emit(true)
        h2.engine.waitUntilIdle()
        assertEquals(1, h2.scheduler.activeTimers)
    }

    @Test
    fun without_any_lifecycle_state_the_flush_timer_keeps_running() = blockingTest {
        // A lifecycle that never reports (e.g. the process lifecycle was never initialised).
        val h = harness(startEngine = false)
        val engine = AnalyticsEngine.create(
            EngineHarness.API_KEY,
            EngineHarness.SERVER_URL,
            LoopAnalyticsOptions(flushQueueSize = 100),
            h.environment().copy(lifecycle = LifecycleSource { }),
        )
        try {
            engine.track("A", null)
            h.scheduler.advance(30_000) { engine.waitUntilIdle() }
            assertEquals(listOf("A"), h.transport.sentNames)
        } finally {
            engine.dispose()
        }
    }

    @Test
    fun going_to_the_background_flushes() = blockingTest {
        val h = harness()
        h.engine.track("A", null)

        h.lifecycle.emit(false)
        h.engine.waitUntilIdle()

        assertEquals(listOf("A"), h.transport.sentNames)
    }

    @Test
    fun coming_back_to_the_foreground_uploads_queued_events() = blockingTest {
        val h = harness()
        h.lifecycle.emit(false)
        h.engine.waitUntilIdle()
        h.engine.track("While Away", null)
        h.engine.waitUntilIdle()
        assertEquals(0, h.transport.requests.size)

        h.lifecycle.emit(true)
        h.engine.waitUntilIdle()

        assertEquals(listOf("While Away"), h.transport.sentNames)
    }

    @Test
    fun sessions_roll_over_after_idle_time_in_the_background() = blockingTest {
        val h = harness(LoopAnalyticsOptions(minTimeBetweenSessionsMillis = 300_000))
        h.engine.track("A", null)
        val first = h.engine.sessionId()

        h.lifecycle.emit(false)
        h.engine.waitUntilIdle()
        h.clock.now += 120_000
        h.lifecycle.emit(true)
        h.engine.waitUntilIdle()
        h.engine.track("B", null)
        assertEquals(first, h.engine.sessionId())

        h.lifecycle.emit(false)
        h.engine.waitUntilIdle()
        h.clock.now += 360_000
        h.lifecycle.emit(true)
        h.engine.waitUntilIdle()
        h.engine.track("C", null)
        val third = h.engine.sessionId()
        assertEquals(h.clock.now, third)

        h.engine.flush()
        val ids = h.transport.sentEvents.map { it["sessionId"] }
        assertEquals(listOf(first, first, third).map { int(it!!) }, ids)
    }

    // Engine: context

    @Test
    fun events_keep_the_purchaser_id_and_locale_they_were_tracked_with() = blockingTest {
        val h = harness()
        h.engine.track("Anonymous", null)
        h.engine.setPurchaserId("\$RCAnonymousID:1")
        h.engine.track("Purchased", null)
        h.engine.track("Purchased Again", null)
        h.context.value = h.context.value.copy(locale = "fr-FR")
        h.engine.track("Bonjour", null)
        h.engine.flush()

        val requests = h.transport.requests
        assertEquals(listOf(1, 2, 1), requests.map { it.events.size })
        val contexts = requests.map { it.context }
        assertEquals(JsonValue.Null, contexts[0]["purchaserId"])
        assertEquals(str("\$RCAnonymousID:1"), contexts[1]["purchaserId"])
        assertEquals(str("en-GB"), contexts[1]["locale"])
        assertEquals(str("fr-FR"), contexts[2]["locale"])
    }

    @Test
    fun events_queued_before_an_app_update_keep_the_old_app_version() = blockingTest {
        val h = harness()
        h.transport.respond(503)
        h.engine.track("Old Version", null)
        h.engine.flush()

        val updated = ContextBox()
        updated.value = updated.value.copy(appVersion = "1.1.0")
        val h2 = restart(h, context = updated)
        h2.engine.waitUntilIdle()
        h2.engine.track("New Version", null)
        h2.engine.flush()

        val requests = h2.transport.requests
        assertEquals(listOf(1, 1), requests.map { it.events.size })
        assertEquals(str("1.0.0"), requests[0].context["appVersion"])
        assertEquals(str("Old Version"), requests[0].events.first()["name"])
        assertEquals(str("1.1.0"), requests[1].context["appVersion"])
        assertEquals(str("New Version"), requests[1].events.first()["name"])
    }

    // Environment

    @Test
    fun production_ids_and_sdk_identity() {
        assertEquals("loop-android" to "2.0.0", AnalyticsEnvironment.SDK)
        val id = AnalyticsEnvironment.newEventId()
        val uuid = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
        assertTrue(id, uuid.matches(id))
        assertNotEquals(id, AnalyticsEnvironment.newEventId())
    }

    @Test
    fun timer_scheduler_ticks_until_cancelled() = blockingTest {
        val ticks = AtomicInteger()
        val timer = TimerScheduler().every(20) { ticks.incrementAndGet() }
        val deadline = System.nanoTime() + 2_000_000_000L
        while (ticks.get() < 2) {
            if (System.nanoTime() > deadline) fail("the timer did not tick twice")
            delay(5)
        }
        timer.cancel()
        // A tick already running when cancel() returns may still finish.
        delay(50)
        val settled = ticks.get()
        delay(100)
        assertEquals("no ticks after cancel", settled, ticks.get())
    }

    @Test
    fun timer_scheduler_ignores_a_non_positive_interval() = blockingTest {
        val ticks = AtomicInteger()
        val zero = TimerScheduler().every(0) { ticks.incrementAndGet() }
        val negative = TimerScheduler().every(-5) { ticks.incrementAndGet() }
        delay(50)
        zero.cancel()
        negative.cancel()
        assertEquals(0, ticks.get())
    }

    @Test
    fun the_engine_publishes_its_identity_for_synchronous_readers() = blockingTest {
        val h = harness()
        assertEquals("DEVICE-1R", h.engine.published.deviceId)
        h.engine.waitUntilIdle()
        assertEquals(EngineHarness.CLOCK_START, h.engine.published.sessionId)
        h.clock.now += 1000
        h.engine.reset()
        assertEquals("DEVICE-2R", h.engine.published.deviceId)
        assertEquals(h.clock.now, h.engine.published.sessionId)
    }

    @Test
    fun a_hung_upload_does_not_hold_up_track() = blockingTest {
        val h = harness(LoopAnalyticsOptions(flushQueueSize = 1), requestTimeoutMillis = 2_000)
        h.transport.hold()
        h.engine.track("A", null) // starts an upload that hangs
        h.transport.waitForRequests(1)

        val started = System.nanoTime()
        h.engine.track("B", null)
        val tookMillis = (System.nanoTime() - started) / 1_000_000

        assertTrue("track waited $tookMillis ms for the hung upload", tookMillis < 1_000)
        assertEquals(2, h.engine.queueLength())
        h.engine.waitUntilIdle()
    }
}
