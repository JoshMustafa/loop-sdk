package io.loop.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class LoopTest {
    @After
    fun tearDown() = Loop.resetForTesting()

    @Test
    fun options_default_to_the_loop_server() {
        assertEquals("https://loop-analytics-api.fly.dev", LoopOptions().serverUrl)
    }

    @Test
    fun configure_keeps_the_key_options_and_application_context() {
        Loop.resetForTesting()
        assertNull(Loop.configuration)
        val app = RuntimeEnvironment.getApplication()
        val options = LoopOptions(serverUrl = "https://example.test")
        Loop.configure(app, "loop_pk_test", options)
        val config = Loop.configuration!!
        assertEquals("loop_pk_test", config.apiKey)
        assertEquals(options, config.options)
        assertSame(app.applicationContext, config.applicationContext)
    }

    @Test
    fun every_configure_bumps_the_configuration_version() {
        val app = RuntimeEnvironment.getApplication()
        val before = Loop.configurationVersion
        Loop.configure(app, "loop_pk_a")
        Loop.configure(app, "loop_pk_b")
        assertEquals(before + 2, Loop.configurationVersion)
        assertEquals("loop_pk_b", Loop.configuration?.apiKey)
    }

    @Test
    fun system_clock_reads_wall_time_in_millis() {
        val before = System.currentTimeMillis()
        val now = SystemClock.nowMillis()
        assertEquals(true, now in before..System.currentTimeMillis())
    }
}
