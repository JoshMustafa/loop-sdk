package io.loop.core

/**
 * Options shared by every Loop module, passed once to [Loop.configure].
 *
 * A data class for apps to build: a library that wraps Loop should not
 * expose it in its own binary API, since its constructor and `copy` change
 * whenever an option is added.
 */
public data class LoopOptions(
    /** The Loop backend every module talks to. */
    val serverUrl: String = "https://loop-analytics-api.fly.dev",
)
