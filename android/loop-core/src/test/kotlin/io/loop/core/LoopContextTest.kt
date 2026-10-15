package io.loop.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale

class LoopContextTest {
    @Test
    fun json_omits_null_fields_but_always_has_purchaser_and_sdk() {
        val ctx = LoopContext(
            platform = "Android", osName = "android", osVersion = "15", appVersion = "1.0.0",
            appBuild = null, deviceModel = "Pixel 9", deviceManufacturer = "Google",
            deviceBrand = null, isTablet = false, locale = "en-GB",
        )
        val json = ctx.json(purchaserId = null, sdk = "loop-android" to "2.0.0")
        assertFalse(json.has("appBuild"))
        assertFalse(json.has("deviceBrand"))
        assertTrue(json.has("purchaserId"))
        assertTrue(json.isNull("purchaserId"))
        assertEquals(JSONObject.NULL, json.get("purchaserId"))
        val sdk = json.getJSONObject("sdk")
        assertEquals(setOf("name", "version"), sdk.keyNames())
        assertEquals("loop-android", sdk.getString("name"))
        assertEquals("2.0.0", sdk.getString("version"))
        assertEquals(false, json.get("isTablet"))
        assertEquals("Android", json.getString("platform"))
        assertEquals("en-GB", json.getString("locale"))
        assertEquals(
            setOf("platform", "osName", "osVersion", "appVersion", "deviceModel", "deviceManufacturer",
                "isTablet", "locale", "purchaserId", "sdk"),
            json.keyNames(),
        )
    }

    @Test
    fun json_keeps_a_purchaser_id_when_set() {
        val json = LoopContext(platform = "Android").json(purchaserId = "p_1", sdk = "loop-android" to "2.0.0")
        assertEquals("p_1", json.getString("purchaserId"))
        assertEquals(setOf("platform", "purchaserId", "sdk"), json.keyNames())
    }

    @Test
    fun locale_tag_is_bcp47() {
        assertEquals("en-GB", LoopContext.localeTag(Locale("en", "GB")))
        val withCalendar = LoopContext.localeTag(Locale.forLanguageTag("en-GB-u-ca-buddhist"))
        assertEquals("en-GB", withCalendar)
    }

    @Test
    fun locale_tag_keeps_only_language_script_and_region() {
        val cases = listOf(
            Locale("en", "GB") to "en-GB",
            Locale.forLanguageTag("en-GB-u-ca-buddhist") to "en-GB",
            Locale.forLanguageTag("en-US-u-rg-gbzzzz") to "en-US",
            Locale.forLanguageTag("zh-Hant-TW") to "zh-Hant-TW",
            Locale.forLanguageTag("sr-Latn") to "sr-Latn",
            Locale.forLanguageTag("es-419") to "es-419",
            Locale("fr") to "fr",
            Locale.forLanguageTag("ca-ES-valencia") to "ca-ES",
            Locale.forLanguageTag("de-DE-x-private") to "de-DE",
        )
        for ((locale, expected) in cases) {
            assertEquals(locale.toString(), expected, LoopContext.localeTag(locale))
        }
    }

    @Test
    fun locale_tag_uses_the_modern_code_for_legacy_languages() {
        // java.util.Locale may report Hebrew as the legacy "iw".
        assertEquals("he-IL", LoopContext.localeTag(Locale("iw", "IL")))
    }

    @Test
    fun locale_tag_is_null_without_a_language() {
        assertNull(LoopContext.localeTag(Locale.ROOT))
    }
}

private fun JSONObject.keyNames(): Set<String> = keys().asSequence().toSet()
