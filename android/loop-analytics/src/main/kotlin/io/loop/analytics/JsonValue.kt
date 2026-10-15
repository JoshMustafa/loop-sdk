package io.loop.analytics

/** A JSON object: event props, user properties, the context snapshot. */
internal typealias JsonObject = Map<String, JsonValue>

/** JSON that could not be read, or a value that cannot be written as JSON. */
internal class JsonException(message: String) : Exception(message)

/**
 * A JSON value. Integers and doubles are kept apart so `1` is written as `1`,
 * never `1.0`.
 *
 * The codec is hand-rolled (no org.json) so JVM unit tests and devices behave
 * the same. Output is compact, keeps map insertion order and does not escape
 * `/`.
 */
internal sealed interface JsonValue {
    data class Str(val value: String) : JsonValue
    data class IntV(val value: Long) : JsonValue
    data class Num(val value: Double) : JsonValue
    data class Bool(val value: Boolean) : JsonValue
    data object Null : JsonValue
    data class Arr(val values: List<JsonValue>) : JsonValue
    data class Obj(val values: JsonObject) : JsonValue

    /** Compact JSON text. Throws [JsonException] for a NaN or infinite number. */
    fun toJson(): String = StringBuilder().also { JsonWriter.write(this, it) }.toString()

    companion object {
        /** Parses one JSON value (RFC 8259). Throws [JsonException] on invalid input. */
        fun fromJson(text: String): JsonValue = JsonReader(text).readDocument()

        /** Parses a JSON object. Throws [JsonException] on invalid input or another kind of value. */
        fun parseObject(text: String): JsonObject =
            (fromJson(text) as? Obj)?.values ?: throw JsonException("Not a JSON object")
    }
}

/** U+FFFD, written and read in place of an unpaired surrogate. */
private const val REPLACEMENT = '\uFFFD'

private object JsonWriter {
    private const val HEX = "0123456789abcdef"

    fun write(value: JsonValue, out: StringBuilder) {
        when (value) {
            is JsonValue.Str -> writeString(value.value, out)
            is JsonValue.IntV -> out.append(value.value)
            is JsonValue.Num -> out.append(formatDouble(value.value))
            is JsonValue.Bool -> out.append(value.value)
            JsonValue.Null -> out.append("null")
            is JsonValue.Arr -> {
                out.append('[')
                value.values.forEachIndexed { index, element ->
                    if (index > 0) out.append(',')
                    write(element, out)
                }
                out.append(']')
            }
            is JsonValue.Obj -> {
                out.append('{')
                var first = true
                for ((key, element) in value.values) {
                    if (!first) out.append(',')
                    first = false
                    writeString(key, out)
                    out.append(':')
                    write(element, out)
                }
                out.append('}')
            }
        }
    }

    /** Shortest round-tripping form; an integral value drops its ".0" as Swift's JSONEncoder does. */
    private fun formatDouble(value: Double): String {
        if (value.isNaN() || value.isInfinite()) throw JsonException("A number is not finite")
        val text = value.toString()
        return if (text.endsWith(".0")) text.substring(0, text.length - 2) else text
    }

    private fun writeString(value: String, out: StringBuilder) {
        out.append('"')
        var index = 0
        while (index < value.length) {
            val char = value[index]
            when {
                char == '"' -> out.append("\\\"")
                char == '\\' -> out.append("\\\\")
                char == '\n' -> out.append("\\n")
                char == '\r' -> out.append("\\r")
                char == '\t' -> out.append("\\t")
                char == '\b' -> out.append("\\b")
                char == '\u000C' -> out.append("\\f")
                char < ' ' -> escape(char, out)
                char.isHighSurrogate() && index + 1 < value.length && value[index + 1].isLowSurrogate() -> {
                    out.append(char).append(value[index + 1])
                    index++
                }
                // A lone surrogate has no UTF-8 form. Swift strings cannot hold one, so
                // write what they would: the replacement character.
                char.isSurrogate() -> out.append(REPLACEMENT)
                else -> out.append(char)
            }
            index++
        }
        out.append('"')
    }

    private fun escape(char: Char, out: StringBuilder) {
        val code = char.code
        out.append("\\u")
            .append(HEX[code shr 12 and 0xF])
            .append(HEX[code shr 8 and 0xF])
            .append(HEX[code shr 4 and 0xF])
            .append(HEX[code and 0xF])
    }
}

/** Strict recursive-descent parser. Messages give positions only, never content. */
private class JsonReader(private val text: String) {
    private var pos = 0
    private var depth = 0

    fun readDocument(): JsonValue {
        skipWhitespace()
        val value = readValue()
        skipWhitespace()
        if (pos != text.length) fail("Unexpected content")
        return value
    }

    private fun readValue(): JsonValue {
        if (pos >= text.length) fail("Unexpected end of input")
        return when (text[pos]) {
            '{' -> readObject()
            '[' -> readArray()
            '"' -> JsonValue.Str(readString())
            't' -> readLiteral("true", JsonValue.Bool(true))
            'f' -> readLiteral("false", JsonValue.Bool(false))
            'n' -> readLiteral("null", JsonValue.Null)
            '-', in '0'..'9' -> readNumber()
            else -> fail("Unexpected character")
        }
    }

