package io.loop.analytics

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.math.BigInteger
import java.net.URI
import java.time.Instant
import java.util.Date

class SanitizeTest {
    // props

    @Test
    fun strips_null_values_and_keeps_json_values_incl_lists_and_maps() {
        val out = Sanitize.props(
            mapOf(
                "a" to null,
                "b" to 1,
                "c" to 2.5,
                "d" to true,
                "e" to "x",
                "foods" to listOf("apple", 1, null),
                "nested" to mapOf("k" to "v", "gone" to null),
            ),
        )
        assertEquals(
            mapOf(
                "b" to JsonValue.IntV(1),
                "c" to JsonValue.Num(2.5),
                "d" to JsonValue.Bool(true),
                "e" to JsonValue.Str("x"),
                "foods" to JsonValue.Arr(listOf(JsonValue.Str("apple"), JsonValue.IntV(1), JsonValue.Null)),
                "nested" to JsonValue.Obj(mapOf("k" to JsonValue.Str("v"))),
            ),
            out,
        )
    }

    @Test
    fun stringifies_values_that_are_not_json_encodable() {
        val thing = object {
            override fun toString() = "Thing!"
        }
        val out = Sanitize.props(
            mapOf(
                "when" to Date(1_791_968_400_000), // 2026-10-14T09:00:00Z
                "obj" to thing,
                "nan" to Double.NaN,
                "set" to setOf(1, 2),
                "intKeys" to mapOf(1 to "one"),
            ),
        )
        assertEquals(JsonValue.Str("2026-10-14T09:00:00.000Z"), out["when"])
        assertEquals(JsonValue.Str("Thing!"), out["obj"])
        assertEquals(JsonValue.Str("nan"), out["nan"])
        val set = out["set"] as? JsonValue.Arr ?: return fail("set is not an array: ${out["set"]}")
        assertEquals(2, set.values.size) // a Set has no order
        assertTrue(JsonValue.IntV(1) in set.values && JsonValue.IntV(2) in set.values)
        assertEquals(JsonValue.Obj(mapOf("1" to JsonValue.Str("one"))), out["intKeys"])
        JsonValue.Obj(out).toJson() // does not throw
    }

    @Test
    fun does_not_truncate_strings_or_cap_the_number_of_keys() {
        val long = "x".repeat(5000)
        val many = HashMap<String, Any>()
        for (i in 0 until 1500) many["k$i"] = i
        val out = Sanitize.props(mapOf("long" to long, "many" to many, "list" to listOf(long)))
        assertEquals(JsonValue.Str(long), out["long"])
        val manyOut = out["many"] as? JsonValue.Obj ?: return fail("many is not an object")
        assertEquals(1500, manyOut.values.size)
        assertEquals(JsonValue.Arr(listOf(JsonValue.Str(long))), out["list"])
    }

    @Test
    fun null_input_gives_an_empty_map() {
        assertEquals(emptyMap<String, JsonValue>(), Sanitize.props(null))
    }

    @Test
    fun sanitize_converts_non_json_values() {
        val custom = object {
            override fun toString() = "custom!"
        }
        val out = Sanitize.props(
            mapOf(
                "d" to Date(1_767_225_600_000),
                "u" to URI("https://x.test"),
                "c" to custom,
                "n" to Double.NaN,
                "i" to 3,
                "f" to 1.5,
                "nil" to null,
            ),
        )
        assertEquals(JsonValue.Str("2026-01-01T00:00:00.000Z"), out["d"])
        assertEquals(JsonValue.Str("https://x.test"), out["u"])
        assertEquals(JsonValue.Str("custom!"), out["c"])
        assertEquals(JsonValue.Str("nan"), out["n"])
        assertEquals(JsonValue.IntV(3), out["i"])
        assertEquals(JsonValue.Num(1.5), out["f"])
        assertFalse(out.containsKey("nil"))
    }

    /** Port of `test_bools_stay_bools_including_bridged_ns_numbers`: boxed Java values and org.json values passed straight in. */
    @Test
    fun bools_stay_bools_including_boxed_java_values() {
        val json = JSONObject(
            """{"t":true,"one":1,"half":0.5,"none":null,"nested":{"k":"v","gone":null},"list":[1,null,{"a":2}]}""",
        )
        val out = Sanitize.props(
            mapOf(
                "kotlinBool" to false,
                "javaBool" to java.lang.Boolean.valueOf(true),
                "javaInt" to Integer.valueOf(1),
                "javaDouble" to java.lang.Double.valueOf(2.5),
                "json" to json,
                "jsonNull" to JSONObject.NULL,
            ),
        )
        assertEquals(JsonValue.Bool(false), out["kotlinBool"])
        assertEquals(JsonValue.Bool(true), out["javaBool"])
        assertEquals(JsonValue.IntV(1), out["javaInt"])
        assertEquals(JsonValue.Num(2.5), out["javaDouble"])
        assertEquals(
            JsonValue.Obj(
                mapOf(
                    "t" to JsonValue.Bool(true),
                    "one" to JsonValue.IntV(1),
                    "half" to JsonValue.Num(0.5),
                    "nested" to JsonValue.Obj(mapOf("k" to JsonValue.Str("v"))),
                    "list" to JsonValue.Arr(
                        listOf(JsonValue.IntV(1), JsonValue.Null, JsonValue.Obj(mapOf("a" to JsonValue.IntV(2)))),
                    ),
                ),
            ),
            out["json"],
        )
        // org.json's NULL is a null, so it is stripped from maps.
        assertFalse(out.containsKey("jsonNull"))
    }

