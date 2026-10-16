package io.loop.analytics

/**
 * One queued analytics event, exactly as it goes on the wire.
 *
 * Immutable: once tracked, an event is never rewritten, so a retried batch
 * carries the same events and server-side dedup applies.
 */
internal data class LoopEvent(
    /** UUID v4, unique per event; the server's dedup key. */
    val id: String,
    val name: String,
    val occurredAtMillis: Long,
    /** Session start in ms since epoch, or null. */
    val sessionId: Long?,
    val deviceId: String,
    val userId: String?,
    val props: JsonObject,
    /** The full merged user-property snapshot at the time of the event. */
    val userProps: JsonObject,
    /**
     * Snapshot of the batch-level `context` taken when the event was tracked.
     * Stored with the event but not part of the wire event: the uploader sends
     * it as the batch context. Null for events stored without one.
     */
    val context: JsonObject? = null,
) {
    /** The event as sent on the wire. `sessionId` and `userId` are explicit nulls when absent. */
    fun wireJson(): JsonObject = linkedMapOf(
        "id" to JsonValue.Str(id),
        "name" to JsonValue.Str(name),
        "occurredAt" to JsonValue.Str(LoopTimestamp.format(occurredAtMillis)),
        "sessionId" to (sessionId?.let { JsonValue.IntV(it) } ?: JsonValue.Null),
        "deviceId" to JsonValue.Str(deviceId),
        "userId" to (userId?.let { JsonValue.Str(it) } ?: JsonValue.Null),
        "props" to JsonValue.Obj(props),
        "userProps" to JsonValue.Obj(userProps),
    )

    /** The event as stored in the queue file: the wire event plus `context`. */
    fun storageJson(): JsonObject {
        val json = LinkedHashMap(wireJson())
        if (context != null) json["context"] = JsonValue.Obj(context)
        return json
    }

    companion object {
        /**
         * Reads [wireJson] or [storageJson] output. Throws [MalformedEventException]
         * when a required field is missing or mistyped (used to skip corrupt queue lines).
         */
        fun fromStorage(json: JsonObject): LoopEvent {
            val id = (json["id"] as? JsonValue.Str)?.value ?: throw MalformedEventException()
            val name = (json["name"] as? JsonValue.Str)?.value ?: throw MalformedEventException()
            val occurredAt = (json["occurredAt"] as? JsonValue.Str)?.value ?: throw MalformedEventException()
            val occurredAtMillis = LoopTimestamp.parse(occurredAt) ?: throw MalformedEventException()
            val deviceId = (json["deviceId"] as? JsonValue.Str)?.value ?: throw MalformedEventException()

            val sessionId = when (val value = json["sessionId"]) {
                null, JsonValue.Null -> null
                is JsonValue.IntV -> value.value
                else -> throw MalformedEventException()
            }
            val userId = when (val value = json["userId"]) {
                null, JsonValue.Null -> null
                is JsonValue.Str -> value.value
                else -> throw MalformedEventException()
            }
            val context = when (val value = json["context"]) {
                null, JsonValue.Null -> null
                is JsonValue.Obj -> value.values
                else -> throw MalformedEventException()
            }
            return LoopEvent(
                id = id,
                name = name,
                occurredAtMillis = occurredAtMillis,
                sessionId = sessionId,
                deviceId = deviceId,
                userId = userId,
                props = objectOrEmpty(json["props"]),
                userProps = objectOrEmpty(json["userProps"]),
                context = context,
            )
        }

        /** A missing or null map reads as empty; anything else must be an object. */
        private fun objectOrEmpty(value: JsonValue?): JsonObject = when (value) {
            null, JsonValue.Null -> emptyMap()
            is JsonValue.Obj -> value.values
            else -> throw MalformedEventException()
        }
    }
}

internal class MalformedEventException : Exception("Malformed stored event")

