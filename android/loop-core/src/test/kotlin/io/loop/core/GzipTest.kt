package io.loop.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class GzipTest {
    @Test
    fun round_trip_and_gzip_magic_bytes() {
        val input = "hello loop ".repeat(500).toByteArray(Charsets.UTF_8)
        val zipped = Gzip.compress(input)
        assertEquals(0x1f.toByte(), zipped[0])
        assertEquals(0x8b.toByte(), zipped[1])
        assertTrue(zipped.size < input.size)
        assertArrayEquals(input, Gzip.decompress(zipped))
    }

    @Test
    fun round_trip_of_incompressible_data_spanning_many_output_chunks() {
        // 300 KB from a seeded xorshift generator: barely compressible, so both
        // compress and decompress go through their buffers several times.
        var state = 0x9E37_79B9_7F4A_7C15uL.toLong()
        val input = ByteArray(300 * 1024)
        for (i in input.indices) {
            state = state xor (state shl 13)
            state = state xor (state ushr 7)
            state = state xor (state shl 17)
            input[i] = state.toByte()
        }
        val zipped = Gzip.compress(input)
        assertTrue("compressed output should span several chunks", zipped.size > 64 * 1024)
        assertArrayEquals(input, Gzip.decompress(zipped))
    }

    @Test
    fun round_trip_of_empty_input() {
        assertArrayEquals(ByteArray(0), Gzip.decompress(Gzip.compress(ByteArray(0))))
    }

    @Test(expected = java.io.IOException::class)
    fun decompress_rejects_data_that_is_not_gzip() {
        Gzip.decompress("not gzip".toByteArray())
    }
}
