package io.loop.analytics

import io.loop.core.Gzip
import io.loop.core.LoopClock
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.text.ParsePosition
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/**
 * Sends queued events to `POST /api/ingest/analytics/batch`.
 *
 * * A batch is the oldest ≤ batch-limit events (also kept under
 *   `maxBodyBytes` of JSON), gzip-compressed. One upload runs at a time;
 *   [flush] drains the queue batch by batch.
 * * 2xx → the batch is removed from the store.
 * * 413 → the batch is halved and retried at once; a single event that is
 *   still too large is dropped.
 * * 401/403 → a wrong or missing API key: the events stay queued and
 *   uploads pause for an hour (or the server's `Retry-After`).
 * * Other 4xx → the batch is dropped (it would never succeed).
 * * 429, 5xx, network errors and timeouts → the events stay queued and
 *   uploads pause with exponential backoff (30 s doubling to 10 min, or the
 *   server's `Retry-After`), reset by the next success.
 * * A failed batch is remembered and retried as the identical event set so
 *   server-side dedup makes a resend harmless.
 *
 * All time comes from the injected [LoopClock], except the request timeout,
 * which is real time. Drains run on [Dispatchers.IO] in a scope the uploader
 * owns, since the [EventStore] does blocking disk I/O.
 */
internal class Uploader(
    private val store: EventStore,
    private val transport: AnalyticsTransport,
    serverUrl: String,
    apiKey: String,
    private val context: suspend () -> JsonObject,
    maxBatchSize: Int,
    private val clock: LoopClock,
    private val isEnabled: () -> Boolean = { true },
    private val requestTimeoutMillis: Long = DEFAULT_REQUEST_TIMEOUT_MILLIS,
    private val maxBodyBytes: Int = DEFAULT_MAX_BODY_BYTES,
) {
    private val endpoint: String = (if (serverUrl.endsWith("/")) serverUrl else "$serverUrl/") + ENDPOINT_PATH
    private val headers: Map<String, String> = linkedMapOf(
        "Authorization" to "Bearer $apiKey",
        "Content-Type" to "application/json",
        "Content-Encoding" to "gzip",
    )
    private val maxBatchSize = maxOf(1, maxBatchSize)

    /**
     * Runs drains and requests. A request that outlives its timeout is left
     * running here, unawaited, so it cannot hold up a drain. A drain cannot
     * fail by design; should one throw anyway, it is logged rather than
     * reaching the app's uncaught-exception handler.
     */
    private val scope = CoroutineScope(
        SupervisorJob() + Dispatchers.IO + CoroutineExceptionHandler { _, error ->
            Log.error("Analytics upload stopped by an unexpected ${error.javaClass.name}")
        },
    )

    /** Guards [inFlight]. Never held across a suspension point. */
    private val jobLock = Any()
    private var inFlight: Job? = null

    /**
     * Held by the drain and by [primePendingBatch]; guards [batchLimit],
     * [pending] and [failures], and serialises writes to [nextAttemptAtMillis].
     */
    private val stateLock = Mutex()
    private var batchLimit = this.maxBatchSize

    /** The batch that failed last and must be retried unchanged. */
    private var pending: List<LoopEvent>? = null
    private var failures = 0

    /**
     * When uploads may resume after a failure, in ms since epoch; null when
     * not backing off.
     */
    @Volatile
    var nextAttemptAtMillis: Long? = null
        private set

    val isUploading: Boolean
        get() = synchronized(jobLock) { inFlight != null }

    val isBackingOff: Boolean
        get() {
            val next = nextAttemptAtMillis ?: return false
            return clock.nowMillis() < next
        }

    /**
     * Uploads queued events until the queue is empty, a retryable failure
     * occurs, or uploads are disabled. Joins the running upload if there is
     * one. Never throws.
     */
    suspend fun flush() {
        val job = synchronized(jobLock) {
            inFlight ?: scope.launch(start = CoroutineStart.LAZY) { drain() }.also {
                inFlight = it
                it.start()
            }
        }
        job.join()
    }

    /** Waits for the upload in flight, if any, without starting one. */
    suspend fun waitForInFlight() {
        synchronized(jobLock) { inFlight }?.join()
    }

    /**
     * Fixes the next batch now, from the store as it is, unless one is
     * already pending or uploads are disabled. The next upload sends exactly
     * this batch, whatever is added meanwhile; at startup that keeps a batch
     * resent after a kill identical, so server-side dedup still applies.
     * Waits for a drain in flight to finish first.
     */
    suspend fun primePendingBatch() {
        stateLock.withLock {
            if (pending == null && isEnabled()) takeNextBatch()
        }
    }

    private suspend fun drain() {
        try {
            stateLock.withLock {
                while (isEnabled() && !isBackingOff) {
                    val batch = pending ?: takeNextBatch() ?: break
                    if (!upload(batch)) break
                }
                if (store.count == 0) batchLimit = maxBatchSize
            }
        } finally {
            val self = currentCoroutineContext()[Job]
            synchronized(jobLock) { if (inFlight === self) inFlight = null }
        }
    }

    /**
     * The oldest queued events that fit one batch, remembered as [pending]
     * until acknowledged; null when the queue is empty or uploads are
     * disabled.
     */
    private fun takeNextBatch(): List<LoopEvent>? {
        val events = store.peek(batchLimit)
        if (events.isEmpty() || !isEnabled()) return null
        val batch = fitToBodyLimit(sameContextPrefix(events))
        pending = batch
        return batch
    }

    /** Sends one batch and applies the outcome. Returns whether draining should continue right away. */
    private suspend fun upload(batch: List<LoopEvent>): Boolean {
        val response = try {
            send(requestBody(batch))
        } catch (e: Exception) {
            currentCoroutineContext().ensureActive()
            null
        }
        if (response == null) {
            scheduleRetry(retryAfter = null)
            return false
        }

        val status = response.status
        if (status in 200..299) {
            store.remove(ids(batch))
            pending = null
            failures = 0
            nextAttemptAtMillis = null
            return true
        }
        if (status == 413) {
            if (batch.size == 1) {
                // Still too large on its own: drop it.
                Log.warning("Dropped an event the server rejected as too large (HTTP 413)")
                store.remove(ids(batch))
                pending = null
                batchLimit = maxBatchSize
            } else {
                val half = batch.size / 2
                pending = batch.subList(0, half).toList()
                batchLimit = half
            }
            return true
        }
        if (status == 401 || status == 403) {
            // A wrong or not-yet-configured key: keep the events until it's fixed.
            Log.error(
                "Analytics upload refused (HTTP $status): check the Loop API key. Events stay queued; retrying later",
            )
            scheduleRetry(retryAfter = retryAfter(response.headers), backoff = AUTH_BACKOFF_MILLIS)
            return false
        }
        // 1xx/3xx are unexpected here; treat them like a transient failure.
        if (status == 429 || status >= 500 || status < 400) {
            scheduleRetry(retryAfter = retryAfter(response.headers))
            return false
        }
        // Any other 4xx would never succeed.
        Log.error("Dropped ${batch.size} event(s) the server rejected (HTTP $status)")
        store.remove(ids(batch))
        pending = null
        return true
    }

    /**
     * `transport.send(...)`, or null once [requestTimeoutMillis] passes. The
     * loser is cancelled but never awaited, so a transport that ignores
     * cancellation cannot hold up the uploader. Rethrows the transport's error.
     */
    private suspend fun send(body: ByteArray): TransportResponse? {
        val request = scope.async { transport.send(endpoint, headers, body) }
        val timer = scope.launch { delay(requestTimeoutMillis) }
        try {
            return select {
                request.onAwait { it }
                timer.onJoin { null }
            }
        } finally {
            timer.cancel()
            request.cancel()
        }
    }

    /** The gzip-compressed JSON body: `sentAt`, the batch `context`, `events`. */
    private suspend fun requestBody(batch: List<LoopEvent>): ByteArray {
        val batchContext = batch.firstOrNull()?.context ?: context()
        val body = linkedMapOf(
            "sentAt" to JsonValue.Str(LoopTimestamp.format(clock.nowMillis())),
            "context" to JsonValue.Obj(batchContext),
            "events" to JsonValue.Arr(batch.map { JsonValue.Obj(it.wireJson()) }),
        )
        return Gzip.compress(JsonValue.Obj(body).toJson().toByteArray(Charsets.UTF_8))
    }

    /**
     * The leading run of [events] whose context snapshots are equal, so each
     * batch is sent with the context its events were tracked under.
     */
    private fun sameContextPrefix(events: List<LoopEvent>): List<LoopEvent> {
        val first = events.firstOrNull() ?: return events
        var count = 1
        while (count < events.size && events[count].context == first.context) count++
        return events.subList(0, count).toList()
    }

    /** The leading events whose wire JSON (plus one byte each) fits in [maxBodyBytes]; always at least one event. */
    private fun fitToBodyLimit(events: List<LoopEvent>): List<LoopEvent> {
        var bytes = 0L
        var count = 0
        for (event in events) {
            bytes += wireLength(event) + 1
            if (count > 0 && bytes > maxBodyBytes) break
            count++
        }
        return events.subList(0, count).toList()
    }

    private fun wireLength(event: LoopEvent): Int = try {
        JsonValue.Obj(event.wireJson()).toJson().toByteArray(Charsets.UTF_8).size
    } catch (_: JsonException) {
        0
    }

    private fun scheduleRetry(retryAfter: Long?, backoff: Long? = null) {
        failures += 1
        val exponential = INITIAL_BACKOFF_MILLIS shl minOf(failures - 1, 10)
        var delay = retryAfter ?: backoff ?: minOf(exponential, MAX_BACKOFF_MILLIS)
        delay = minOf(delay, MAX_RETRY_AFTER_MILLIS)
        delay = maxOf(delay, 0L)
        nextAttemptAtMillis = clock.nowMillis() + delay
    }

    /** The `Retry-After` delay in ms (delta-seconds or an HTTP date), or null when absent or unparseable. */
    private fun retryAfter(headers: Map<String, String>): Long? {
        val raw = headers.entries.firstOrNull { it.key.lowercase(Locale.ROOT) == "retry-after" }?.value
            ?: return null
        val value = raw.trim()
        if (value.isEmpty()) return null
        value.toLongOrNull()?.let { seconds ->
            // Clamped first so a huge value cannot overflow the conversion.
            return minOf(maxOf(seconds, 0L), MAX_RETRY_AFTER_MILLIS / 1000) * 1000
        }
        val date = parseHttpDate(value) ?: return null
        return date - clock.nowMillis()
    }

    /** RFC 7231 IMF-fixdate (e.g. `Wed, 14 Oct 2026 09:03:00 GMT`) in ms since epoch, or null. */
    private fun parseHttpDate(value: String): Long? {
        // SimpleDateFormat is not thread-safe, so each call makes its own.
        val format = SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss zzz", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("GMT")
            isLenient = false
        }
        val position = ParsePosition(0)
        val date = format.parse(value, position) ?: return null
        // The whole value must be the date, not just a prefix of it.
        if (position.index != value.length) return null
        return date.time
    }

    private fun ids(batch: List<LoopEvent>): Set<String> = batch.mapTo(HashSet()) { it.id }

    companion object {
        const val ENDPOINT_PATH = "api/ingest/analytics/batch"

        /** The server rejects bodies over 1 MB decompressed; leave headroom for the envelope and context. */
        const val DEFAULT_MAX_BODY_BYTES = 900 * 1024
        const val INITIAL_BACKOFF_MILLIS = 30_000L
        const val MAX_BACKOFF_MILLIS = 600_000L

        /** Fixed pause after 401/403 (bad or missing API key). */
        const val AUTH_BACKOFF_MILLIS = 3_600_000L

        /** Upper bound on how long a `Retry-After` can pause uploads. */
        const val MAX_RETRY_AFTER_MILLIS = 3_600_000L

        /** How long one request may take before it counts as a network error. */
        const val DEFAULT_REQUEST_TIMEOUT_MILLIS = 30_000L
    }
}