/**
 * ISO 8601 UTC timestamps with millisecond precision, e.g.
 * `2026-10-14T09:11:58.402Z`. Integer arithmetic only, so the millisecond is
 * exact (and no java.time, which needs API 26).
 */
internal object LoopTimestamp {
    private const val MS_PER_DAY = 86_400_000L

    fun format(millis: Long): String {
        val days = millis.floorDiv(MS_PER_DAY)
        val msOfDay = millis - days * MS_PER_DAY
        val (year, month, day) = civilFromDays(days)
        val hour = msOfDay / 3_600_000
        val minute = msOfDay / 60_000 % 60
        val second = msOfDay / 1000 % 60
        val ms = msOfDay % 1000
        return pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2) +
            "T" + pad(hour, 2) + ":" + pad(minute, 2) + ":" + pad(second, 2) +
            "." + pad(ms, 3) + "Z"
    }

    /**
     * Milliseconds since epoch for `YYYY-MM-DDTHH:MM:SS[.fff…]Z`, or null.
     * Digits past the millisecond are ignored.
     */
    fun parse(string: String): Long? {
        val chars = string
        if (chars.length < 20 || chars.last() != 'Z' ||
            chars[4] != '-' || chars[7] != '-' || chars[10] != 'T' ||
            chars[13] != ':' || chars[16] != ':'
        ) {
            return null
        }
        val year = number(chars, 0, 4) ?: return null
        val month = number(chars, 5, 7) ?: return null
        val day = number(chars, 8, 10) ?: return null
        val hour = number(chars, 11, 13) ?: return null
        val minute = number(chars, 14, 16) ?: return null
        val second = number(chars, 17, 19) ?: return null

        var ms = 0L
        val fractionEnd = chars.length - 1
        if (fractionEnd > 19) {
            if (chars[19] != '.' || fractionEnd - 19 < 2) return null
            for (index in 20 until fractionEnd) {
                if (chars[index] !in '0'..'9') return null
            }
            val scale = longArrayOf(100, 10, 1)
            for (index in 0 until minOf(3, fractionEnd - 20)) {
                ms += (chars[20 + index] - '0') * scale[index]
            }
        }

        if (month !in 1..12 || day !in 1..31 || hour >= 24 || minute >= 60 || second >= 60) return null
        val days = daysFromCivil(year, month, day)
        // Rejects days past the end of the month (e.g. 30 February).
        if (civilFromDays(days) != Triple(year, month, day)) return null
        return days * MS_PER_DAY + hour * 3_600_000 + minute * 60_000 + second * 1000 + ms
    }

    private fun number(chars: String, start: Int, end: Int): Long? {
        if (end <= start || end - start > 18) return null
        var value = 0L
        for (index in start until end) {
            val char = chars[index]
            if (char !in '0'..'9') return null
            value = value * 10 + (char - '0')
        }
        return value
    }

    private fun pad(value: Long, width: Int): String {
        val digits = value.toString()
        return if (digits.length >= width) digits else "0".repeat(width - digits.length) + digits
    }

    // Days since 1970-01-01 <-> proleptic Gregorian date (H. Hinnant's algorithms).

    private fun civilFromDays(days: Long): Triple<Long, Long, Long> {
        val z = days + 719_468
        val era = z.floorDiv(146_097L)
        val doe = z - era * 146_097
        val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        val mp = (5 * doy + 2) / 153
        val day = doy - (153 * mp + 2) / 5 + 1
        val month = if (mp < 10) mp + 3 else mp - 9
        val year = yoe + era * 400 + (if (month <= 2) 1 else 0)
        return Triple(year, month, day)
    }

    private fun daysFromCivil(year: Long, month: Long, day: Long): Long {
        val y = if (month <= 2) year - 1 else year
        val era = y.floorDiv(400L)
        val yoe = y - era * 400
        val doy = (153 * (if (month > 2) month - 3 else month + 9) + 2) / 5 + day - 1
        val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
