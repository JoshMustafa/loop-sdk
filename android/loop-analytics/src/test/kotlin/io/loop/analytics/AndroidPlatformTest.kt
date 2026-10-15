package io.loop.analytics

import android.app.Application
import android.content.Context
import android.os.Looper
import android.os.StrictMode
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.ProcessLifecycleOwner
import io.loop.core.KeyValueStore
import io.loop.core.Loop
import io.loop.core.LoopContext
import io.loop.core.LoopOptions
import kotlinx.coroutines.delay
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeFalse
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import java.io.File
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * The Android adapters (production environment, `ProcessLifecycleOwner`,
 * device context) and the plan's review-focus cases, run through the public
 * API on Robolectric with the real queue file and SharedPreferences. Only the
 * transport is faked.
 */
@RunWith(RobolectricTestRunner::class)
class AndroidPlatformTest {
    private lateinit var app: Application
    private val transport = RecordingTransport()
    private var log: LogRecorder? = null

    @Before
    fun setUp() {
        app = RuntimeEnvironment.getApplication()
        Loop.resetForTesting()
        // Every test starts with no queue and no stored identity.
        File(app.noBackupFilesDir, "loop").deleteRecursively()
        app.getSharedPreferences(AnalyticsEnvironment.PREFERENCES_NAME, Context.MODE_PRIVATE).edit().clear().commit()
    }

    @After
    fun tearDown() = blockingTest {
        LoopAnalytics.resetForTesting()
        AnalyticsRuntime.shared.waitForPendingCalls()
        Loop.resetForTesting()
        log?.stop()
    }

    /** The real Android environment with the recording transport; [change] adjusts it further. */
    private fun useProductionEnvironment(change: (AnalyticsEnvironment) -> AnalyticsEnvironment = { it }) {
        LoopAnalytics.resetForTesting { configuration ->
            change(AnalyticsEnvironment.production(configuration.applicationContext).copy(transport = transport))
        }
    }

    private fun configure() {
        Loop.configure(app, EngineHarness.API_KEY, LoopOptions(serverUrl = EngineHarness.SERVER_URL))
    }

    private fun isMainThread() = Looper.myLooper() == Looper.getMainLooper()

    private class TestLifecycleOwner : LifecycleOwner {
        val registry = LifecycleRegistry(this)
        override val lifecycle: Lifecycle get() = registry
    }

    // Production environment

    @Test
    fun the_library_manifest_requests_the_INTERNET_permission() {
        // Merged into the app's manifest, so an app that does not ask for it still uploads.
        @Suppress("DEPRECATION")
        val requested = app.packageManager
            .getPackageInfo(app.packageName, android.content.pm.PackageManager.GET_PERMISSIONS)
            .requestedPermissions.orEmpty()
        assertTrue(requested.toList().toString(), "android.permission.INTERNET" in requested)
    }

