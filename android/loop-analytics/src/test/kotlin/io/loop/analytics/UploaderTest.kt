@file:OptIn(ExperimentalCoroutinesApi::class) // runCurrent

package io.loop.analytics

import io.loop.core.Gzip
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.BufferedInputStream
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.file.Files
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

/** A request as the server would see it: the gzip-decoded JSON body. */
private class Sent(val url: String, val headers: Map<String, String>, rawBody: ByteArray) {
    val body: JsonObject = JsonValue.parseObject(String(Gzip.decompress(rawBody), Charsets.UTF_8))

    val events: List<JsonObject>
        get() = (body["events"] as? JsonValue.Arr)?.values.orEmpty().mapNotNull { (it as? JsonValue.Obj)?.values }

    val ids: List<String>
        get() = events.mapNotNull { (it["id"] as? JsonValue.Str)?.value }
}

private fun reply(status: Int, body: String = "{}", headers: Map<String, String> = emptyMap()) =
    TransportResponse(status, headers, body.toByteArray(Charsets.UTF_8))

/**
 * Records every request and answers with `respond(sent, index)`, where
 * `index` is the number of earlier requests. While [gate] is set, each request
 * waits for it before answering; [started] completes when the first arrives.
 */
private class FakeTransport : AnalyticsTransport {
    private val lock = Any()
    private val requests = ArrayList<Sent>()
    private var inFlight = 0
    private var maxSeen = 0

    @Volatile var respond: suspend (Sent, Int) -> TransportResponse = { _, _ ->
        reply(202, """{"accepted":1,"dropped":0}""")
    }

    @Volatile var gate: CompletableDeferred<Unit>? = null
    val started = CompletableDeferred<Unit>()

    val sent: List<Sent> get() = synchronized(lock) { requests.toList() }
    val maxInFlight: Int get() = synchronized(lock) { maxSeen }

    override suspend fun send(url: String, headers: Map<String, String>, body: ByteArray): TransportResponse {
        val s = Sent(url, headers, body)
        val index = synchronized(lock) {
            requests.add(s)
            inFlight += 1
            maxSeen = maxOf(maxSeen, inFlight)
            requests.size - 1
        }
        try {
            started.complete(Unit)
            gate?.await()
            return respond(s, index)
        } finally {
            synchronized(lock) { inFlight -= 1 }
        }
    }
}

/** A transport whose requests never return and ignore cancellation. */
private class HangingTransport : AnalyticsTransport {
    private val never = CompletableDeferred<TransportResponse>()
    private val count = AtomicInteger()
    val calls: Int get() = count.get()

    override suspend fun send(url: String, headers: Map<String, String>, body: ByteArray): TransportResponse {
        count.incrementAndGet()
        return withContext(NonCancellable) { never.await() }
    }

    /** Lets the hung requests finish so the test leaves nothing suspended. */
    fun release() {
        never.complete(reply(202))
    }
}

class UploaderTest {
    private val start = 1_791_968_400_000L // 2026-10-14T09:00:00.000Z
    private val second = 1000L
    private val minute = 60_000L
    private val hour = 3_600_000L
    private val currentContext: JsonObject = mapOf("platform" to JsonValue.Str("Android"))

    private var clock = FakeClock(start)
    private var transport = FakeTransport()
    private var store = EventStore(null, 1000)

    @Volatile private var enabled = true
    private var dir: File? = null

    @Before
    fun setUp() {
        clock = FakeClock(start)
        transport = FakeTransport()
        store = EventStore(null, 1000)
        enabled = true
    }

    @After
    fun tearDown() {
        dir?.deleteRecursively()
    }

    private fun uploader(
        maxBatchSize: Int = 100,
        maxBodyBytes: Int = 900_000,
        serverUrl: String = "https://loop.test",
    ): Uploader {
        val context = currentContext
        return Uploader(
            store = store,
            transport = transport,
            serverUrl = serverUrl,
            apiKey = "loop_pk_test",
            context = { context },
            maxBatchSize = maxBatchSize,
            clock = clock,
            isEnabled = { enabled },
            maxBodyBytes = maxBodyBytes,
        )
    }

    private fun addEvents(n: Int, prefix: String = "e") {
        for (i in 0 until n) store.add(sampleEvent(id = "$prefix$i"))
    }

