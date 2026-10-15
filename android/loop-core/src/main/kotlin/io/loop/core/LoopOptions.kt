package io.loop.core

/** Options shared by every Loop module, passed once to [Loop.configure]. */
public data class LoopOptions(
    /** The Loop backend every module talks to. */
    val serverUrl: String = "https://loop-analytics-api.fly.dev",
)
