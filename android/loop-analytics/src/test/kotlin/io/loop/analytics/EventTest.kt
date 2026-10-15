package io.loop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class EventTest {
    private val event = LoopEvent(
        id = "6f1c2a9e-0000-4000-8000-000000000001",
        name = "Purchase Completed",
        occurredAtMillis = 1_791_969_118_402, // 2026-10-14T09:11:58.402Z
        sessionId = 1_760_432_400_000,
        deviceId = "B3F1",
        userId = "12345",
        props = mapOf("Plan" to JsonValue.Str("annual"), "Restored" to JsonValue.Bool(false)),
        userProps = mapOf("Total Diary Entries" to JsonValue.IntV(412)),
    )

    @Test
    fun encodes_the_contract_field_names_with_ms_precision_utc_time() {
        assertEquals(
            mapOf(
                "id" to JsonValue.Str("6f1c2a9e-0000-4000-8000-000000000001"),
                "name" to JsonValue.Str("Purchase Completed"),
                "occurredAt" to JsonValue.Str("2026-10-14T09:11:58.402Z"),
                "sessionId" to JsonValue.IntV(1_760_432_400_000),
                "deviceId" to JsonValue.Str("B3F1"),
                "userId" to JsonValue.Str("12345"),
                "props" to JsonValue.Obj(mapOf("Plan" to JsonValue.Str("annual"), "Restored" to JsonValue.Bool(false))),
                "userProps" to JsonValue.Obj(mapOf("Total Diary Entries" to JsonValue.IntV(412))),
            ),
            event.wireJson(),
        )
    }

    @Test
    fun keeps_null_session_id_and_user_id_as_explicit_nulls() {
        val anon = LoopEvent(
            id = "x", name = "App Opened", occurredAtMillis = 1_767_225_600_000,
            sessionId = null, deviceId = "d", userId = null, props = emptyMap(), userProps = emptyMap(),
        )
        val json = anon.wireJson()
        assertEquals(JsonValue.Null, json["sessionId"])
        assertEquals(JsonValue.Null, json["userId"])
        assertEquals(JsonValue.Str("2026-01-01T00:00:00.000Z"), json["occurredAt"])
    }

    @Test
    fun round_trips_through_json() {
        val text = JsonValue.Obj(event.wireJson()).toJson()
        val decoded = LoopEvent.fromStorage(JsonValue.parseObject(text))
        assertEquals(event, decoded)
        assertEquals(event.wireJson(), decoded.wireJson())
    }

    @Test
    fun the_context_snapshot_is_stored_but_not_part_of_the_wire_event() {
        val context = mapOf("platform" to JsonValue.Str("ios"), "appVersion" to JsonValue.Str("5.2.0 (812)"))
        val withContext = LoopEvent(
            id = "x", name = "A", occurredAtMillis = 1_767_225_600_000,
            sessionId = null, deviceId = "d", userId = null, props = emptyMap(), userProps = emptyMap(),
            context = context,
        )
        assertNull(withContext.wireJson()["context"])
        val stored = withContext.storageJson()
        assertEquals(JsonValue.Obj(context), stored["context"])
        val decoded = LoopEvent.fromStorage(JsonValue.parseObject(JsonValue.Obj(stored).toJson()))
        assertEquals(withContext.context, decoded.context)
        assertEquals(withContext.wireJson(), decoded.wireJson())
    }

    @Test
    fun a_stored_event_without_a_context_snapshot_loads_with_null() {
        assertNull(LoopEvent.fromStorage(event.wireJson()).context)
    }

    @Test
    fun from_json_rejects_malformed_input() {
        assertThrows(MalformedEventException::class.java) {
            LoopEvent.fromStorage(mapOf("name" to JsonValue.Str("x")))
        }
        val badTime = event.wireJson() + ("occurredAt" to JsonValue.Str("yesterday"))
        assertThrows(MalformedEventException::class.java) { LoopEvent.fromStorage(badTime) }
        val badSession = event.wireJson() + ("sessionId" to JsonValue.Str("1"))
        assertThrows(MalformedEventException::class.java) { LoopEvent.fromStorage(badSession) }
    }

    @Test
    fun missing_props_load_as_empty_maps() {
        val json = event.wireJson() - "props" - "userProps"
        val decoded = LoopEvent.fromStorage(json)
        assertEquals(emptyMap<String, JsonValue>(), decoded.props)
        assertEquals(emptyMap<String, JsonValue>(), decoded.userProps)
    }

    @Test
    fun json_value_keeps_ints_and_doubles_distinct() {
        val value = JsonValue.Arr(
            listOf(
                JsonValue.IntV(1), JsonValue.Num(1.5), JsonValue.Bool(true), JsonValue.Null,
                JsonValue.Str("s"), JsonValue.Obj(mapOf("k" to JsonValue.IntV(-2))),
            ),
        )
        val text = value.toJson()
        assertEquals("""[1,1.5,true,null,"s",{"k":-2}]""", text)
        assertEquals(value, JsonValue.fromJson(text))
    }

    @Test
    fun timestamps_before_1970_and_far_future_format_correctly() {
        assertEquals("1969-12-31T23:59:59.999Z", LoopTimestamp.format(-1))
        assertEquals("2000-02-29T00:00:00.000Z", LoopTimestamp.format(951_782_400_000))
        assertEquals(951_782_400_000L, LoopTimestamp.parse("2000-02-29T00:00:00.000Z"))
        assertEquals(1_791_969_118_000L, LoopTimestamp.parse("2026-10-14T09:11:58Z"))
        assertEquals(1_791_969_118_400L, LoopTimestamp.parse("2026-10-14T09:11:58.4Z"))
        assertNull(LoopTimestamp.parse("2026-02-30T00:00:00.000Z"))
        assertNull(LoopTimestamp.parse("2026-10-14T09:11:58.402+01:00"))
    }
}
