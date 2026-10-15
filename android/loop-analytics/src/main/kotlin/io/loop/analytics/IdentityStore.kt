package io.loop.analytics

import io.loop.core.KeyValueStore
import java.util.UUID

/**
 * A new device id: a random UUID v4, lower-case, followed by `R`
 * (e.g. `9860d042-84a6-4bb3-95ab-f974f56d9c3dR`).
 */
internal fun generateDeviceId(): String = UUID.randomUUID().toString().lowercase() + "R"

/**
 * Who the events are about: device id, user id, RevenueCat purchaser id, the
 * merged user-property snapshot and the opt-out flag. Persisted in a
 * [KeyValueStore]. Not thread-safe: the engine serialises access.
 */
internal class IdentityStore(
    private val kv: KeyValueStore,
    legacyDeviceId: String?,
    private val newDeviceId: () -> String,
) {
    var deviceId: String
        private set
    var userId: String?
        private set
    var purchaserId: String?
        private set

    /** The current snapshot (never mutated in place; safe to embed in an event). */
    var userProperties: JsonObject
        private set
    var optOut: Boolean
        private set

    /**
     * Loads the stored identity. On first run the device id is [legacyDeviceId]
     * (trimmed) when it is valid, else `newDeviceId()`.
     */
    init {
        val stored = kv.string(DEVICE_ID_KEY)
        if (stored != null && isValidDeviceId(stored)) {
            deviceId = stored
        } else {
            val legacy = legacyDeviceId?.let(Sanitize::trimWhitespace)
            deviceId = legacy?.takeIf(::isValidDeviceId) ?: newDeviceId()
            kv.setString(DEVICE_ID_KEY, deviceId)
        }
        userId = kv.string(USER_ID_KEY)
        purchaserId = kv.string(PURCHASER_ID_KEY)
        optOut = kv.bool(OPT_OUT_KEY) ?: false
        userProperties = decodeProps(kv.string(USER_PROPS_KEY))
    }

    fun setUserId(userId: String?) {
        this.userId = userId
        kv.setString(USER_ID_KEY, userId)
    }

    fun setPurchaserId(purchaserId: String?) {
        this.purchaserId = purchaserId
        kv.setString(PURCHASER_ID_KEY, purchaserId)
    }

    /** Merges [properties] into the snapshot; a [JsonValue.Null] value removes that key. */
    fun mergeUserProperties(properties: JsonObject) {
        val next = LinkedHashMap(userProperties)
        for ((key, value) in properties) {
            if (value == JsonValue.Null) next.remove(key) else next[key] = value
        }
        userProperties = next
        try {
            kv.setString(USER_PROPS_KEY, JsonValue.Obj(next).toJson())
        } catch (_: JsonException) {
            // Not encodable (a non-finite number): kept in memory only, as on iOS.
        }
    }

    fun setOptOut(optOut: Boolean) {
        this.optOut = optOut
        kv.setBool(OPT_OUT_KEY, optOut)
    }

    /**
     * New random device id (never the legacy one) and no user, purchaser or
     * user properties. Opt-out is kept: it is the person's choice, not identity.
     */
    fun reset() {
        deviceId = newDeviceId()
        userId = null
        purchaserId = null
        userProperties = emptyMap()
        kv.setString(DEVICE_ID_KEY, deviceId)
        kv.setString(USER_ID_KEY, null)
        kv.setString(PURCHASER_ID_KEY, null)
        kv.setString(USER_PROPS_KEY, null)
    }

    companion object {
        const val DEVICE_ID_KEY = "io.loop.analytics.device_id"
        const val USER_ID_KEY = "io.loop.analytics.user_id"
        const val PURCHASER_ID_KEY = "io.loop.analytics.purchaser_id"
        const val USER_PROPS_KEY = "io.loop.analytics.user_props"
        const val OPT_OUT_KEY = "io.loop.analytics.opt_out"

        /** Server limit on device ids. */
        const val MAX_DEVICE_ID_LENGTH = 200

        /** A missing or unreadable snapshot loads as empty. */
        private fun decodeProps(raw: String?): JsonObject {
            if (raw == null) return emptyMap()
            return try {
                JsonValue.parseObject(raw)
            } catch (_: JsonException) {
                emptyMap()
            }
        }

        private fun isValidDeviceId(id: String): Boolean =
            Sanitize.trimWhitespace(id).isNotEmpty() && id.length <= MAX_DEVICE_ID_LENGTH
    }
}
