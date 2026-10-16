package io.loop.core

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream

/** gzip (RFC 1952) compression. */
@InternalLoopApi
public object Gzip {
    private const val BUFFER_SIZE = 64 * 1024

    public fun compress(data: ByteArray): ByteArray {
        val out = ByteArrayOutputStream(data.size / 2 + 32)
        GZIPOutputStream(out, BUFFER_SIZE).use { it.write(data) }
        return out.toByteArray()
    }

    /** Used by tests to check the wire bytes. Throws [IOException] if [data] is not valid gzip. */
    @Throws(IOException::class)
    public fun decompress(data: ByteArray): ByteArray =
        GZIPInputStream(ByteArrayInputStream(data), BUFFER_SIZE).use { it.readBytes() }
}
