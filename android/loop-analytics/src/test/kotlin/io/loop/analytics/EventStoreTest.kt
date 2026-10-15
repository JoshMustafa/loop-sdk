package io.loop.analytics

import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeFalse
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import kotlin.concurrent.thread

class EventStoreTest {
    private lateinit var dir: File
    private lateinit var file: File

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("loop_store_test_").toFile()
        file = File(dir, "events.jsonl")
    }

    @After
    fun tearDown() {
        dir.walkBottomUp().forEach { it.setWritable(true) }
        dir.deleteRecursively()
    }

    private fun open(max: Int = 1000) = EventStore(file, max)

    private fun ids(store: EventStore) = store.peek(Int.MAX_VALUE).map { it.id }

    private fun fileLines() = file.readText(Charsets.UTF_8).split("\n").filter { it.isNotEmpty() }

    @Test
    fun appends_events_and_reloads_them_after_a_restart() {
        val store = open()
        store.add(sampleEvent("a"))
        store.add(sampleEvent("b"))

        val reloaded = open().peek(10)
        assertEquals(listOf("a", "b"), reloaded.map { it.id })
        assertEquals(sampleEvent("a").wireJson(), reloaded.first().wireJson())
        assertEquals(sampleEvent("a"), reloaded.first())
    }

    @Test
    fun persists_each_events_context_snapshot() {
        val context = mapOf("platform" to JsonValue.Str("ios"), "appVersion" to JsonValue.Str("1.0 (1)"))
        open().add(sampleEvent("a", context = context))
        assertEquals(context, open().peek(10).first().context)
    }

    @Test
    fun stores_one_json_object_per_line() {
        val store = open()
        store.add(sampleEvent("a"))
        store.add(sampleEvent("b"))
        val lines = fileLines()
        assertEquals(2, lines.size)
        // An independent parser (org.json) reads each line as an object.
        for (line in lines) JSONObject(line)
    }

    @Test
    fun when_full_drops_the_oldest_20_events_at_once() {
        val store = open(max = 30)
        for (i in 0 until 30) store.add(sampleEvent("$i"))
        assertEquals(30, store.count)
        store.add(sampleEvent("30"))
        assertEquals(11, store.count)
        var current = ids(store)
        assertEquals("20", current.first())
        assertEquals("30", current.last())
        store.add(sampleEvent("31"))
        assertEquals("no further drop until full again", 12, store.count)
        current = ids(store)
        assertEquals((20..31).map { "$it" }, current)

        assertEquals((20..31).map { "$it" }, ids(open(max = 30)))
    }

    @Test
    fun a_cap_below_20_keeps_at_least_the_new_event() {
        val store = open(max = 3)
        for (id in listOf("1", "2", "3", "4")) store.add(sampleEvent(id))
        assertEquals(listOf("4"), ids(store))
        store.add(sampleEvent("5"))
        assertEquals(listOf("4", "5"), ids(open(max = 3)))
    }

    @Test
    fun compacts_the_file_once_it_grows_well_past_the_cap() {
        val store = open(max = 25)
        for (i in 0 until 200) store.add(sampleEvent("$i"))
        assertTrue(fileLines().size <= 50)
        assertEquals(ids(store), ids(open(max = 25)))
    }

    @Test
    fun a_lower_cap_on_restart_keeps_only_the_newest_events() {
        val store = open(max = 10)
        for (id in listOf("1", "2", "3", "4")) store.add(sampleEvent(id))
        assertEquals(listOf("3", "4"), ids(open(max = 2)))
    }

    @Test
    fun skips_corrupt_and_truncated_lines() {
        val good = JsonValue.Obj(sampleEvent("ok").storageJson()).toJson()
        file.writeText("not json\n{\"id\": 1}\n$good\n{\"id\":\"half", Charsets.UTF_8)
        val store = open()
        assertEquals(listOf("ok"), ids(store))

        // Appends after a corrupt tail must still be readable after restart.
        store.add(sampleEvent("next"))
        assertEquals(listOf("ok", "next"), ids(open()))
    }

    @Test
    fun truncated_last_line_is_skipped() {
        val line = JSONObject(JsonValue.Obj(sampleEvent("e1").storageJson()).toJson()).toString() + "\n"
        file.writeText(line + """{"id":"e2","name":"Tru""", Charsets.UTF_8)
        val store = EventStore(file, 1000)
        assertEquals(listOf("e1"), store.peek(10).map { it.id })
    }

    /** Kotlin-only: a valid last line with no newline is repaired, so the next append is not glued onto it. */
    @Test
    fun a_last_line_without_a_newline_is_repaired_before_the_next_append() {
        file.writeText(JsonValue.Obj(sampleEvent("a").storageJson()).toJson(), Charsets.UTF_8)
        val store = open()
        assertEquals(listOf("a"), ids(store))
        store.add(sampleEvent("b"))
        assertEquals(listOf("a", "b"), ids(open()))
    }

    /** Kotlin-only: invalid UTF-8, blank lines and CRLF endings, as the Swift loader handles them. */
    @Test
    fun skips_invalid_utf8_and_blank_lines_and_accepts_crlf() {
        val good = JsonValue.Obj(sampleEvent("ok").storageJson()).toJson().toByteArray(Charsets.UTF_8)
        val bad = JsonValue.Obj(sampleEvent("bad").storageJson()).toJson().toByteArray(Charsets.UTF_8)
        // Invalid UTF-8 inside the name: a lenient decoder would load it with U+FFFD.
        bad[String(bad, Charsets.UTF_8).indexOf("Test Event")] = 0xFF.toByte()
        file.writeBytes(good + "\r\n \t\n".toByteArray() + bad + "\n".toByteArray())
        val store = open()
        assertEquals(listOf("ok"), ids(store))
        assertEquals(1, fileLines().size)
    }

    @Test
    fun peek_returns_the_oldest_events_once_they_are_persisted() {
        val store = open()
        for (id in listOf("a", "b", "c")) store.add(sampleEvent(id))
        assertEquals(listOf("a", "b"), store.peek(2).map { it.id })
        // Durable before upload: the peeked events are already on disk.
        assertEquals(listOf("a", "b", "c"), ids(open()))
    }

    @Test
    fun remove_deletes_by_id_in_memory_and_on_disk() {
        val store = open()
        for (id in listOf("a", "b", "c")) store.add(sampleEvent(id))
        store.remove(setOf("a", "c"))
        assertEquals(listOf("b"), ids(store))
        assertEquals(listOf("b"), ids(open()))
    }

    @Test
    fun rewrites_leave_the_right_content_and_no_temp_files() {
        val store = open(max = 25)
        for (i in 1..26) store.add(sampleEvent("e$i")) // drop-20 rewrite
        store.remove(setOf("e21")) // remove rewrite
        store.add(sampleEvent("e27")) // append after rewrite
        val decoded = fileLines().map { LoopEvent.fromStorage(JsonValue.parseObject(it)).id }
        assertEquals(listOf("e22", "e23", "e24", "e25", "e26", "e27"), decoded)
        assertEquals(listOf("events.jsonl"), dir.list()!!.toList())
    }

    @Test
    fun events_added_during_a_remove_are_not_lost() {
        val store = open()
        store.add(sampleEvent("a"))
        val start = CountDownLatch(1)
        val removing = thread { start.await(); store.remove(setOf("a")) }
        val adding = thread { start.await(); store.add(sampleEvent("b")) }
        start.countDown()
        removing.join()
        adding.join()
        assertEquals(listOf("b"), ids(store))
        assertEquals(listOf("b"), ids(open()))
    }

    @Test
    fun a_missing_file_opens_as_an_empty_queue() {
        val nested = File(dir, "nested/dir/events.jsonl")
        val store = EventStore(nested, 10)
        assertEquals(0, store.count)
        store.add(sampleEvent("a"))
        assertEquals(1, store.count)
        assertEquals(listOf("a"), EventStore(nested, 10).peek(10).map { it.id })
    }

    @Test
    fun works_without_a_file() {
        val store = EventStore(null, 10)
        store.add(sampleEvent("a"))
        store.add(sampleEvent("b"))
        store.remove(setOf("a"))
        assertEquals(listOf("b"), ids(store))
    }

    @Test
    fun full_queue_drops_oldest_20_and_keeps_new_event() {
        val store = EventStore(null, 25)
        for (i in 1..26) store.add(sampleEvent("e$i"))
        assertEquals((21..26).map { "e$it" }, store.peek(100).map { it.id })
    }

    @Test
    fun unicode_line_separators_inside_values_survive_a_restart() {
        val text = "one two\u0085three\r\nfour"
        open().add(sampleEvent("a", props = mapOf("text" to JsonValue.Str(text))))
        assertEquals(JsonValue.Str(text), open().peek(10).first().props["text"])
    }

    @Test
    fun an_unencodable_event_is_not_queued() {
        val store = open()
        store.add(sampleEvent("bad", props = mapOf("n" to JsonValue.Num(Double.NaN))))
        store.add(sampleEvent("good"))
        assertEquals(listOf("good"), ids(store))
        assertEquals(1, fileLines().size)
    }

    // Logging

    @Test
    fun write_failures_are_logged_and_the_events_stay_in_memory() {
        val log = LogRecorder()
        try {
            // A regular file where the queue's directory should be: every write fails.
            val blocker = File(dir, "blocker")
            blocker.writeBytes(ByteArray(0))
            val store = EventStore(File(blocker, "events.jsonl"), 10)

            store.add(sampleEvent("a")) // appended
            store.add(sampleEvent("b")) // the failed append makes this a rewrite

            assertEquals(2, store.count)
            val errors = log.messages(Log.Level.ERROR)
            assertEquals(errors.toString(), 2, errors.size)
            assertTrue(errors.toString(), errors.first().contains("append"))
            assertTrue(errors.toString(), errors.last().contains("rewrite"))
        } finally {
            log.stop()
        }
    }

    /** Review Focus 5: an unwritable directory is logged, events stay queued, and a later write recovers. */
    @Test
    fun write_failure_is_logged_and_events_stay_in_memory() {
        val readOnly = File(dir, "read-only").apply { mkdirs() }
        readOnly.setWritable(false)
        assumeFalse("the directory is still writable (running as root?)", readOnly.canWrite())
        val queue = File(readOnly, "events.jsonl")
        val log = LogRecorder()
        try {
            val store = EventStore(queue, 10)
            store.add(sampleEvent("a"))
            store.add(sampleEvent("b"))

            assertEquals(listOf("a", "b"), ids(store))
            val errors = log.messages(Log.Level.ERROR)
            assertEquals(errors.toString(), 2, errors.size)
            assertTrue(errors.toString(), errors.first().contains("append"))
            assertTrue(errors.toString(), errors.last().contains("rewrite"))
            for (message in errors) assertTrue(message, "device-1" !in message)

            // Storage comes back: the next change writes everything still queued.
            readOnly.setWritable(true)
            store.add(sampleEvent("c"))
            assertEquals(listOf("a", "b", "c"), ids(EventStore(queue, 10)))
            assertEquals(listOf("events.jsonl"), readOnly.list()!!.toList())
        } finally {
            log.stop()
        }
    }

    @Test
    fun an_unencodable_event_is_logged_by_name() {
        val log = LogRecorder()
        try {
            val store = open()
            store.add(sampleEvent("nan", name = "Score Posted", props = mapOf("score" to JsonValue.Num(Double.NaN))))

            assertEquals(0, store.count)
            val errors = log.messages(Log.Level.ERROR)
            assertEquals(1, errors.size)
            assertTrue(errors.toString(), errors.first().contains("Score Posted"))
        } finally {
            log.stop()
        }
    }
}
