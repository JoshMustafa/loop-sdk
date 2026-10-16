package io.loop.core

import android.content.Context
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class KeyValueStoreTest {
    private val app get() = RuntimeEnvironment.getApplication()

    @Test
    fun shared_preferences_store_round_trips_and_null_removes() {
        val store = SharedPreferencesStore(app, "io.loop.tests")
        assertRoundTripsAndNullRemoves(store)
        assertFalse(app.getSharedPreferences("io.loop.tests", Context.MODE_PRIVATE).contains("s"))
    }

    @Test
    fun shared_preferences_store_survives_a_new_instance() {
        SharedPreferencesStore(app, "io.loop.tests").setLong("i", 42L)
        assertEquals(42L, SharedPreferencesStore(app, "io.loop.tests").long("i"))
    }

    @Test
    fun shared_preferences_store_returns_null_for_a_value_of_another_type() {
        val store = SharedPreferencesStore(app, "io.loop.tests")
        store.setString("k", "text")
        assertNull(store.long("k"))
        assertNull(store.bool("k"))
    }

    @Test
    fun memory_store_round_trips_and_null_removes() {
        assertRoundTripsAndNullRemoves(MemoryKeyValueStore())
    }

    private fun assertRoundTripsAndNullRemoves(store: KeyValueStore) {
        store.setString("s", "a")
        store.setLong("i", 1_767_225_600_000L)
        store.setBool("b", true)
        assertEquals("a", store.string("s"))
        assertEquals(1_767_225_600_000L, store.long("i"))
        assertEquals(true, store.bool("b"))
        store.setString("s", null)
        store.setLong("i", null)
        store.setBool("b", null)
        assertNull(store.string("s"))
        assertNull(store.long("i"))
        assertNull(store.bool("b"))
    }
}
