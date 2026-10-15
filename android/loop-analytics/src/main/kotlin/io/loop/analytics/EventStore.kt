package io.loop.analytics

import android.annotation.SuppressLint
import android.os.Build
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.file.StandardOpenOption

/**
 * The durable event queue: an append-only JSON-lines file mirrored in memory.
 *
 * * [add] appends the event's line to the file (and syncs it) before it
 *   returns, so [peek] only ever returns events that are on disk.
 * * The queue is capped at `maxQueueSize`: when an event would exceed it, the
 *   oldest [DROP_BATCH] events are dropped at once (so this happens at most
 *   once per [DROP_BATCH] events) and the file is rewritten. The file is also
 *   rewritten after every [remove] and compacted if it grows past twice the
 *   cap; opening keeps only the newest `maxQueueSize` lines.
 * * Rewrites go through a synced temp file and a rename, so a crash or power
 *   cut never leaves a half-written or empty queue.
 * * Corrupt or truncated lines are skipped on load, and a file that ends
 *   mid-line is repaired.
 * * With a null [file] the queue lives in memory only.
 *
 * Thread-safe: every call holds one lock. The constructor and every mutation
 * do disk I/O, so call them off the main thread.
 *
 * [syncDirectory] makes a rename durable and reports whether it could; it is
 * a parameter only so tests can make it fail.
 */