    private fun respond(respond: suspend (Sent, Int) -> TransportResponse) {
        transport.respond = respond
    }

    private fun respond(status: Int, body: String = "{}", headers: Map<String, String> = emptyMap()) {
        transport.respond = { _, _ -> reply(status, body, headers) }
    }

    private fun sent() = transport.sent

    private fun fileBackedStore(maxQueueSize: Int = 1000): File {
        val dir = Files.createTempDirectory("loop_uploader_test_").toFile()
        this.dir = dir
        val file = File(dir, "events.jsonl")
        store = EventStore(file, maxQueueSize)
        return file
    }

    private fun wireLength(event: LoopEvent) =
        JsonValue.Obj(event.wireJson()).toJson().toByteArray(Charsets.UTF_8).size

    // Basics

    @Test
    fun posts_a_gzip_JSON_batch_with_auth_headers_and_removes_it_on_202() = runTest {
        val file = fileBackedStore()
        addEvents(2)
        uploader().flush()

        val sent = sent()
        assertEquals(1, sent.size)
        assertEquals("https://loop.test/api/ingest/analytics/batch", sent[0].url)
        assertEquals("Bearer loop_pk_test", sent[0].headers["Authorization"])
        assertTrue(sent[0].headers["Content-Type"]!!.startsWith("application/json"))
        assertEquals("gzip", sent[0].headers["Content-Encoding"])
        assertEquals(JsonValue.Str("2026-10-14T09:00:00.000Z"), sent[0].body["sentAt"])
        assertEquals(JsonValue.Obj(currentContext), sent[0].body["context"])
        assertEquals(listOf("e0", "e1"), sent[0].ids)
        assertEquals(sampleEvent(id = "e0").wireJson(), sent[0].events[0])
        assertEquals(0, store.count)
        assertEquals(0, file.readBytes().size)
    }

    @Test
    fun the_body_keys_are_sentAt_context_events_in_order() = runTest {
        addEvents(1)
        uploader().flush()
        assertEquals(listOf("sentAt", "context", "events"), sent()[0].body.keys.toList())
    }

    @Test
    fun sentAt_comes_from_the_injected_clock() = runTest {
        addEvents(1)
        clock.now = start + 1234
        uploader().flush()
        assertEquals(JsonValue.Str("2026-10-14T09:00:01.234Z"), sent().first().body["sentAt"])
    }

    @Test
    fun nothing_queued_means_no_request() = runTest {
        uploader().flush()
        assertTrue(sent().isEmpty())
    }

    @Test
    fun events_are_on_disk_before_they_are_sent() = runTest {
        val file = fileBackedStore()
        addEvents(1)
        respond { _, _ ->
            val contents = if (file.exists()) file.readText(Charsets.UTF_8) else ""
            if (contents.contains("\"e0\"")) reply(202) else reply(500)
        }
        uploader().flush()
        assertEquals(1, sent().size)
        assertEquals("the event was on disk when the request went out", 0, store.count)
    }

    @Test
    fun splits_the_queue_into_batches_of_maxBatchSize_oldest_first() = runTest {
        addEvents(250)
        uploader().flush()
        val sent = sent()
        assertEquals(listOf(100, 100, 50), sent.map { it.events.size })
        assertEquals("e0", sent.first().ids.first())
        assertEquals("e249", sent.last().ids.last())
        assertEquals(0, store.count)
    }

    @Test
    fun also_splits_by_encoded_size_to_stay_under_the_body_limit() = runTest {
        for (i in 0 until 10) {
            store.add(sampleEvent(id = "big$i", props = mapOf("blob" to JsonValue.Str("x".repeat(1000)))))
        }
        uploader(maxBodyBytes = 3500).flush()
        val sent = sent()
        assertTrue(sent.map { it.events.size }.toString(), sent.all { it.events.size <= 3 })
        assertEquals(10, sent.flatMap { it.ids }.size)
    }

