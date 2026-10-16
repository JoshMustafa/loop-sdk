package io.loop.analytics.conformance

import io.loop.analytics.EngineHarness
import io.loop.analytics.JsonObject
import io.loop.analytics.JsonValue
import io.loop.analytics.LoopAnalyticsOptions
import io.loop.analytics.blockingTest
import kotlinx.coroutines.CancellationException
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.net.URI

/**
 * Runs the shared conformance cases (`conformance/cases/analytics`) against
 * `AnalyticsEngine`. The case format is defined in `conformance/README.md`;
 * this is a port of the Swift runner (`ios/Tests/LoopAnalyticsTests/ConformanceTests.swift`).
 */
class ConformanceTest {
    @Test
    fun runner_finds_all_cases() {
        val files = caseFiles()
        assertTrue(
            "Only ${files.size} case file(s) in ${CASES_DIRECTORY.canonicalPath}",
            files.size >= MINIMUM_CASE_COUNT,
        )
    }

    @Test
    fun all_conformance_cases() = blockingTest(timeoutMillis = 300_000) {
        val files = caseFiles()
        if (files.size < MINIMUM_CASE_COUNT) {
            fail("Only ${files.size} case file(s) in ${CASES_DIRECTORY.canonicalPath}")
        }
        val failures = ArrayList<String>()
        for (file in files) {
            val slug = file.nameWithoutExtension
            if (slug in KNOWN_FAILURES) continue
            val spec = try {
                JsonValue.parseObject(file.readText(Charsets.UTF_8))
            } catch (e: Exception) {
                failures.add("$slug: unreadable case file: $e")
                continue
            }
            ConformanceCaseRunner(spec).run()?.let { failures.add("$slug: $it") }
        }
        if (failures.isNotEmpty()) {
            fail("${failures.size} of ${files.size} conformance case(s) failed:\n" + failures.joinToString("\n"))
        }
    }

    private companion object {
        /** Cases in the suite today; fewer loaded means the path is wrong. */
        const val MINIMUM_CASE_COUNT = 39

        /**
         * Cases this SDK is known to fail, by file name (without `.json`), with
         * the reason. They stay in the suite and are skipped here only.
         */
        val KNOWN_FAILURES: Map<String, String> = emptyMap()

        /** Gradle runs unit tests from the module directory (`android/loop-analytics`). */
        val CASES_DIRECTORY: File =
            File(requireNotNull(System.getProperty("user.dir"))).resolve("../../conformance/cases/analytics")

        fun caseFiles(): List<File> =
            CASES_DIRECTORY.listFiles { file -> file.isFile && file.extension == "json" }
                .orEmpty()
                .sortedBy { it.name }
    }
}

/** A case step or expectation that did not hold. Ends the case. */
private class CaseFailure(message: String) : Exception(message)

/**
 * Drives one case. Storage, the clock, the id counters and the request log
 * live in the harness and survive `restart`.
 */
private class ConformanceCaseRunner(private val spec: JsonObject) {
    private var harness: EngineHarness? = null

    private val h: EngineHarness
        get() = harness ?: throw CaseFailure("no engine")

    /** Runs the case; returns the first failure, or null when it passed. */
    suspend fun run(): String? {
        try {
            harness = EngineHarness.create(options(spec["options"]))
            h.engine.waitUntilIdle()
            val steps = array(spec["steps"] ?: JsonValue.Arr(emptyList()), "steps")
            for ((i, value) in steps.withIndex()) {
                val step = obj(value, "steps[$i]")
                val op = (step["op"] as? JsonValue.Str)?.value ?: "?"
                perform(step, "steps[$i] ($op)")
                h.engine.waitUntilIdle()
            }
            checkEveryRequest()
            checkExpect(obj(spec["expect"] ?: JsonValue.Obj(emptyMap()), "expect"))
            return null
        } catch (e: CaseFailure) {
            return e.message
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            return e.toString()
        } finally {
            harness?.let {
                if (it.hasEngine) it.engine.dispose()
                it.removeStorage()
            }
        }
    }

    // Steps