    private fun readObject(): JsonValue {
        enter()
        pos++ // {
        val values = LinkedHashMap<String, JsonValue>()
        skipWhitespace()
        if (peek() == '}') {
            pos++
            depth--
            return JsonValue.Obj(values)
        }
        while (true) {
            if (peek() != '"') fail("Expected a key")
            val key = readString()
            skipWhitespace()
            expect(':')
            skipWhitespace()
            values[key] = readValue()
            skipWhitespace()
            when (peek()) {
                ',' -> {
                    pos++
                    skipWhitespace()
                }
                '}' -> {
                    pos++
                    depth--
                    return JsonValue.Obj(values)
                }
                else -> fail("Expected ',' or '}'")
            }
        }
    }

    private fun readArray(): JsonValue {
        enter()
        pos++ // [
        val values = ArrayList<JsonValue>()
        skipWhitespace()
        if (peek() == ']') {
            pos++
            depth--
            return JsonValue.Arr(values)
        }
        while (true) {
            values.add(readValue())
            skipWhitespace()
            when (peek()) {
                ',' -> {
                    pos++
                    skipWhitespace()
                }
                ']' -> {
                    pos++
                    depth--
                    return JsonValue.Arr(values)
                }
                else -> fail("Expected ',' or ']'")
            }
        }
    }

    /**
     * Reads a string. An unpaired surrogate, escaped or raw, becomes U+FFFD so
     * the result always has a UTF-8 form.
     */
    private fun readString(): String {
        pos++ // opening quote
        val out = StringBuilder()
        while (true) {
            if (pos >= text.length) fail("Unterminated string")
            val char = text[pos++]
            when {
                char == '"' -> return out.toString()
                char == '\\' -> {
                    if (pos >= text.length) fail("Unterminated string")
                    when (text[pos++]) {
                        '"' -> out.append('"')
                        '\\' -> out.append('\\')
                        '/' -> out.append('/')
                        'b' -> out.append('\b')
                        'f' -> out.append('\u000C')
                        'n' -> out.append('\n')
                        'r' -> out.append('\r')
                        't' -> out.append('\t')
                        'u' -> appendCodeUnit(readHex4(), out, escaped = true)
                        else -> fail("Invalid escape")
                    }
                }
                char < ' ' -> fail("Unescaped control character")
                else -> appendCodeUnit(char, out, escaped = false)
            }
        }
    }

    /**
     * Appends [char], pairing a high surrogate with a low one that follows in
     * the same form (`\uXXXX` escape when [escaped], else raw).
     */
    private fun appendCodeUnit(char: Char, out: StringBuilder, escaped: Boolean) {
        when {
            char.isHighSurrogate() -> {
                val low = if (escaped) peekEscapedLowSurrogate() else peekRawLowSurrogate()
                if (low == null) {
                    out.append(REPLACEMENT)
                } else {
                    out.append(char).append(low)
                    pos += if (escaped) 6 else 1
                }
            }
            char.isLowSurrogate() -> out.append(REPLACEMENT)
            else -> out.append(char)
        }
    }

    /** The low surrogate of a `\uXXXX` escape at [pos], without consuming it, or null. */
    private fun peekEscapedLowSurrogate(): Char? {
        if (pos + 6 > text.length || text[pos] != '\\' || text[pos + 1] != 'u') return null
        var code = 0
        for (index in pos + 2 until pos + 6) {
            val digit = Character.digit(text[index], 16)
            if (digit < 0) return null
            code = code * 16 + digit
        }
        return code.toChar().takeIf { it.isLowSurrogate() }
    }

    private fun peekRawLowSurrogate(): Char? = text.getOrNull(pos)?.takeIf { it.isLowSurrogate() }

    private fun readHex4(): Char {
        if (pos + 4 > text.length) fail("Invalid unicode escape")
        var code = 0
        repeat(4) {
            val digit = Character.digit(text[pos++], 16)
            if (digit < 0) fail("Invalid unicode escape")
            code = code * 16 + digit
        }
        return code.toChar()
    }

    private fun readNumber(): JsonValue {
        val start = pos
        if (peek() == '-') pos++
        when {
            peek() == '0' -> pos++
            isDigit(peek()) -> skipDigits()
            else -> fail("Invalid number")
        }
        var integral = true
        if (peek() == '.') {
            pos++
            if (!isDigit(peek())) fail("Invalid number")
            skipDigits()
            integral = false
        }
        if (peek() == 'e' || peek() == 'E') {
            pos++
            if (peek() == '+' || peek() == '-') pos++
            if (!isDigit(peek())) fail("Invalid number")
            skipDigits()
            integral = false
        }
        val token = text.substring(start, pos)
        if (integral) token.toLongOrNull()?.let { return JsonValue.IntV(it) }
        val value = token.toDouble()
        if (value.isInfinite()) fail("Number out of range")
        return JsonValue.Num(value)
    }

    private fun readLiteral(literal: String, value: JsonValue): JsonValue {
        if (!text.startsWith(literal, pos)) fail("Invalid literal")
        pos += literal.length
        return value
    }

    private fun enter() {
        if (++depth > MAX_DEPTH) fail("Too deeply nested")
    }

    private fun skipDigits() {
        while (isDigit(peek())) pos++
    }

    private fun skipWhitespace() {
        while (pos < text.length) {
            when (text[pos]) {
                ' ', '\t', '\n', '\r' -> pos++
                else -> return
            }
        }
    }

    private fun expect(char: Char) {
        if (peek() != char) fail("Expected '$char'")
        pos++
    }

    /** The current character, or NUL at the end of input. */
    private fun peek(): Char = if (pos < text.length) text[pos] else '\u0000'

    private fun isDigit(char: Char) = char in '0'..'9'

    private fun fail(reason: String): Nothing = throw JsonException("$reason at offset $pos")

    private companion object {
        /** Same nesting limit as Foundation's JSON parser. */
        const val MAX_DEPTH = 512
    }
}