internal class EventStore(
    private val file: File?,
    maxQueueSize: Int,
    private val syncDirectory: (File) -> Boolean = DirectorySync::sync,
) {
    /** A queued event and its encoded line (UTF-8, without the newline). */
    private class Entry(val event: LoopEvent, val line: ByteArray)

    private val lock = Any()
    private val maxQueueSize = maxOf(1, maxQueueSize)

    /** Line count at which the file is compacted. */
    private val compactAt = if (this.maxQueueSize > Int.MAX_VALUE / 2) Int.MAX_VALUE else this.maxQueueSize * 2
    private val entries = ArrayList<Entry>()

    /** Lines in the file as far as we know (including dropped ones). */
    private var fileLines = 0

    /** Set when the file no longer matches [entries] (a drop or a failed write); the next write rewrites it. */
    private var needsRewrite = false

    /** A failed directory sync is logged once per store, not on every rewrite. */
    private var loggedDirectorySyncFailure = false

    init {
        val raw = readFile()
        var lines = 0
        var corrupt = 0
        var start = 0
        while (start < raw.size) {
            var end = start
            while (end < raw.size && raw[end] != NEWLINE) end++
            // JSON strings escape control characters, so a raw "\r" can only be
            // part of a CRLF line ending.
            var lineEnd = end
            if (lineEnd > start && raw[lineEnd - 1] == CARRIAGE_RETURN) lineEnd--
            if (end > start && !isBlank(raw, start, lineEnd)) {
                lines++
                val line = raw.copyOfRange(start, lineEnd)
                val event = decode(line)
                if (event != null) entries.add(Entry(event, line)) else corrupt++
            }
            start = end + 1
        }
        val overflow = entries.size - this.maxQueueSize
        if (overflow > 0) entries.subList(0, overflow).clear()

        fileLines = lines
        // A file ending mid-line must be rewritten, or the next append would be
        // glued onto the partial line.
        val cleanTail = raw.isEmpty() || raw.last() == NEWLINE
        if (corrupt > 0 || overflow > 0 || !cleanTail) rewrite()
    }

    /** Number of queued events. */
    val count: Int
        get() = synchronized(lock) { entries.size }

    /**
     * Queues [event] in memory and on disk. An event that cannot be
     * JSON-encoded (e.g. a NaN built directly as a [JsonValue]) is not queued.
     */
    fun add(event: LoopEvent) {
        val line = try {
            JsonValue.Obj(event.storageJson()).toJson().toByteArray(Charsets.UTF_8)
        } catch (e: JsonException) {
            Log.error("Dropped event \"${event.name}\": it could not be encoded as JSON (${e.message})")
            return
        }
        synchronized(lock) {
            entries.add(Entry(event, line))
            if (entries.size > maxQueueSize) {
                // Drop the oldest batch, but always keep the event just added.
                var dropped = DROP_BATCH
                if (dropped < entries.size - maxQueueSize) dropped = entries.size - maxQueueSize
                if (dropped > entries.size - 1) dropped = entries.size - 1
                entries.subList(0, dropped).clear()
                needsRewrite = true
            }
            if (file == null) return
            if (needsRewrite || fileLines + 1 > compactAt) rewrite() else append(file, line)
        }
    }

    /** Up to [n] oldest events. They are already on disk. */
    fun peek(n: Int): List<LoopEvent> = synchronized(lock) {
        entries.subList(0, minOf(maxOf(0, n), entries.size)).map { it.event }
    }

    /** Removes the events with these ids (e.g. after a successful upload). */
    fun remove(ids: Set<String>) {
        if (ids.isEmpty()) return
        synchronized(lock) {
            entries.removeAll { it.event.id in ids }
            rewrite()
        }
    }

    private fun readFile(): ByteArray {
        if (file == null || !file.exists()) return ByteArray(0)
        return try {
            file.readBytes()
        } catch (_: IOException) {
            ByteArray(0)
        } catch (_: SecurityException) {
            ByteArray(0)
        }
    }

    /** The event on [line], or null for invalid UTF-8, invalid JSON or a malformed event. */
    private fun decode(line: ByteArray): LoopEvent? = try {
        val text = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(line))
            .toString()
        LoopEvent.fromStorage(JsonValue.parseObject(text))
    } catch (_: CharacterCodingException) {
        null
    } catch (_: JsonException) {
        null
    } catch (_: MalformedEventException) {
        null
    }

    private fun append(file: File, line: ByteArray) {
        try {
            createDirectory(file)
            FileOutputStream(file, true).use { out ->
                out.write(line + NEWLINE)
                out.fd.sync()
            }
            fileLines += 1
        } catch (e: Exception) {
            // The event is still queued in memory; fix the file next time.
            Log.error("Could not append to the analytics queue file; will rewrite it on the next change: ${e.message}")
            needsRewrite = true
        }
    }

    /** Replaces the file with exactly the in-memory queue. */
    private fun rewrite() {
        val file = file ?: return
        val size = entries.sumOf { it.line.size + 1 }
        val data = ByteArray(size)
        var offset = 0
        for (entry in entries) {
            entry.line.copyInto(data, offset)
            offset += entry.line.size
            data[offset++] = NEWLINE
        }
        try {
            replaceDurably(file, data)
            fileLines = entries.size
            needsRewrite = false
        } catch (e: Exception) {
            // Covers every step of replaceDurably (directory, temp file, write,
            // rename): they throw to here, so each failure is logged once.
            Log.error(
                "Could not rewrite the analytics queue file; ${entries.size} event(s) are kept in memory: ${e.message}",
            )
            needsRewrite = true
        }
    }

    /**
     * Writes [data] to a temp file beside [file], syncs it to disk, then renames
     * it over [file], so a crash or power cut leaves either the old queue or the
     * new one, never an empty or partial file.
     */
    private fun replaceDurably(file: File, data: ByteArray) {
        createDirectory(file)
        val directory = file.absoluteFile.parentFile ?: throw IOException("The analytics queue file has no directory")
        // A fixed name: a temp file left by a crash is simply overwritten.
        val temp = File(directory, file.name + ".tmp")
        try {
            FileOutputStream(temp, false).use { out ->
                out.write(data)
                out.fd.sync()
            }
        } catch (e: Exception) {
            // Logged by rewrite(), which this throws to.
            temp.delete()
            throw e
        }
        // rename(2): atomic, and replaces the old file, on the same filesystem.
        if (!temp.renameTo(file)) {
            temp.delete()
            throw IOException("Could not rename the temporary queue file into place")
        }
        // Make the rename itself durable. Best effort: the new queue is already
        // in place, so a failure only weakens the guarantee after a power cut.
        if (!syncDirectory(directory) && !loggedDirectorySyncFailure) {
            loggedDirectorySyncFailure = true
            Log.debug("Could not sync the analytics queue directory after a rewrite; continuing without it")
        }
    }

    private fun createDirectory(file: File) {
        val directory = file.absoluteFile.parentFile ?: return
        if (!directory.isDirectory && !directory.mkdirs()) {
            throw IOException("Could not create the analytics queue directory")
        }
    }

    private fun isBlank(bytes: ByteArray, start: Int, end: Int): Boolean {
        for (index in start until end) {
            if (bytes[index] != SPACE && bytes[index] != TAB) return false
        }
        return true
    }

    companion object {
        /** How many of the oldest events are dropped when the queue is full. */
        const val DROP_BATCH = 20

        private const val NEWLINE = '\n'.code.toByte()
        private const val CARRIAGE_RETURN = '\r'.code.toByte()
        private const val SPACE = ' '.code.toByte()
        private const val TAB = '\t'.code.toByte()
    }
}

/** fsync for a directory, so a rename inside it survives a power cut. */
internal object DirectorySync {
    /** Syncs [directory]; false when it could not be opened or synced. */
    @SuppressLint("ObsoleteSdkInt") // the check tells a device from the plain JVM, not API levels apart
    fun sync(directory: File): Boolean = try {
        // SDK_INT is 0 on the plain JVM (unit tests), where android.system.Os is a stub.
        if (Build.VERSION.SDK_INT > 0) syncWithOs(directory) else syncWithFileChannel(directory)
        true
    } catch (_: Exception) {
        false
    } catch (_: LinkageError) {
        false // e.g. a platform without the API, under a test runtime
    }

    /** Android: open(2) the directory read-only and fsync(2) it. */
    private fun syncWithOs(directory: File) {
        val fd = Os.open(directory.path, OsConstants.O_RDONLY, 0)
        try {
            Os.fsync(fd)
        } finally {
            Os.close(fd)
        }
    }

    /** The JVM: a read-only channel on the directory, forced. */
    @SuppressLint("NewApi") // never runs on Android; see sync()
    private fun syncWithFileChannel(directory: File) {
        FileChannel.open(directory.toPath(), StandardOpenOption.READ).use { it.force(true) }
    }
}
