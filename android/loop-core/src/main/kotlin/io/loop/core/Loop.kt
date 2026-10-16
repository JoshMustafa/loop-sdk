package io.loop.core

import android.content.Context

/**
 * Configure Loop once at app launch, before using any module:
 *
 *     Loop.configure(this, apiKey = "loop_pk_…")
 */
public object Loop {
    private val lock = Any()
    private var _configuration: LoopConfiguration? = null
    private var _configurationVersion = 0

    @JvmStatic
    @JvmOverloads
    public fun configure(context: Context, apiKey: String, options: LoopOptions = LoopOptions()) {
        val appContext = context.applicationContext ?: context
        synchronized(lock) {
            _configuration = LoopConfiguration(apiKey, options, appContext)
            _configurationVersion += 1
        }
    }

    /** The last [configure] call, or null before the first one. */
    @InternalLoopApi
    public val configuration: LoopConfiguration?
        get() = synchronized(lock) { _configuration }

    /**
     * Bumped by every [configure], so modules that cache work built from the
     * configuration know when to rebuild it.
     */
    @InternalLoopApi
    public val configurationVersion: Int
        get() = synchronized(lock) { _configurationVersion }

    /** Test hook: forget the configuration. */
    @InternalLoopApi
    public fun resetForTesting() {
        synchronized(lock) {
            _configuration = null
            _configurationVersion += 1
        }
    }
}

/** What [Loop.configure] was given; [applicationContext] is the app's, never an Activity. */
@InternalLoopApi
public data class LoopConfiguration(
    val apiKey: String,
    val options: LoopOptions,
    val applicationContext: Context,
)
