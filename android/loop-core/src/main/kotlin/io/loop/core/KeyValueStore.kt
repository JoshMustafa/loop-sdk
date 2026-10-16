package io.loop.core

import android.content.Context
import android.content.SharedPreferences

/** Small typed key-value persistence. Setting `null` removes the key. */
@InternalLoopApi
public interface KeyValueStore {
    public fun string(key: String): String?
    public fun long(key: String): Long?
    public fun bool(key: String): Boolean?
    public fun setString(key: String, value: String?)
    public fun setLong(key: String, value: Long?)
    public fun setBool(key: String, value: Boolean?)
}

/**
 * [SharedPreferences]-backed store in its own file. Writes use `apply()`: they
 * are visible at once and reach disk in the background, off the caller's thread.
 */
@InternalLoopApi
public class SharedPreferencesStore(context: Context, name: String) : KeyValueStore {
    private val prefs: SharedPreferences = context.getSharedPreferences(name, Context.MODE_PRIVATE)

    override fun string(key: String): String? = read(key) { prefs.getString(key, null) }
    override fun long(key: String): Long? = read(key) { prefs.getLong(key, 0L) }
    override fun bool(key: String): Boolean? = read(key) { prefs.getBoolean(key, false) }

    override fun setString(key: String, value: String?) =
        write(key, value) { putString(key, it) }

    override fun setLong(key: String, value: Long?) =
        write(key, value) { putLong(key, it) }

    override fun setBool(key: String, value: Boolean?) =
        write(key, value) { putBoolean(key, it) }

    /** Null when the key is missing or holds a value of another type. */
    private inline fun <T> read(key: String, get: () -> T): T? {
        if (!prefs.contains(key)) return null
        return try {
            get()
        } catch (_: ClassCastException) {
            null
        }
    }

    private inline fun <T : Any> write(key: String, value: T?, put: SharedPreferences.Editor.(T) -> Unit) {
        val editor = prefs.edit()
        if (value == null) editor.remove(key) else editor.put(value)
        editor.apply()
    }
}

/** In-memory store for tests and as a fallback. */
@InternalLoopApi
public class MemoryKeyValueStore : KeyValueStore {
    private val values = HashMap<String, Any>()

    override fun string(key: String): String? = get(key) as? String
    override fun long(key: String): Long? = get(key) as? Long
    override fun bool(key: String): Boolean? = get(key) as? Boolean

    override fun setString(key: String, value: String?) = put(key, value)
    override fun setLong(key: String, value: Long?) = put(key, value)
    override fun setBool(key: String, value: Boolean?) = put(key, value)

    private fun get(key: String): Any? = synchronized(values) { values[key] }

    private fun put(key: String, value: Any?) {
        synchronized(values) {
            if (value == null) values.remove(key) else values[key] = value
        }
    }
}