    @Test
    fun the_body_limit_counts_each_events_wire_length_plus_one() = runTest {
        addEvents(3)
        val length = wireLength(sampleEvent(id = "e0"))
        // Two events take exactly 2 × (length + 1) bytes: they fit, a third does not.
        uploader(maxBodyBytes = 2 * (length + 1)).flush()
        assertEquals(listOf(listOf("e0", "e1"), listOf("e2")), sent().map { it.ids })

        transport = FakeTransport()
        store = EventStore(null, 1000)
        addEvents(3)
        // One byte less and only one event fits per batch.
        uploader(maxBodyBytes = 2 * (length + 1) - 1).flush()
        assertEquals(listOf(listOf("e0"), listOf("e1"), listOf("e2")), sent().map { it.ids })
    }

    @Test
    fun a_single_event_over_the_body_limit_is_still_sent_alone() = runTest {
        store.add(sampleEvent(id = "huge", props = mapOf("blob" to JsonValue.Str("x".repeat(5000)))))
        store.add(sampleEvent(id = "small"))
        uploader(maxBodyBytes = 3500).flush()
        assertEquals(listOf(listOf("huge"), listOf("small")), sent().map { it.ids })
    }

    @Test
    fun production_defaults() {
        assertEquals(900 * 1024, Uploader.DEFAULT_MAX_BODY_BYTES)
        assertEquals(30_000L, Uploader.INITIAL_BACKOFF_MILLIS)
        assertEquals(600_000L, Uploader.MAX_BACKOFF_MILLIS)
        assertEquals(3_600_000L, Uploader.AUTH_BACKOFF_MILLIS)
        assertEquals(3_600_000L, Uploader.MAX_RETRY_AFTER_MILLIS)
        assertEquals("api/ingest/analytics/batch", Uploader.ENDPOINT_PATH)
        assertEquals(30_000, HttpUrlConnectionTransport.DEFAULT_TIMEOUT_MILLIS)
        assertEquals(30_000, HttpUrlConnectionTransport().timeoutMillis)
        assertEquals(30_000L, Uploader.DEFAULT_REQUEST_TIMEOUT_MILLIS)
    }

    // 413

    @Test
    fun _413_halves_the_batch_until_it_fits_then_sends_the_rest() = runTest {
        addEvents(100)
        respond { s, _ -> if (s.events.size > 25) reply(413, """{"error":"too large"}""") else reply(202) }
        uploader().flush()
        val sent = sent()
        assertEquals(listOf(100, 50, 25, 25, 25, 25), sent.map { it.events.size })
        assertEquals(sent[0].ids.take(50), sent[1].ids)
        assertEquals(0, store.count)
    }

    @Test
    fun _413_drops_a_single_event_that_is_still_too_large() = runTest {
        addEvents(3)
        respond { s, _ -> if ("e0" in s.ids) reply(413, """{"error":"too large"}""") else reply(202) }
        val log = LogRecorder()
        try {
            uploader().flush()
        } finally {
            log.stop()
        }
        val sent = sent()
        assertEquals(listOf(3, 1, 2), sent.map { it.events.size })
        assertEquals(listOf("e1", "e2"), sent.last().ids)
        assertEquals(0, store.count)
        assertEquals(
            listOf("Dropped an event the server rejected as too large (HTTP 413)"),
            log.messages(Log.Level.WARNING),
        )
    }

    @Test
    fun the_batch_limit_returns_to_maxBatchSize_once_a_413_halved_queue_drains() = runTest {
        addEvents(100)
        val up = uploader()
        respond { s, _ -> if (s.events.size > 25) reply(413, """{"error":"too large"}""") else reply(202) }
        up.flush()
        assertEquals(0, store.count)

        addEvents(150, prefix = "more")
        respond(202)
        up.flush()
        assertEquals(listOf(100, 50), sent().drop(6).map { it.events.size })
        assertEquals(0, store.count)
    }

    // Other 4xx

    @Test
    fun other_4xx_drops_the_batch_and_carries_on() = runTest {
        for (status in listOf(400, 404, 409, 422)) {
            transport = FakeTransport()
            store = EventStore(null, 1000)
            addEvents(150)
            respond { _, index -> if (index == 0) reply(status, """{"error":"bad"}""") else reply(202) }
            val up = uploader()
            up.flush()
            assertEquals("HTTP $status", listOf(100, 50), sent().map { it.events.size })
            assertEquals("HTTP $status", 0, store.count)
            assertNull("HTTP $status", up.nextAttemptAtMillis)
        }
    }

    // 401/403 (bad or missing key)

