package io.loop.analytics

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/** Kotlin-only: the hand-rolled JSON codec that replaces Swift's JSONEncoder/JSONDecoder. */
class JsonValueTest {
    @Test
    fun strings_escape_quotes_backslashes_and_control_characters_but_not_slashes() {
        val value = JsonValue.Str("a/b\"c\\d\n\r\t\b\u000C\u0001\u001F\u007F\u2028é😀")
        val text = value.toJson()
        assertEquals("\"a/b\\\"c\\\\d\\n\\r\\t\\b\\f\\u0001\\u001f\u007F\u2028é😀\"", text)
        assertEquals(value, JsonValue.fromJson(text))
        // An independent parser agrees.
        assertEquals(value.value, JSONArray("[$text]").getString(0))
    }

    @Test
    fun lone_surrogates_are_written_as_the_replacement_character() {
        // As Swift (whose strings cannot hold them) does: never a \uD800-style escape.
        val text = JsonValue.Str("x\uD800y\uDC00z\uDBFF").toJson()
        assertEquals("\"x\uFFFDy\uFFFDz\uFFFD\"", text)
        assertEquals(JsonValue.Str("x\uFFFDy\uFFFDz\uFFFD"), JsonValue.fromJson(text))
    }

    @Test
    fun unpaired_surrogate_escapes_read_as_the_replacement_character() {
        assertEquals(JsonValue.Str("\uFFFDx"), JsonValue.fromJson(""""\ud800x""""))
        assertEquals(JsonValue.Str("\uFFFD"), JsonValue.fromJson(""""\udc00""""))
        assertEquals(JsonValue.Str("\uFFFDA"), JsonValue.fromJson(""""\ud800\u0041""""))
        assertEquals(JsonValue.Str("\uFFFD\uFFFD"), JsonValue.fromJson(""""\udc00\ud800""""))
        assertEquals(JsonValue.Str("\uFFFD😀"), JsonValue.fromJson(""""\ud800\ud83d\ude00""""))
        // Raw (unescaped) lone surrogates in the text are treated the same way.
        assertEquals(JsonValue.Str("\uFFFDa\uFFFD"), JsonValue.fromJson("\"\uD800a\uDC00\""))
        assertEquals(JsonValue.Str("😀"), JsonValue.fromJson("\"😀\""))
    }

    @Test
    fun parses_escapes_and_surrogate_pairs() {
        assertEquals(
            JsonValue.Str("/\"\\\b\u000C\n\r\t\u00e9😀"),
            JsonValue.fromJson(""""\/\"\\\b\f\n\r\t\u00E9\ud83d\ude00""""),
        )
    }

    @Test
    fun numbers_keep_ints_and_doubles_apart() {
        assertEquals(JsonValue.IntV(Long.MAX_VALUE), JsonValue.fromJson("9223372036854775807"))
        assertEquals(JsonValue.IntV(Long.MIN_VALUE), JsonValue.fromJson("-9223372036854775808"))
        assertEquals(JsonValue.Num(9.223372036854775808E18), JsonValue.fromJson("9223372036854775808"))
        assertEquals(JsonValue.Num(1.5), JsonValue.fromJson("1.5"))
        assertEquals(JsonValue.Num(-2.5E-7), JsonValue.fromJson("-2.5e-7"))
        assertEquals(JsonValue.Num(100.0), JsonValue.fromJson("1E2"))
        assertEquals(JsonValue.Num(1.0), JsonValue.fromJson("1.0"))
        assertEquals(JsonValue.IntV(0), JsonValue.fromJson("-0"))
    }

    @Test
    fun doubles_encode_as_the_shortest_round_tripping_form() {
        assertEquals("1.5", JsonValue.Num(1.5).toJson())
        assertEquals("0.30000000000000004", JsonValue.Num(0.1 + 0.2).toJson())
        // Like Swift's JSONEncoder, an integral double has no ".0".
        assertEquals("100", JsonValue.Num(100.0).toJson())
        for (d in listOf(1e20, 1e-5, -0.0, Double.MIN_VALUE, Double.MAX_VALUE, 123456789.125)) {
            val text = JsonValue.Num(d).toJson()
            assertEquals(text, d, JSONArray("[$text]").getDouble(0), 0.0)
            assertEquals(text, d, numberValue(JsonValue.fromJson(text)), 0.0)
        }
    }

    private fun numberValue(value: JsonValue): Double = when (value) {
        is JsonValue.Num -> value.value
        is JsonValue.IntV -> value.value.toDouble()
        else -> throw AssertionError("not a number: $value")
    }

    @Test
    fun non_finite_numbers_cannot_be_encoded() {
        for (d in listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY)) {
            assertThrows(JsonException::class.java) { JsonValue.Arr(listOf(JsonValue.Num(d))).toJson() }
        }
    }

    @Test
    fun objects_keep_insertion_order_and_the_last_duplicate_key_wins() {
        val value = JsonValue.fromJson(""" { "b" : 1 , "a" : [ true , false , null ] , "b" : 2 } """)
        assertEquals(
            JsonValue.Obj(mapOf("b" to JsonValue.IntV(2), "a" to JsonValue.Arr(listOf(JsonValue.Bool(true), JsonValue.Bool(false), JsonValue.Null))))
                .toJson(),
            value.toJson(),
        )
        assertEquals("""{"x":{},"y":[]}""", JsonValue.fromJson("""{"x":{},"y":[]}""").toJson())
    }

    @Test
    fun rejects_invalid_json() {
        val invalid = listOf(
            "", " ", "{", "[1,]", "{\"a\":1,}", "01", "1.", ".5", "1e", "+1", "-", "NaN", "Infinity",
            "tru", "nul", "\"unterminated", "\"bad \\x escape\"", "\"\\u12G4\"", "\"raw \n newline\"",
            "{1:2}", "{\"a\" 1}", "[1 2]", "1 2", "{} x", "'s'",
        )
        for (text in invalid) {
            assertThrows(text, JsonException::class.java) { JsonValue.fromJson(text) }
        }
    }

    @Test
    fun deep_nesting_is_rejected_instead_of_overflowing_the_stack() {
        assertThrows(JsonException::class.java) { JsonValue.fromJson("[".repeat(100_000)) }
        assertEquals(JsonValue.Arr(listOf(JsonValue.Arr(emptyList()))), JsonValue.fromJson("[[]]"))
    }

    @Test
    fun parse_object_requires_an_object() {
        assertEquals(mapOf("a" to JsonValue.IntV(1)), JsonValue.parseObject("""{"a":1}"""))
        assertThrows(JsonException::class.java) { JsonValue.parseObject("[1]") }
    }
}
