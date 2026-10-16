package io.loop.analytics

import org.json.JSONArray
import org.json.JSONObject
import java.math.BigDecimal
import java.math.BigInteger
import java.util.Date

/** Event-name validation and property sanitising. */
internal object Sanitize {
    /** Server limit on event names (after trimming). */
    const val MAX_NAME = 128

    /**
     * True when [name] is accepted by the server: 1–128 characters once trimmed
     * (counted in UTF-16 code units, as the reference SDK does). The name
     * itself is sent verbatim; it is never rewritten.
     */
    fun isValidEventName(name: String): Boolean {
        val trimmed = trimWhitespace(name)
        return trimmed.isNotEmpty() && trimmed.length <= MAX_NAME
    }

    /**
     * Makes event/user properties safe to JSON-encode.
     *
     * Null values (`null`, [JsonValue.Null], `JSONObject.NULL`) are stripped
     * from maps; lists keep their positions. org.json's `JSONObject` and
     * `JSONArray` become objects and arrays. Strings, booleans, finite numbers, collections, arrays
     * and maps pass through; map keys become strings, [Date] and
     * `java.time.Instant` (also desugared) become ISO 8601 UTC strings, non-finite numbers
     * become `"nan"`, `"inf"` or `"-inf"` (as on iOS), and anything else its
     * `toString()`. Nothing is truncated.
     */
    fun props(props: Map<String, Any?>?): JsonObject {
        if (props == null) return emptyMap()
        val out = LinkedHashMap<String, JsonValue>()
        for ((key, value) in props) {
            val sanitized = sanitize(value)
            if (sanitized != JsonValue.Null) out[key] = sanitized
        }
        return out
    }

    /**
     * [value] without leading and trailing white space as Swift's
     * `.whitespacesAndNewlines` defines it (Unicode White_Space), so names and
     * ids are judged the same on both platforms.
     */
    fun trimWhitespace(value: String): String {
        var start = 0
        var end = value.length
        while (start < end && isWhitespace(value[start])) start++
        while (end > start && isWhitespace(value[end - 1])) end--
        return value.substring(start, end)
    }

    private fun isWhitespace(char: Char): Boolean = when (char) {
        in '\u0009'..'\u000D', ' ', '\u0085', ' ', ' ', in ' '..' ',
        ' ', ' ', ' ', ' ', '　' -> true
        else -> false
    }

    private fun sanitize(value: Any?): JsonValue = when (value) {
        null -> JsonValue.Null
        JSONObject.NULL -> JsonValue.Null
        is JsonValue -> sanitizeJson(value)
        // org.json (part of Android): before Iterable, which the JVM library's JSONArray implements.
        is JSONObject -> {
            val out = LinkedHashMap<String, JsonValue>()
            for (key in value.keys()) {
                val sanitized = sanitize(value.opt(key))
                if (sanitized != JsonValue.Null) out[key] = sanitized
            }
            JsonValue.Obj(out)
        }
        is JSONArray -> JsonValue.Arr((0 until value.length()).map { sanitize(value.opt(it)) })
        is String -> JsonValue.Str(value)
        is Boolean -> JsonValue.Bool(value)
        is Int -> JsonValue.IntV(value.toLong())
        is Long -> JsonValue.IntV(value)
        is Short -> JsonValue.IntV(value.toLong())
        is Byte -> JsonValue.IntV(value.toLong())
        is Double -> doubleValue(value)
        // Via the shortest decimal form so 9.99f stays 9.99, not 9.989999771118164.
        is Float -> if (value.isNaN() || value.isInfinite()) doubleValue(value.toDouble()) else JsonValue.Num(value.toString().toDouble())
        is BigInteger -> if (value.bitLength() < 64) JsonValue.IntV(value.toLong()) else doubleValue(value.toDouble())
        is BigDecimal -> doubleValue(value.toDouble())
        is UByte -> JsonValue.IntV(value.toLong())
        is UShort -> JsonValue.IntV(value.toLong())
        is UInt -> JsonValue.IntV(value.toLong())
        is ULong -> if (value <= Long.MAX_VALUE.toULong()) JsonValue.IntV(value.toLong()) else doubleValue(value.toDouble())
        is Date -> JsonValue.Str(LoopTimestamp.format(value.time))
        is Map<*, *> -> {
            val out = LinkedHashMap<String, JsonValue>()
            for ((key, element) in value) {
                val sanitized = sanitize(element)
                if (sanitized != JsonValue.Null) out[key.toString()] = sanitized
            }
            JsonValue.Obj(out)
        }
        is Iterable<*> -> JsonValue.Arr(value.map(::sanitize))
        is Array<*> -> JsonValue.Arr(value.map(::sanitize))
        is IntArray -> JsonValue.Arr(value.map(::sanitize))
        is LongArray -> JsonValue.Arr(value.map(::sanitize))
        is ShortArray -> JsonValue.Arr(value.map(::sanitize))
        is ByteArray -> JsonValue.Arr(value.map(::sanitize))
        is DoubleArray -> JsonValue.Arr(value.map(::sanitize))
        is FloatArray -> JsonValue.Arr(value.map(::sanitize))
        is BooleanArray -> JsonValue.Arr(value.map(::sanitize))
        is CharArray -> JsonValue.Arr(value.map(::sanitize))
        else -> instantValue(value) ?: JsonValue.Str(value.toString())
    }

    /** A [JsonValue] under the same rules: nulls stripped from objects (kept in arrays), non-finite numbers stringified. */
    private fun sanitizeJson(json: JsonValue): JsonValue = when (json) {
        is JsonValue.Num -> doubleValue(json.value)
        is JsonValue.Arr -> JsonValue.Arr(json.values.map(::sanitizeJson))
        is JsonValue.Obj -> {
            val out = LinkedHashMap<String, JsonValue>()
            for ((key, element) in json.values) {
                val sanitized = sanitizeJson(element)
                if (sanitized != JsonValue.Null) out[key] = sanitized
            }
            JsonValue.Obj(out)
        }
        is JsonValue.Str, is JsonValue.IntV, is JsonValue.Bool, JsonValue.Null -> json
    }

    /** Finite doubles as numbers; NaN and infinities spelled as Swift prints them. */
    private fun doubleValue(value: Double): JsonValue = when {
        value.isNaN() -> JsonValue.Str("nan")
        value == Double.POSITIVE_INFINITY -> JsonValue.Str("inf")
        value == Double.NEGATIVE_INFINITY -> JsonValue.Str("-inf")
        else -> JsonValue.Num(value)
    }

    /**
     * The instant classes, by name: `java.time.Instant` exists only from API
     * 26, and core-library desugaring rewrites an app's uses of it to
     * `j$.time.Instant` below that. Neither can be referenced in an `is`
     * check, so both are recognised by class name (each is final).
     */
    private val instantClassNames = setOf("java.time.Instant", "j\$.time.Instant")

    /** An instant as a millisecond ISO 8601 string; null if [value] is no instant. */
    private fun instantValue(value: Any): JsonValue? {
        if (value.javaClass.name !in instantClassNames) return null
        val millis = try {
            value.javaClass.getMethod("toEpochMilli").invoke(value) as Long
        } catch (_: ReflectiveOperationException) {
            // Beyond the range of epoch milliseconds (an ArithmeticException,
            // wrapped), or the method was shrunk away: its own ISO 8601 form.
            return JsonValue.Str(value.toString())
        }
        return JsonValue.Str(LoopTimestamp.format(millis))
    }
}
