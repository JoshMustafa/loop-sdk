package io.loop.analytics

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLConnection
import java.util.Locale

/**
 * Sends one HTTP POST. Returns the status code, the response headers with
 * lower-cased names, and the body. Throws on network errors and timeouts.
 */
internal fun interface AnalyticsTransport {
    suspend fun send(url: String, headers: Map<String, String>, body: ByteArray): TransportResponse
}

/** An HTTP response. [headers] names are lower-cased. */
internal data class TransportResponse(
    val status: Int,
    val headers: Map<String, String>,
    val body: ByteArray,
)

/**
 * The production transport over [HttpURLConnection], run on [Dispatchers.IO],
 * with connect and read timeouts of [timeoutMillis] (30 s by default). A
 * timeout surfaces as a `SocketTimeoutException`.
 */
internal class HttpUrlConnectionTransport(
    val timeoutMillis: Int = DEFAULT_TIMEOUT_MILLIS,
    /** Opens the connection; a test seam. */
    private val open: (URL) -> URLConnection = { it.openConnection() },
) : AnalyticsTransport {
    override suspend fun send(url: String, headers: Map<String, String>, body: ByteArray): TransportResponse =
        withContext(Dispatchers.IO) {
            val connection = open(URL(url)) as HttpURLConnection
            try {
                connection.requestMethod = "POST"
                connection.connectTimeout = timeoutMillis
                connection.readTimeout = timeoutMillis
                connection.useCaches = false
                connection.doOutput = true
                // A fixed-length stream is never silently re-sent by the JVM's
                // HttpURLConnection after a failure.
                connection.setFixedLengthStreamingMode(body.size)
                for ((name, value) in headers) connection.setRequestProperty(name, value)
                connection.outputStream.use { it.write(body) }

                val status = connection.responseCode
                val responseHeaders = LinkedHashMap<String, String>()
                for ((name, values) in connection.headerFields) {
                    // The status line is listed under a null name.
                    if (name == null) continue
                    responseHeaders[name.lowercase(Locale.ROOT)] = values.joinToString(", ")
                }
                // Read to the end and closed, but never disconnect()ed: that
                // returns the connection to the keep-alive pool, so the next
                // batch skips a new TCP and TLS handshake.
                val stream: InputStream? = if (status >= 400) connection.errorStream else connection.inputStream
                val responseBody = stream?.use { it.readBytes() } ?: ByteArray(0)
                TransportResponse(status, responseHeaders, responseBody)
            } catch (e: Exception) {
                // A failed connection is not reused; release it now.
                connection.disconnect()
                throw e
            }
        }

    companion object {
        /** Connect and read timeout, in milliseconds. */
        const val DEFAULT_TIMEOUT_MILLIS = 30_000
    }
}
