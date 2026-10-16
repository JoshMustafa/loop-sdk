package io.loop.analytics

import io.loop.core.MemoryKeyValueStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class IdentityStoreTest {
    private var kv = MemoryKeyValueStore()
    private var counter = 0

    private fun load(legacy: String? = null) = IdentityStore(kv, legacy) {
        counter += 1
        "uuid-$counter"
    }

    // generateDeviceId

    @Test
    fun android_lower_case_uuid_v4_plus_r() {
        val id = generateDeviceId()
        val pattern = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}R$")
        assertTrue(id, pattern.matches(id))
        assertNotEquals(id, generateDeviceId())
    }

    // deviceId

    @Test
    fun generates_a_uuid_on_first_run_and_keeps_it_across_restarts() {
        assertEquals("uuid-1", load().deviceId)
        assertEquals("uuid-1", load().deviceId)
    }

    @Test
    fun adopts_the_legacy_id_on_first_run_only() {
        assertEquals("amp-device", load(legacy = "amp-device").deviceId)
        assertEquals("amp-device", load(legacy = "other").deviceId)
    }

    @Test
    fun ignores_a_blank_or_over_long_legacy_id() {
        assertEquals("uuid-1", load(legacy = "  ").deviceId)
        kv = MemoryKeyValueStore()
        assertEquals("uuid-2", load(legacy = "x".repeat(201)).deviceId)
    }

    @Test
    fun trims_the_legacy_id() {
        assertEquals("amp-device", load(legacy = "  amp-device \n").deviceId)
    }

    @Test
    fun persists_user_id_and_purchaser_id_null_clears_them() {
        val id = load()
        id.setUserId("12345")
        id.setPurchaserId("\$RCAnonymousID:abc")
        val again = load()
        assertEquals("12345", again.userId)
        assertEquals("\$RCAnonymousID:abc", again.purchaserId)

        again.setUserId(null)
        again.setPurchaserId(null)
        assertNull(load().userId)
        assertNull(load().purchaserId)
    }

    // user properties

    @Test
    fun merge_into_the_snapshot_null_removes_a_key_persisted() {
        val id = load()
        id.mergeUserProperties(
            mapOf(
                "Plan" to JsonValue.Str("free"),
                "Entries" to JsonValue.IntV(1),
                "Tags" to JsonValue.Arr(listOf(JsonValue.Str("a"))),
            ),
        )
        id.mergeUserProperties(mapOf("Plan" to JsonValue.Str("annual"), "Entries" to JsonValue.Null))
        val expected = mapOf("Plan" to JsonValue.Str("annual"), "Tags" to JsonValue.Arr(listOf(JsonValue.Str("a"))))
        assertEquals(expected, id.userProperties)
        assertEquals(expected, load().userProperties)
    }

    @Test
    fun snapshot_is_a_copy_that_later_merges_do_not_change() {
        val id = load()
        id.mergeUserProperties(mapOf("Plan" to JsonValue.Str("free")))
        val snapshot = id.userProperties
        id.mergeUserProperties(mapOf("Plan" to JsonValue.Str("annual")))
        assertEquals(mapOf("Plan" to JsonValue.Str("free")), snapshot)
    }

    @Test
    fun non_json_values_are_stringified() {
        val id = load()
        id.mergeUserProperties(Sanitize.props(mapOf("Since" to java.util.Date(1_767_312_000_000))))
        assertEquals(JsonValue.Str("2026-01-02T00:00:00.000Z"), id.userProperties["Since"])
    }

    @Test
    fun a_corrupt_stored_snapshot_loads_as_empty() {
        kv.setString(IdentityStore.USER_PROPS_KEY, "{not json")
        assertEquals(emptyMap<String, JsonValue>(), load().userProperties)
    }

    @Test
    fun opt_out_is_persisted() {
        val id = load()
        assertFalse(id.optOut)
        id.setOptOut(true)
        assertTrue(load().optOut)
    }

    @Test
    fun reset_gives_a_fresh_device_id_and_clears_user_props_purchaser() {
        val id = load(legacy = "amp-device")
        id.setUserId("12345")
        id.setPurchaserId("rc")
        id.mergeUserProperties(mapOf("Plan" to JsonValue.Str("annual")))
        id.setOptOut(true)

        id.reset()

        assertEquals("uuid-1", id.deviceId)
        assertNull(id.userId)
        assertNull(id.purchaserId)
        assertEquals(emptyMap<String, JsonValue>(), id.userProperties)
        assertTrue("opt-out is a user choice; reset keeps it", id.optOut)

        val again = load(legacy = "amp-device")
        assertEquals("uuid-1", again.deviceId)
        assertNull(again.userId)
        assertNull(again.purchaserId)
        assertEquals(emptyMap<String, JsonValue>(), again.userProperties)
        assertTrue(again.optOut)
    }

    @Test
    fun uses_the_documented_storage_keys() {
        val id = load()
        id.setUserId("u")
        id.setPurchaserId("p")
        id.mergeUserProperties(mapOf("k" to JsonValue.IntV(1)))
        id.setOptOut(true)
        assertEquals("uuid-1", kv.string("io.loop.analytics.device_id"))
        assertEquals("u", kv.string("io.loop.analytics.user_id"))
        assertEquals("p", kv.string("io.loop.analytics.purchaser_id"))
        assertEquals("""{"k":1}""", kv.string("io.loop.analytics.user_props"))
        assertEquals(true, kv.bool("io.loop.analytics.opt_out"))
    }
}