    /** Port of `test_optionals_nested_in_any_are_unwrapped_or_stripped`. */
    @Test
    fun nullable_values_are_kept_or_stripped() {
        val some: Int? = 7
        val none: String? = null
        val out = Sanitize.props(mapOf("some" to some, "none" to none, "list" to listOf(some, none)))
        assertEquals(JsonValue.IntV(7), out["some"])
        assertNull(out["none"])
        assertEquals(JsonValue.Arr(listOf(JsonValue.IntV(7), JsonValue.Null)), out["list"])
    }

    @Test
    fun json_value_input_is_sanitised_like_any_other_value() {
        assertEquals(
            mapOf("o" to JsonValue.Obj(mapOf("b" to JsonValue.IntV(1)))),
            Sanitize.props(mapOf("o" to JsonValue.Obj(mapOf("a" to JsonValue.Null, "b" to JsonValue.IntV(1))))),
        )
        val out = Sanitize.props(
            mapOf(
                "list" to JsonValue.Arr(
                    listOf(
                        JsonValue.Null,
                        JsonValue.Num(Double.NaN),
                        JsonValue.Obj(mapOf("gone" to JsonValue.Null, "deep" to JsonValue.Arr(listOf(JsonValue.Null)))),
                    ),
                ),
                "inf" to JsonValue.Num(Double.POSITIVE_INFINITY),
                "null" to JsonValue.Null,
            ),
        )
        assertEquals(
            mapOf(
                "list" to JsonValue.Arr(
                    listOf(
                        JsonValue.Null,
                        JsonValue.Str("nan"),
                        JsonValue.Obj(mapOf("deep" to JsonValue.Arr(listOf(JsonValue.Null)))),
                    ),
                ),
                "inf" to JsonValue.Str("inf"),
            ),
            out,
        )
    }

    @Test
    fun infinite_numbers_are_stringified() {
        val out = Sanitize.props(
            mapOf("inf" to Double.POSITIVE_INFINITY, "ninf" to Double.NEGATIVE_INFINITY, "f" to Float.NaN),
        )
        assertEquals(JsonValue.Str("inf"), out["inf"])
        assertEquals(JsonValue.Str("-inf"), out["ninf"])
        assertEquals(JsonValue.Str("nan"), out["f"])
    }

    /** Kotlin-only: the number, date and array types the Swift tests cover with Swift types. */
    @Test
    fun kotlin_numbers_instants_and_arrays_are_converted() {
        val out = Sanitize.props(
            mapOf(
                "long" to 9_007_199_254_740_993L,
                "short" to 3.toShort(),
                "byte" to (-4).toByte(),
                "float" to 9.99f,
                "big" to BigInteger("123456789012345678901234567890"),
                "smallBig" to BigInteger.valueOf(42),
                "uint" to 7u,
                "ulong" to ULong.MAX_VALUE,
                "instant" to Instant.ofEpochMilli(1_791_969_118_402),
                "preEpoch" to Instant.ofEpochMilli(-1),
                "ints" to intArrayOf(1, 2),
                "doubles" to doubleArrayOf(0.5),
                "bools" to booleanArrayOf(true),
                "objects" to arrayOf("a", null),
                "sequence" to Iterable { listOf(1).iterator() },
            ),
        )
        assertEquals(JsonValue.IntV(9_007_199_254_740_993L), out["long"])
        assertEquals(JsonValue.IntV(3), out["short"])
        assertEquals(JsonValue.IntV(-4), out["byte"])
        assertEquals(JsonValue.Num(9.99), out["float"])
        assertEquals(JsonValue.Num(1.2345678901234568E29), out["big"])
        assertEquals(JsonValue.IntV(42), out["smallBig"])
        assertEquals(JsonValue.IntV(7), out["uint"])
        assertEquals(JsonValue.Num(1.8446744073709552E19), out["ulong"])
        assertEquals(JsonValue.Str("2026-10-14T09:11:58.402Z"), out["instant"])
        assertEquals(JsonValue.Str("1969-12-31T23:59:59.999Z"), out["preEpoch"])
        assertEquals(JsonValue.Arr(listOf(JsonValue.IntV(1), JsonValue.IntV(2))), out["ints"])
        assertEquals(JsonValue.Arr(listOf(JsonValue.Num(0.5))), out["doubles"])
        assertEquals(JsonValue.Arr(listOf(JsonValue.Bool(true))), out["bools"])
        assertEquals(JsonValue.Arr(listOf(JsonValue.Str("a"), JsonValue.Null)), out["objects"])
        assertEquals(JsonValue.Arr(listOf(JsonValue.IntV(1))), out["sequence"])
    }

    // isValidEventName

    @Test
    fun accepts_title_case_with_spaces_and_rejects_blank_or_too_long() {
        assertTrue(Sanitize.isValidEventName("Purchase Completed"))
        assertFalse(Sanitize.isValidEventName("   "))
        assertFalse(Sanitize.isValidEventName(""))
        assertTrue(Sanitize.isValidEventName("a".repeat(128)))
        assertFalse(Sanitize.isValidEventName("a".repeat(129)))
        assertTrue(Sanitize.isValidEventName("  ${"a".repeat(128)}  "))
        assertEquals(128, Sanitize.MAX_NAME)
    }

    /** Kotlin-only: trimming follows Swift's `.whitespacesAndNewlines`, not `Char.isWhitespace`. */
    @Test
    fun trims_unicode_whitespace_like_ios() {
        assertFalse(Sanitize.isValidEventName("\u0085  　\t\n"))
        // U+001F is whitespace to Java but not to Swift: a name, not a blank.
        assertTrue(Sanitize.isValidEventName("\u001F"))
        assertTrue(Sanitize.isValidEventName("\u0085${"a".repeat(128)} "))
    }
}