    @Test
    fun _401_and_403_keep_the_events_and_back_off_for_an_hour() = runTest {
        for (status in listOf(401, 403)) {
            clock = FakeClock(start)
            transport = FakeTransport()
            store = EventStore(null, 1000)
            addEvents(3)
            val up = uploader()
            respond(status, """{"error":"invalid api key"}""")

            up.flush()
            assertEquals("HTTP $status", 1, sent().size)
            assertEquals("HTTP $status", 3, store.count)
            assertEquals("HTTP $status", clock.now + hour, up.nextAttemptAtMillis)
            assertTrue("HTTP $status", up.isBackingOff)

            clock.now += 59 * minute
            up.flush()
            assertEquals("HTTP $status", 1, sent().size)

            clock.now += minute
            up.flush()
            val sent = sent()
            assertEquals("HTTP $status", 2, sent.size)
            assertEquals("identical retry, HTTP $status", sent[0].ids, sent[1].ids)
            assertEquals("no growth, HTTP $status", clock.now + hour, up.nextAttemptAtMillis)

            clock.now += hour
            respond(202)
            up.flush()
            assertEquals("HTTP $status", 0, store.count)
            assertNull("HTTP $status", up.nextAttemptAtMillis)
            assertFalse("HTTP $status", up.isBackingOff)
        }
    }

    @Test
    fun _401_honours_Retry_After() = runTest {
        addEvents(1)
        val up = uploader()
        respond(401, "", headers = mapOf("retry-after" to "300"))
        up.flush()
        assertEquals(clock.now + 5 * minute, up.nextAttemptAtMillis)
    }

    @Test
    fun _401_Retry_After_over_an_hour_is_capped_at_an_hour() = runTest {
        addEvents(1)
        val up = uploader()
        respond(401, "", headers = mapOf("retry-after" to "7200"))
        up.flush()
        assertEquals(clock.now + hour, up.nextAttemptAtMillis)
    }

    @Test
    fun the_queue_cap_still_applies_while_the_key_is_wrong() = runTest {
        store = EventStore(null, 5)
        addEvents(4)
        val up = uploader()
        respond(401, "")
        up.flush()
        addEvents(10, prefix = "more")
        assertTrue(store.count <= 5)
        assertEquals("more9", store.peek(Int.MAX_VALUE).last().id)
    }

    // Per-event context

    private val a: JsonObject = mapOf("platform" to JsonValue.Str("Android"), "appVersion" to JsonValue.Str("5.2.0"))
    private val b: JsonObject = mapOf("platform" to JsonValue.Str("Android"), "appVersion" to JsonValue.Str("5.3.0"))

    @Test
    fun a_batch_only_holds_consecutive_events_with_the_same_context_sent_as_the_batch_context() = runTest {
        store.add(sampleEvent(id = "1", context = a))
        store.add(sampleEvent(id = "2", context = HashMap(a)))
        store.add(sampleEvent(id = "3", context = b))
        store.add(sampleEvent(id = "4", context = b))
        store.add(sampleEvent(id = "5", context = a))
        uploader().flush()
        val sent = sent()
        assertEquals(listOf(listOf("1", "2"), listOf("3", "4"), listOf("5")), sent.map { it.ids })
        assertEquals(
            listOf(JsonValue.Obj(a), JsonValue.Obj(b), JsonValue.Obj(a)),
            sent.map { it.body["context"] },
        )
        assertEquals(0, store.count)
    }

    @Test
    fun events_without_a_snapshot_use_the_current_context() = runTest {
        store.add(sampleEvent(id = "old"))
        store.add(sampleEvent(id = "new", context = a))
        uploader().flush()
        assertEquals(listOf(JsonValue.Obj(currentContext), JsonValue.Obj(a)), sent().map { it.body["context"] })
    }

    @Test
    fun a_retried_context_batch_is_identical() = runTest {
        store.add(sampleEvent(id = "1", context = a))
        store.add(sampleEvent(id = "2", context = b))
        val up = uploader()
        respond(500, "")
        up.flush()
        store.add(sampleEvent(id = "3", context = a))
        clock.now += 30 * second
        respond(202)
        up.flush()
        val sent = sent()
        assertEquals(listOf("1"), sent[1].ids)
        assertEquals(JsonValue.Obj(a), sent[1].body["context"])
        assertEquals(listOf(listOf("2"), listOf("3")), sent.drop(2).map { it.ids })
    }

