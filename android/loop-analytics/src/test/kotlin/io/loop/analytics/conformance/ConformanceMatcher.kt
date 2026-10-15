package io.loop.analytics.conformance

import io.loop.analytics.JsonException
import io.loop.analytics.JsonValue

/**
 * Matches recorded values against a conformance case's expected values
 * (port of the Swift `ConformanceMatcher`; the rules are in
 * `conformance/README.md` under "Matching").
 */
internal object ConformanceMatcher {
    private val UUID_PATTERN = Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
    private val ISO8601_PATTERN = Regex("""^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$""")
    private val PATH_SEGMENT = Regex("""([^.\[\]]+)|\[(\d+)]""")

    /**
     * The first mismatch between [actual] (null when absent) and [expected],
     * or null when they match. [root] is what `$sameAs` paths resolve
     * against; [path] names the value in the message.
     */
    fun mismatch(actual: JsonValue?, expected: JsonValue, root: JsonValue, path: String): String? {
        if (expected is JsonValue.Str) {
            when (expected.value) {
                "<uuid>" -> return if (actual is JsonValue.Str && UUID_PATTERN.matches(actual.value)) {
                    null
                } else {
                    "$path: expected a UUID, got ${describe(actual)}"
                }
                "<int>" -> return if (actual is JsonValue.IntV) null else "$path: expected an int, got ${describe(actual)}"
                "<iso8601>" -> return if (actual is JsonValue.Str && ISO8601_PATTERN.matches(actual.value)) {
                    null
                } else {
                    "$path: expected an ISO-8601 string, got ${describe(actual)}"
                }
                "<any>" -> return if (actual != null) null else "$path: expected a value, got ${describe(actual)}"
            }
        }

        return when (expected) {
            is JsonValue.Obj -> matchObject(actual, expected.values, root, path)
            is JsonValue.Arr -> {
                val want = expected.values
                if (actual !is JsonValue.Arr) return "$path: expected an array, got ${describe(actual)}"
                val got = actual.values
                if (got.size != want.size) {
                    return "$path: expected ${want.size} element(s), got ${got.size}: ${describe(actual)}"
                }
                want.indices.firstNotNullOfOrNull { i -> mismatch(got[i], want[i], root, "$path[$i]") }
            }
            else -> if (actual != null && equal(actual, expected)) {
                null
            } else {
                "$path: expected ${describe(expected)}, got ${describe(actual)}"
            }
        }
    }

    private fun matchObject(actual: JsonValue?, want: Map<String, JsonValue>, root: JsonValue, path: String): String? {
        want["\$stringLength"]?.let { length ->
            // Dart's String.length counts UTF-16 code units, as Kotlin's does.
            if (actual is JsonValue.Str && equal(JsonValue.IntV(actual.value.length.toLong()), length)) return null
            val got = if (actual is JsonValue.Str) "length ${actual.value.length}" else describe(actual)
            return "$path: expected a string of length ${describe(length)}, got $got"
        }
        (want["\$sameAs"] as? JsonValue.Str)?.value?.let { source ->
            val resolved = resolve(source, root) ?: return "\$sameAs: no $source"
            if (actual != null && equal(actual, resolved)) return null
            return "$path: expected the same as $source (${describe(resolved)}), got ${describe(actual)}"
        }
        if (actual !is JsonValue.Obj) return "$path: expected an object, got ${describe(actual)}"
        val got = actual.values
        val partial = want["\$partial"] == JsonValue.Bool(true)
        val keys = want.keys - "\$partial"
        if (!partial) {
            val missing = keys - got.keys
            val extra = got.keys - keys
            if (missing.isNotEmpty() || extra.isNotEmpty()) {
                return "$path: key mismatch (missing ${missing.sorted()}, unexpected ${extra.sorted()}) in ${describe(actual)}"
            }
        }
        for (key in keys.sorted()) {
            val value = got[key] ?: return "$path: missing key \"$key\" in ${describe(actual)}"
            mismatch(value, want.getValue(key), root, "$path.$key")?.let { return it }
        }
        return null
    }

    /** Deep equality where an integer and a double with the same value are equal (as in Dart, where `1 == 1.0`). */
    fun equal(a: JsonValue, b: JsonValue): Boolean = when {
        a is JsonValue.IntV && b is JsonValue.Num -> a.value.toDouble() == b.value
        a is JsonValue.Num && b is JsonValue.IntV -> a.value == b.value.toDouble()
        a is JsonValue.Arr && b is JsonValue.Arr ->
            a.values.size == b.values.size && a.values.indices.all { equal(a.values[it], b.values[it]) }
        a is JsonValue.Obj && b is JsonValue.Obj ->
            a.values.size == b.values.size &&
                a.values.all { (key, value) -> b.values[key]?.let { equal(value, it) } ?: false }
        else -> a == b
    }

    /** Resolves a path like `requests[0].events` against [root]. */
    fun resolve(path: String, root: JsonValue): JsonValue? {
        var node = root
        for (match in PATH_SEGMENT.findAll(path)) {
            val index = match.groups[2]?.value
            node = if (index != null) {
                (node as? JsonValue.Arr)?.values?.getOrNull(index.toInt()) ?: return null
            } else {
                (node as? JsonValue.Obj)?.values?.get(match.groupValues[1]) ?: return null
            }
        }
        return node
    }

    /** [value] as compact JSON for failure messages. */
    fun describe(value: JsonValue?): String {
        if (value == null) return "<absent>"
        val text = try {
            value.toJson()
        } catch (_: JsonException) {
            value.toString()
        }
        return if (text.length > 2000) text.take(2000) + "…" else text
    }
}
