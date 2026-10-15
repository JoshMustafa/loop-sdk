package io.loop.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
class LoopContextCaptureTest {
    @Test
    fun capture_fills_android_platform_and_locale() {
        val ctx = LoopContext.capture(RuntimeEnvironment.getApplication())
        assertEquals("Android", ctx.platform)
        assertEquals("android", ctx.osName)
        assertNotNull(ctx.osVersion)
        assertNotNull(ctx.deviceModel)
        val locale = ctx.locale
        assertNotNull(locale)
        assertFalse("BCP 47 uses '-' not '_', got $locale", locale!!.contains("_"))
    }

    @Test
    @Config(qualifiers = "sw320dp")
    fun capture_reports_a_phone_below_600dp() {
        assertEquals(false, LoopContext.capture(RuntimeEnvironment.getApplication()).isTablet)
    }

    @Test
    @Config(qualifiers = "sw600dp")
    fun capture_reports_a_tablet_from_600dp() {
        assertEquals(true, LoopContext.capture(RuntimeEnvironment.getApplication()).isTablet)
    }

    @Test
    @Config(qualifiers = "fr-rCA")
    fun capture_reads_the_configuration_locale() {
        assertEquals("fr-CA", LoopContext.capture(RuntimeEnvironment.getApplication()).locale)
    }
}