    // Retryable failures

    @Test
    fun _5xx_keeps_the_events_and_backs_off_30s_doubling_then_resets() = runTest {
        addEvents(3)
        val up = uploader()
        respond(503, "")

        up.flush()
        assertEquals(1, sent().size)
        assertEquals(3, store.count)
        assertEquals(clock.now + 30 * second, up.nextAttemptAtMillis)

        up.flush()
        assertEquals("still backing off", 1, sent().size)

        clock.now += 30 * second
        up.flush()
        assertEquals(2, sent().size)
        assertEquals(clock.now + 60 * second, up.nextAttemptAtMillis)

        clock.now += 59 * second
        up.flush()
        assertEquals(2, sent().size)

        clock.now += second
        respond(202)
        up.flush()
        assertEquals(3, sent().size)
        assertEquals(0, store.count)
        assertNull(up.nextAttemptAtMillis)

        addEvents(1, prefix = "n")
        respond(500, "")
        up.flush()
        assertEquals("backoff resets after a success", clock.now + 30 * second, up.nextAttemptAtMillis)
    }

    @Test
    fun a_retried_batch_is_the_identical_event_set() = runTest {
        addEvents(5)
        val up = uploader(maxBatchSize = 3)
        respond(502, "")
        up.flush()

        // New events arrive and an older one is no longer first in line;
        // the retry must still be exactly the same batch.
        addEvents(4, prefix = "late")
        clock.now += 30 * second
        up.flush()
        var sent = sent()
        assertEquals(sent[0].ids, sent[1].ids)
        assertEquals(listOf("e0", "e1", "e2"), sent[1].ids)
        assertEquals(sent[0].body["events"], sent[1].body["events"])

        respond(202)
        clock.now += 60 * second
        up.flush()
        sent = sent()
        assertEquals(listOf("e0", "e1", "e2"), sent[2].ids)
        assertEquals(listOf("e3", "e4", "late0", "late1", "late2", "late3"), sent.drop(3).flatMap { it.ids })
        assertEquals(0, store.count)
    }

    @Test
    fun a_primed_batch_is_sent_first_and_unchanged() = runTest {
        addEvents(2)
        val up = uploader()
        up.primePendingBatch()
        addEvents(2, prefix = "late")
        up.flush()
        assertEquals(listOf(listOf("e0", "e1"), listOf("late0", "late1")), sent().map { it.ids })
    }

    @Test
    fun priming_does_nothing_while_disabled() = runTest {
        addEvents(2)
        enabled = false
        val up = uploader()
        up.primePendingBatch()
        addEvents(1, prefix = "late")
        enabled = true
        up.flush()
        assertEquals(listOf(listOf("e0", "e1", "late0")), sent().map { it.ids })
    }

    @Test
    fun backoff_is_capped_at_10_minutes() = runTest {
        addEvents(1)
        val up = uploader()
        respond(500, "")
        repeat(8) {
            up.flush()
            clock.now += 10 * minute
        }
        assertEquals(8, sent().size)
        up.flush()
        assertEquals(clock.now + 10 * minute, up.nextAttemptAtMillis)
    }

    @Test
    fun _429_honours_Retry_After_seconds() = runTest {
        addEvents(1)
        val up = uploader()
        respond(429, """{"error":"rate limited"}""", headers = mapOf("retry-after" to "120"))
        up.flush()
        assertEquals(clock.now + 120 * second, up.nextAttemptAtMillis)
        clock.now += 119 * second
        up.flush()
        assertEquals(1, sent().size)
        clock.now += second
        respond(202)
        up.flush()
        assertEquals(2, sent().size)
        assertEquals(0, store.count)
    }

    @Test
    fun Retry_After_as_an_HTTP_date() = runTest {
        addEvents(1)
        val up = uploader()
        // Three minutes after the fake clock's 2026-10-14T09:00:00Z.
        respond(503, "", headers = mapOf("retry-after" to "Wed, 14 Oct 2026 09:03:00 GMT"))
        up.flush()
        assertEquals(clock.now + 3 * minute, up.nextAttemptAtMillis)
    }