    private suspend fun perform(step: JsonObject, at: String) {
        val engine = h.engine
        when (string(step["op"])) {
            "track" -> {
                var props: Map<String, JsonValue>? = step["props"]?.let { obj(it, "$at.props") }
                step["fill"]?.let { fillValue ->
                    val fill = obj(fillValue, "$at.fill")
                    val key = string(fill["key"])
                    val count = (fill["count"] as? JsonValue.IntV)?.value
                    if (key == null || count == null) throw CaseFailure("$at: fill needs a string key and an int count")
                    props = LinkedHashMap(props.orEmpty()).apply { put(key, JsonValue.Str("x".repeat(count.toInt()))) }
                }
                engine.track(requiredString(step["name"], "$at.name"), props)
            }
            "setUserId" -> engine.setUserId(string(step["userId"]))
            "setUserProperties" -> engine.setUserProperties(obj(step["props"] ?: JsonValue.Null, "$at.props"))
            "setPurchaserId" -> engine.setPurchaserId(string(step["purchaserId"]))
            "flush" -> engine.flush()
            "reset" -> engine.reset()
            "setOptOut" -> {
                val optOut = (step["optOut"] as? JsonValue.Bool)?.value ?: throw CaseFailure("$at: optOut must be a bool")
                engine.setOptOut(optOut)
            }
            "advance" -> h.advance(int(step["ms"], "$at.ms"))
            "lifecycle" -> when (string(step["state"])) {
                "foreground" -> h.lifecycle.emit(true)
                "background" -> h.lifecycle.emit(false)
                else -> throw CaseFailure("$at: unknown lifecycle state ${ConformanceMatcher.describe(step["state"])}")
            }
            "respond" -> if (string(step["error"]) == "network") {
                h.transport.failNext()
            } else {
                val headers = obj(step["headers"] ?: JsonValue.Obj(emptyMap()), "$at.headers")
                    .mapValues { (name, value) -> requiredString(value, "$at.headers.$name") }
                h.transport.respond(
                    int(step["status"], "$at.status").toInt(),
                    headers = headers,
                    body = string(step["body"]).orEmpty(),
                )
            }
            "restart" -> {
                // Explicit options replace the case options; absent, they
                // stay (null keeps the harness's options).
                val options = step["options"]?.let { options(it) }
                engine.dispose()
                harness = h.restarted(options = options, transport = h.transport)
            }
            "check" -> {
                step["requests"]?.let { want ->
                    val n = int(want, "$at.requests")
                    val got = h.transport.requests.size
                    if (got.toLong() != n) throw CaseFailure("$at: requests so far: expected $n, got $got")
                }
                step["queueLength"]?.let { want ->
                    val n = int(want, "$at.queueLength")
                    val got = engine.queueLength()
                    if (got.toLong() != n) throw CaseFailure("$at: queued events: expected $n, got $got")
                }
            }
            else -> throw CaseFailure("$at: unknown op")
        }
    }

    // Expectations

    private fun checkEveryRequest() {
        for ((i, sent) in h.transport.requests.withIndex()) {
            val path = URI(sent.url).path
            if (path != ENDPOINT_PATH) throw CaseFailure("requests[$i] path: expected $ENDPOINT_PATH, got $path")
            val authorization = header(sent.headers, "Authorization")
            if (authorization != "Bearer ${EngineHarness.API_KEY}") {
                throw CaseFailure("requests[$i] Authorization: got $authorization")
            }
            val encoding = header(sent.headers, "Content-Encoding")
            if (encoding != "gzip") throw CaseFailure("requests[$i] Content-Encoding: got $encoding")
        }
    }

    private fun checkExpect(expect: JsonObject) {
        val bodies = JsonValue.Arr(h.transport.requests.map { JsonValue.Obj(it.body) })
        expect["requests"]?.let { want ->
            val root = JsonValue.Obj(mapOf("requests" to bodies))
            ConformanceMatcher.mismatch(bodies, want, root, "requests")?.let { throw CaseFailure(it) }
        }
        expect["queueLength"]?.let { want ->
            val n = int(want, "expect.queueLength")
            val got = h.engine.queueLength()
            if (got.toLong() != n) throw CaseFailure("expect.queueLength: expected $n, got $got")
        }
    }

    private companion object {
        const val ENDPOINT_PATH = "/api/ingest/analytics/batch"
        val OPTION_KEYS = setOf(
            "flushQueueSize", "flushIntervalMs", "minTimeBetweenSessionsMs",
            "maxQueueSize", "maxBatchSize", "legacyDeviceId",
        )

        /** Header names are case-insensitive. */
        fun header(headers: Map<String, String>, name: String): String? =
            headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value

        // Case JSON

        /** The case's `options` (all keys optional) as engine options. */
        fun options(value: JsonValue?): LoopAnalyticsOptions {
            val o = obj(value ?: JsonValue.Obj(emptyMap()), "options")
            val unknown = o.keys - OPTION_KEYS
            if (unknown.isNotEmpty()) throw CaseFailure("Unknown options: ${unknown.sorted()}")
            val defaults = LoopAnalyticsOptions()
            return LoopAnalyticsOptions(
                flushQueueSize = o["flushQueueSize"]?.let { int(it, "options.flushQueueSize").toInt() }
                    ?: defaults.flushQueueSize,
                flushIntervalMillis = o["flushIntervalMs"]?.let { int(it, "options.flushIntervalMs") }
                    ?: defaults.flushIntervalMillis,
                minTimeBetweenSessionsMillis = o["minTimeBetweenSessionsMs"]
                    ?.let { int(it, "options.minTimeBetweenSessionsMs") }
                    ?: defaults.minTimeBetweenSessionsMillis,
                maxQueueSize = o["maxQueueSize"]?.let { int(it, "options.maxQueueSize").toInt() }
                    ?: defaults.maxQueueSize,
                maxBatchSize = o["maxBatchSize"]?.let { int(it, "options.maxBatchSize").toInt() }
                    ?: defaults.maxBatchSize,
                legacyDeviceId = string(o["legacyDeviceId"]),
            )
        }

        fun string(value: JsonValue?): String? = (value as? JsonValue.Str)?.value

        fun requiredString(value: JsonValue?, what: String): String =
            string(value) ?: throw CaseFailure("$what: expected a string")

        fun int(value: JsonValue?, what: String): Long =
            (value as? JsonValue.IntV)?.value ?: throw CaseFailure("$what: expected an int")

        fun obj(value: JsonValue, what: String): JsonObject =
            (value as? JsonValue.Obj)?.values ?: throw CaseFailure("$what: expected an object")

        fun array(value: JsonValue, what: String): List<JsonValue> =
            (value as? JsonValue.Arr)?.values ?: throw CaseFailure("$what: expected an array")
    }
}
