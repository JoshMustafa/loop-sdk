package io.loop.flutter

import io.loop.analytics.LoopAnalyticsOptions
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class LoopAnalyticsPluginTest {
    @Test
    fun `native options map field by field onto analytics options`() {
        val options = NativeOptions(
            serverUrl = "https://example.test",
            flushQueueSize = 12,
            flushIntervalMillis = 45_000,
            minTimeBetweenSessionsMillis = 600_000,
            maxQueueSize = 500,
            maxBatchSize = 50,
            legacyDeviceId = "legacy-id",
        )

        assertEquals(
            LoopAnalyticsOptions(
                flushQueueSize = 12,
                flushIntervalMillis = 45_000,
                minTimeBetweenSessionsMillis = 600_000,
                maxQueueSize = 500,
                maxBatchSize = 50,
                legacyDeviceId = "legacy-id",
            ),
            options.toAnalyticsOptions(),
        )
    }

    @Test
    fun `the Dart defaults map onto the native defaults`() {
        val options = NativeOptions(
            flushQueueSize = 30,
            flushIntervalMillis = 30_000,
            minTimeBetweenSessionsMillis = 300_000,
            maxQueueSize = 1000,
            maxBatchSize = 100,
        )

        assertEquals(LoopAnalyticsOptions(), options.toAnalyticsOptions())
    }

    @Test
    fun `counts beyond the Int range are clamped, not wrapped`() {
        val options = NativeOptions(
            flushQueueSize = Long.MAX_VALUE,
            flushIntervalMillis = 1,
            minTimeBetweenSessionsMillis = 1,
            maxQueueSize = Long.MIN_VALUE,
            maxBatchSize = Int.MAX_VALUE.toLong() + 1,
        )

        val mapped = options.toAnalyticsOptions()
        assertEquals(Int.MAX_VALUE, mapped.flushQueueSize)
        assertEquals(Int.MIN_VALUE, mapped.maxQueueSize)
        assertEquals(Int.MAX_VALUE, mapped.maxBatchSize)
    }

    @Test
    fun `null keys are dropped and null values kept, nested values untouched`() {
        val nestedMap = hashMapOf<Any?, Any?>("a" to null, "b" to 1, "c" to listOf(null, 2L))
        val nestedList = listOf(null, mapOf("d" to null), listOf(null))
        val input = linkedMapOf<String?, Any?>(
            null to "dropped",
            "removed" to null,
            "int" to 7,
            "long" to 8_000_000_000L,
            "map" to nestedMap,
            "list" to nestedList,
        )

        val converted = stringKeyed(input)

        assertEquals(listOf("removed", "int", "long", "map", "list"), converted.keys.toList())
        assertTrue(converted.containsKey("removed"))
        assertEquals(null, converted["removed"])
        assertEquals(7, converted["int"])
        assertEquals(8_000_000_000L, converted["long"])
        assertEquals(nestedMap, converted["map"])
        assertEquals(nestedList, converted["list"])
    }
}