    @Test
    fun Retry_After_is_capped_at_an_hour() = runTest {
        addEvents(1)
        val up = uploader()
        respond(429, "", headers = mapOf("retry-after" to "7200"))
        up.flush()
        assertEquals(clock.now + hour, up.nextAttemptAtMillis)

        clock.now += hour
        respond(503, "", headers = mapOf("retry-after" to "Thu, 15 Oct 2026 09:00:00 GMT"))
        up.flush()
        assertEquals("an HTTP date is capped too", clock.now + hour, up.nextAttemptAtMillis)
    }

    @Test
    fun Retry_After_in_the_past_retries_at_once_and_garbage_falls_back_to_backoff() = runTest {
        addEvents(1)
        val up = uploader()
        respond(503, "", headers = mapOf("retry-after" to "Wed, 14 Oct 2026 08:00:00 GMT"))
        up.flush()
        assertEquals(clock.now, up.nextAttemptAtMillis)

        respond(503, "", headers = mapOf("retry-after" to "soon"))
        up.flush()
        assertEquals("second failure: ordinary backoff", clock.now + 60 * second, up.nextAttemptAtMillis)
    }

    @Test
    fun network_errors_keep_the_events_and_back_off() = runTest {
        addEvents(2)
        val up = uploader()
        respond { _, _ -> throw IOException("not connected to the internet") }
        up.flush()
        assertEquals(2, store.count)
        assertEquals(clock.now + 30 * second, up.nextAttemptAtMillis)
    }

    @Test
    fun a_hung_request_times_out_and_is_retried_later() = runTest {
        // The one test on real time: the uploader's own 10 ms request timeout.
        addEvents(1)
        val hanging = HangingTransport()
        val up = Uploader(
            store = store,
            transport = hanging,
            serverUrl = "https://loop.test",
            apiKey = "k",
            context = { mapOf("platform" to JsonValue.Str("Android")) },
            maxBatchSize = 100,
            clock = clock,
            requestTimeoutMillis = 10,
        )
        up.flush()
        assertEquals(1, hanging.calls)
        assertEquals(1, store.count)
        assertNotNull(up.nextAttemptAtMillis)
        assertFalse(up.isUploading)
        hanging.release()
    }

    @Test
    fun a_transport_reported_timeout_is_retried_later() = runTest {
        // HttpUrlConnectionTransport surfaces its 30 s timeouts as SocketTimeoutException.
        addEvents(1)
        val up = uploader()
        respond { _, _ -> throw SocketTimeoutException("Read timed out") }
        up.flush()
        assertEquals(1, store.count)
        assertNotNull(up.nextAttemptAtMillis)
    }

    @Test
    fun a_transport_failure_logs_one_warning_with_the_error_class_and_no_host() = runTest {
        addEvents(1)
        val up = uploader(serverUrl = "https://private-host.loop.test")
        respond { _, _ -> throw java.net.UnknownHostException("private-host.loop.test: nodename nor servname provided") }
        val log = LogRecorder()
        try {
            up.flush()
        } finally {
            log.stop()
        }
        assertEquals(
            listOf("Analytics upload failed (java.net.UnknownHostException); retrying in 30 s"),
            log.messages(Log.Level.WARNING),
        )
        val everything = Log.Level.values().flatMap { log.messages(it) }
        assertTrue(everything.toString(), everything.none { it.contains("loop.test") || it.contains("nodename") })
    }

    @Test
    fun the_retry_warning_reports_the_backed_off_delay() = runTest {
        addEvents(1)
        val up = uploader()
        respond { _, _ -> throw IOException("connection reset") }
        up.flush() // 30 s
        clock.now += 30 * second
        val log = LogRecorder()
        try {
            up.flush() // the second failure doubles the pause
        } finally {
            log.stop()
        }
        assertEquals(
            listOf("Analytics upload failed (java.io.IOException); retrying in 60 s"),
            log.messages(Log.Level.WARNING),
        )
    }

    // Concurrency and opt-out

    @Test
    fun only_one_upload_is_in_flight_at_a_time() = runTest {
        addEvents(250)
        val gate = CompletableDeferred<Unit>()
        transport.gate = gate
        val up = uploader()
        val flushes = List(3) { async { up.flush() } }
        transport.started.await()
        runCurrent() // every flush has started and is waiting
        gate.complete(Unit)
        flushes.awaitAll()

        assertEquals(1, transport.maxInFlight)
        val ids = sent().flatMap { it.ids }
        assertEquals(250, ids.size)
        assertEquals(250, ids.toSet().size)
        assertFalse(up.isUploading)
    }