    @Test
    fun production_environment_uses_no_backup_storage_and_the_io_loop_analytics_preferences() {
        val environment = AnalyticsEnvironment.production(app)

        assertEquals(File(app.noBackupFilesDir, "loop/analytics-queue.jsonl"), environment.queueFile)
        environment.kv.setString("probe", "value")
        assertEquals(
            "value",
            app.getSharedPreferences("io.loop.analytics", Context.MODE_PRIVATE).getString("probe", null),
        )
        assertEquals("loop-android" to "2.0.0", environment.sdk)
        assertEquals(LoopContext.capture(app), environment.context())
        assertTrue(environment.transport is HttpUrlConnectionTransport)
        assertTrue(environment.scheduler is TimerScheduler)
        assertSame(ProcessLifecycleOwner.get(), (environment.lifecycle as ProcessLifecycleSource).owner)
        assertEquals(Uploader.DEFAULT_REQUEST_TIMEOUT_MILLIS, environment.requestTimeoutMillis)
        assertTrue(Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$").matches(environment.newEventId()))
        assertTrue(Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}R$").matches(environment.newDeviceId()))
    }

    @Test
    fun the_device_context_is_recaptured_after_a_configuration_change() {
        RuntimeEnvironment.setQualifiers("en-rGB")
        val environment = AnalyticsEnvironment.production(app)
        assertEquals("en-GB", environment.context().locale)

        RuntimeEnvironment.setQualifiers("fr-rFR")
        app.onConfigurationChanged(app.resources.configuration)

        assertEquals("fr-FR", environment.context().locale)
        assertEquals(LoopContext.capture(app), environment.context())
    }

    @Test
    fun events_reach_the_queue_file_and_preferences_and_upload() = blockingTest {
        useProductionEnvironment()
        configure()
        LoopAnalytics.start(LoopAnalyticsOptions(flushQueueSize = 100))
        LoopAnalytics.setUserId("u1")
        LoopAnalytics.track("Item Viewed", mapOf("Index" to 1))
        AnalyticsRuntime.shared.waitForPendingCalls()

        val queue = File(app.noBackupFilesDir, "loop/analytics-queue.jsonl")
        assertEquals(1, queue.readLines().size)
        val prefs = app.getSharedPreferences("io.loop.analytics", Context.MODE_PRIVATE)
        assertEquals(LoopAnalytics.deviceId, prefs.getString(IdentityStore.DEVICE_ID_KEY, null))
        assertEquals("u1", prefs.getString(IdentityStore.USER_ID_KEY, null))

        LoopAnalytics.flush()

        assertEquals(listOf("Item Viewed"), transport.sentNames)
        val context = transport.requests.single().context
        assertEquals(JsonValue.Str("Android"), context["platform"])
        assertEquals(JsonValue.Obj(mapOf("name" to JsonValue.Str("loop-android"), "version" to JsonValue.Str("2.0.0"))), context["sdk"])
        assertEquals(0, queue.readLines().size)
    }

    @Test
    fun flushAsync_and_resetAsync_call_back_on_the_main_thread_once_done() = blockingTest {
        val calls = Collections.synchronizedList(mutableListOf<String>())
        // Before Loop.configure the call is dropped, but the callback still comes.
        LoopAnalytics.flushAsync { calls.add("dropped flush, main=${isMainThread()}") }
        awaitMainThreadCallbacks(calls, 1)

        useProductionEnvironment()
        configure()
        LoopAnalytics.start(LoopAnalyticsOptions(flushQueueSize = 100))
        LoopAnalytics.track("A")
        LoopAnalytics.flushAsync { calls.add("flushed ${transport.sentNames}, main=${isMainThread()}") }
        awaitMainThreadCallbacks(calls, 2)

        val before = LoopAnalytics.deviceId
        LoopAnalytics.resetAsync { calls.add("new device id ${LoopAnalytics.deviceId != before}, main=${isMainThread()}") }
        awaitMainThreadCallbacks(calls, 3)
        LoopAnalytics.flushAsync(null)
        LoopAnalytics.resetAsync(null)
        LoopAnalytics.flush()

        assertEquals(
            listOf("dropped flush, main=true", "flushed [A], main=true", "new device id true, main=true"),
            calls.toList(),
        )
    }

    /** Runs the main looper until [calls] has [n] entries (callbacks are posted there). */
    private suspend fun awaitMainThreadCallbacks(calls: List<String>, n: Int) {
        val deadline = System.nanoTime() + 5_000_000_000L
        while (calls.size < n) {
            if (System.nanoTime() > deadline) throw AssertionError("Timed out waiting for callback ${calls.size + 1}: $calls")
            shadowOf(Looper.getMainLooper()).idle()
            delay(5)
        }
    }

    // Process lifecycle

    @Test
    fun on_start_is_the_foreground_on_stop_the_background_and_the_initial_state_is_not_an_event() {
        val owner = TestLifecycleOwner()
        owner.registry.currentState = Lifecycle.State.RESUMED
        val seen = mutableListOf<Pair<Boolean, Boolean>>()

        ProcessLifecycleSource(owner).start { foreground, initial -> seen.add(foreground to initial) }

        assertEquals("the replayed ON_CREATE/ON_START/ON_RESUME are not events", listOf(true to true), seen)
        owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_PAUSE)
        owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_STOP)
        owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_START)
        owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_RESUME)

        assertEquals(listOf(true to true, false to false, true to false), seen)
    }

    @Test
    fun a_process_that_starts_in_the_background_reports_it_as_the_initial_state() {
        val owner = TestLifecycleOwner()
        owner.registry.currentState = Lifecycle.State.CREATED
        val seen = mutableListOf<Pair<Boolean, Boolean>>()

        ProcessLifecycleSource(owner).start { foreground, initial -> seen.add(foreground to initial) }
        owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_START)

        assertEquals(listOf(false to true, true to false), seen)
    }

    @Test
    fun a_process_lifecycle_that_was_never_initialised_is_logged_and_reports_no_state() {
        // What a host app gets when it removes androidx.startup's ProcessLifecycleInitializer:
        // the lifecycle never leaves INITIALIZED. Its state is unknown, not "background".
        val log = LogRecorder().also { this.log = it }
        val owner = TestLifecycleOwner()
        val seen = mutableListOf<Pair<Boolean, Boolean>>()

        ProcessLifecycleSource(owner).start { foreground, initial -> seen.add(foreground to initial) }

        assertEquals(emptyList<Pair<Boolean, Boolean>>(), seen)
        val warnings = log.messages(Log.Level.WARNING).filter { it.contains("ProcessLifecycleInitializer") }
        assertEquals(log.messages(Log.Level.WARNING).toString(), 1, warnings.size)

        // Should it start after all, changes are still reported.
        owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_CREATE)
        owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_START)
        assertEquals(listOf(true to false), seen)
    }

    @Test
    fun starting_off_the_main_thread_registers_on_the_main_thread() {
        val owner = TestLifecycleOwner()
        owner.registry.currentState = Lifecycle.State.STARTED
        val seen = Collections.synchronizedList(mutableListOf<Triple<Boolean, Boolean, Boolean>>())

        thread {
            ProcessLifecycleSource(owner).start { foreground, initial -> seen.add(Triple(foreground, initial, isMainThread())) }
        }.join()
        assertEquals("posted to the main thread, not run on the caller's", emptyList<Any>(), seen.toList())

        shadowOf(Looper.getMainLooper()).idle()
        owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_STOP)

        assertEquals(listOf(Triple(true, true, true), Triple(false, false, true)), seen.toList())
    }

    @Test
    fun the_engine_flushes_when_the_process_goes_to_the_background() = blockingTest {
        val owner = TestLifecycleOwner()
        owner.registry.currentState = Lifecycle.State.RESUMED
        useProductionEnvironment { it.copy(lifecycle = ProcessLifecycleSource(owner)) }
        configure()
        LoopAnalytics.start(LoopAnalyticsOptions(flushQueueSize = 100))
        LoopAnalytics.track("A")
        AnalyticsRuntime.shared.waitForPendingCalls()
        shadowOf(Looper.getMainLooper()).idle() // the observer is registered on the main thread
        assertEquals(0, transport.requests.size)

        owner.registry.handleLifecycleEvent(Lifecycle.Event.ON_STOP)
        transport.waitForRequests(1)

        assertEquals(listOf("A"), transport.sentNames)
    }

    // Review focus 2: main-thread safety

    @Test
    fun track_on_the_main_thread_does_no_disk_work_there() {
        assertTrue(isMainThread())
        val onMain = AtomicInteger()
        useProductionEnvironment { environment ->
            environment.copy(
                kv = ThreadCheckingStore(environment.kv) { if (isMainThread()) onMain.incrementAndGet() },
                // Called on the thread that queues each event on disk.
                newEventId = {
                    if (isMainThread()) onMain.incrementAndGet()
                    environment.newEventId()
                },
            )
        }
        val previous = StrictMode.getThreadPolicy()
        StrictMode.setThreadPolicy(StrictMode.ThreadPolicy.Builder().detectAll().penaltyDeath().build())
        try {
            configure()
            LoopAnalytics.start(LoopAnalyticsOptions(flushQueueSize = 1000))
            repeat(100) { LoopAnalytics.track("Main $it", mapOf("Index" to it)) }
            LoopAnalytics.setUserId("u1")
            LoopAnalytics.setUserProperties(mapOf("Plan" to "annual"))
            LoopAnalytics.flushAsync()
        } finally {
            StrictMode.setThreadPolicy(previous)
        }
        blockingTest { LoopAnalytics.flush() }

        assertEquals(100, transport.sentNames.size)
        assertEquals("storage or event work ran on the main thread", 0, onMain.get())
    }

    /** Counts calls through [check] before delegating. */
    private class ThreadCheckingStore(private val store: KeyValueStore, private val check: () -> Unit) : KeyValueStore {
        override fun string(key: String): String? = store.string(key).also { check() }
        override fun long(key: String): Long? = store.long(key).also { check() }
        override fun bool(key: String): Boolean? = store.bool(key).also { check() }
        override fun setString(key: String, value: String?) = store.setString(key, value).also { check() }
        override fun setLong(key: String, value: Long?) = store.setLong(key, value).also { check() }
        override fun setBool(key: String, value: Boolean?) = store.setBool(key, value).also { check() }
    }

    // Review focus 4: concurrent callers

    @Test
    fun eight_threads_tracking_500_events_each_lose_none_and_keep_each_threads_order() = blockingTest(120_000) {
        useProductionEnvironment()
        configure()
        LoopAnalytics.start(LoopAnalyticsOptions(flushQueueSize = 10_000, maxQueueSize = 10_000))
        val ready = CountDownLatch(1)
        val threads = (0 until 8).map { t ->
            thread {
                ready.await()
                for (i in 0 until 500) LoopAnalytics.track("T$t", mapOf("i" to i))
            }
        }
        ready.countDown()
        threads.forEach { it.join() }
        LoopAnalytics.flush()

        val events = transport.sentEvents
        assertEquals(4000, events.size)
        assertEquals(4000, events.map { (it["id"] as JsonValue.Str).value }.toSet().size)
        for (t in 0 until 8) {
            val order = events.filter { it["name"] == JsonValue.Str("T$t") }
                .map { ((it["props"] as JsonValue.Obj).values["i"] as JsonValue.IntV).value }
            assertEquals("thread $t", (0L until 500L).toList(), order)
        }
    }

    // Review focus 1: process death

    @Test
    fun after_a_restart_the_first_request_is_exactly_the_events_on_disk() = blockingTest {
        useProductionEnvironment()
        configure()
        LoopAnalytics.start(LoopAnalyticsOptions(flushQueueSize = 100))
        LoopAnalytics.track("Old 1")
        LoopAnalytics.track("Old 2")
        AnalyticsRuntime.shared.waitForPendingCalls()
        assertEquals(0, transport.requests.size)

        // The process dies; the next launch starts over the same files and tracks at once.
        useProductionEnvironment()
        LoopAnalytics.start(LoopAnalyticsOptions(flushQueueSize = 100))
        LoopAnalytics.track("New")
        LoopAnalytics.flush()
        transport.waitForRequests(2)

        assertEquals(listOf(listOf("Old 1", "Old 2"), listOf("New")), transport.requests.map { it.names })
    }

    // Review focus 5: unwritable storage

    @Test
    fun an_unwritable_queue_directory_is_logged_and_events_are_kept_in_memory() = blockingTest {
        val directory = File(app.noBackupFilesDir, "loop")
        assertTrue(directory.mkdirs() || directory.isDirectory)
        directory.setWritable(false, false)
        try {
            assumeFalse("the file system ignores permissions here (running as root?)", directory.canWrite())
            val log = LogRecorder().also { this@AndroidPlatformTest.log = it }
            useProductionEnvironment()
            configure()
            LoopAnalytics.start(LoopAnalyticsOptions(flushQueueSize = 100))
            LoopAnalytics.track("A")
            LoopAnalytics.track("B")
            AnalyticsRuntime.shared.waitForPendingCalls()

            assertFalse(File(directory, "analytics-queue.jsonl").exists())
            assertTrue(log.messages(Log.Level.ERROR).toString(), log.messages(Log.Level.ERROR).any { it.contains("analytics queue file") })

            LoopAnalytics.flush()
            assertEquals("the events were kept in memory and uploaded", listOf("A", "B"), transport.sentNames)
        } finally {
            directory.setWritable(true, false)
        }
    }
}