    @Test
    fun a_flush_joins_the_running_upload() = runTest {
        addEvents(1)
        val gate = CompletableDeferred<Unit>()
        transport.gate = gate
        val up = uploader()
        val first = async { up.flush() }
        // Let the first flush start its request.
        transport.started.await()
        assertTrue(up.isUploading)
        val second = async { up.flush() }
        runCurrent()
        assertTrue("the second flush waits for the running upload", second.isActive)
        gate.complete(Unit)
        second.await()
        assertEquals("the second flush returns only once the upload is done", 0, store.count)
        first.await()
        assertEquals(1, sent().size)
    }

    @Test
    fun waitForInFlight_waits_for_the_running_upload_without_starting_one() = runTest {
        val up = uploader()
        addEvents(1)
        up.waitForInFlight()
        assertTrue("nothing was running, so nothing is sent", sent().isEmpty())

        val gate = CompletableDeferred<Unit>()
        transport.gate = gate
        val first = async { up.flush() }
        transport.started.await()
        val waiter = async { up.waitForInFlight() }
        runCurrent()
        assertTrue(waiter.isActive)
        gate.complete(Unit)
        waiter.await()
        assertEquals(0, store.count)
        assertFalse(up.isUploading)
        first.await()
    }

    @Test
    fun does_nothing_while_disabled_opt_out() = runTest {
        addEvents(2)
        enabled = false
        val up = uploader()
        up.flush()
        assertTrue(sent().isEmpty())
        assertEquals(2, store.count)
        enabled = true
        up.flush()
        assertEquals(1, sent().size)
    }

    // Endpoint

    @Test
    fun serverUrl_with_or_without_a_trailing_slash_and_with_a_path_prefix() = runTest {
        val cases = listOf(
            "https://loop.test" to "https://loop.test/api/ingest/analytics/batch",
            "https://loop.test/" to "https://loop.test/api/ingest/analytics/batch",
            "https://loop.test/base" to "https://loop.test/base/api/ingest/analytics/batch",
            "https://loop.test/base/" to "https://loop.test/base/api/ingest/analytics/batch",
        )
        for ((index, case) in cases.withIndex()) {
            val (server, expected) = case
            addEvents(1, prefix = "s$index-")
            uploader(serverUrl = server).flush()
            val sent = sent()
            assertEquals(server, expected, sent.last().url)
            assertEquals(server, index + 1, sent.size)
        }
    }

    // HttpUrlConnectionTransport

    @Test
    fun HttpUrlConnectionTransport_returns_status_lower_cased_headers_and_the_error_body() = runTest {
        val seen = AtomicReference<LocalHttpServer.Request>()
        LocalHttpServer { request ->
            seen.set(request)
            LocalHttpServer.Response(
                429,
                listOf("Retry-After" to "120", "Content-Type" to "application/json"),
                """{"error":"rate limited"}""".toByteArray(Charsets.UTF_8),
            )
        }.use { server ->
            val payload = Gzip.compress("""{"events":[]}""".toByteArray(Charsets.UTF_8))
            val response = HttpUrlConnectionTransport().send(
                "http://127.0.0.1:${server.port}/api/ingest/analytics/batch",
                mapOf("Authorization" to "Bearer k", "Content-Type" to "application/json", "Content-Encoding" to "gzip"),
                payload,
            )
            assertEquals(429, response.status)
            assertEquals("120", response.headers["retry-after"])
            assertEquals("application/json", response.headers["content-type"])
            assertTrue(response.headers.toString(), response.headers.keys.all { it == it.lowercase(Locale.ROOT) })
            assertEquals("""{"error":"rate limited"}""", String(response.body, Charsets.UTF_8))

            val request = seen.get()
            assertEquals("POST", request.method)
            assertEquals("/api/ingest/analytics/batch", request.path)
            assertEquals("Bearer k", request.headers["authorization"])
            assertEquals("application/json", request.headers["content-type"])
            assertEquals("gzip", request.headers["content-encoding"])
            assertArrayEquals(payload, request.body)
        }
    }

    @Test
    fun HttpUrlConnectionTransport_returns_a_2xx_body() = runTest {
        LocalHttpServer {
            LocalHttpServer.Response(202, emptyList(), """{"accepted":1,"dropped":0}""".toByteArray(Charsets.UTF_8))
        }.use { server ->
            val response = HttpUrlConnectionTransport().send("http://127.0.0.1:${server.port}/batch", emptyMap(), ByteArray(1))
            assertEquals(202, response.status)
            assertEquals("""{"accepted":1,"dropped":0}""", String(response.body, Charsets.UTF_8))
        }
    }

    @Test
    fun HttpUrlConnectionTransport_returns_an_empty_body_for_an_error_without_one() = runTest {
        LocalHttpServer { LocalHttpServer.Response(503, emptyList(), ByteArray(0)) }.use { server ->
            val response = HttpUrlConnectionTransport().send("http://127.0.0.1:${server.port}/batch", emptyMap(), ByteArray(1))
            assertEquals(503, response.status)
            assertEquals(0, response.body.size)
        }
    }

    @Test
    fun HttpUrlConnectionTransport_throws_a_SocketTimeoutException_when_the_server_does_not_answer() = runTest {
        val release = CountDownLatch(1)
        LocalHttpServer {
            release.await(5, TimeUnit.SECONDS)
            LocalHttpServer.Response(202, emptyList(), ByteArray(0))
        }.use { server ->
            try {
                HttpUrlConnectionTransport(timeoutMillis = 100)
                    .send("http://127.0.0.1:${server.port}/batch", emptyMap(), ByteArray(1))
                fail("expected a timeout")
            } catch (_: SocketTimeoutException) {
                // expected
            } finally {
                release.countDown()
            }
        }
    }
}

/**
 * A one-connection-at-a-time HTTP/1.1 server on the loopback interface, for
 * testing [HttpUrlConnectionTransport] against real sockets. (The JDK's
 * `com.sun.net.httpserver` is not on the Android unit-test compile classpath.)
 */
private class LocalHttpServer(private val handle: (Request) -> Response) : Closeable {
    /** A received request; header names are lower-cased. */
    class Request(val method: String, val path: String, val headers: Map<String, String>, val body: ByteArray)

    class Response(val status: Int, val headers: List<Pair<String, String>>, val body: ByteArray)

    private val socket = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
    val port: Int get() = socket.localPort

    init {
        thread(isDaemon = true, name = "LocalHttpServer") {
            while (!socket.isClosed) {
                val client = try {
                    socket.accept()
                } catch (_: IOException) {
                    break
                }
                try {
                    client.use { serve(it) }
                } catch (_: IOException) {
                    // The client went away (e.g. it timed out); serve the next one.
                }
            }
        }
    }

    private fun serve(client: Socket) {
        val input = BufferedInputStream(client.getInputStream())
        val requestLine = readLine(input).split(" ")
        val headers = LinkedHashMap<String, String>()
        while (true) {
            val line = readLine(input)
            if (line.isEmpty()) break
            val colon = line.indexOf(':')
            headers[line.substring(0, colon).trim().lowercase(Locale.ROOT)] = line.substring(colon + 1).trim()
        }
        val length = headers["content-length"]?.toInt() ?: 0
        val body = ByteArray(length)
        var read = 0
        while (read < length) {
            val n = input.read(body, read, length - read)
            if (n < 0) throw IOException("request body ended early")
            read += n
        }
        val response = handle(Request(requestLine[0], requestLine[1], headers, body))
        val head = StringBuilder("HTTP/1.1 ${response.status} Status\r\n")
        for ((name, value) in response.headers) head.append("$name: $value\r\n")
        head.append("Content-Length: ${response.body.size}\r\nConnection: close\r\n\r\n")
        val output = client.getOutputStream()
        output.write(head.toString().toByteArray(Charsets.ISO_8859_1))
        output.write(response.body)
        output.flush()
    }

    private fun readLine(input: BufferedInputStream): String {
        val line = StringBuilder()
        while (true) {
            val byte = input.read()
            if (byte < 0) throw IOException("connection closed mid-request")
            if (byte == '\n'.code) break
            if (byte != '\r'.code) line.append(byte.toChar())
        }
        return line.toString()
    }

    override fun close() {
        socket.close()
    }
}
