package io.loop.core

/** Source of wall-clock time in Unix epoch milliseconds. Injectable so tests can control time. */
@InternalLoopApi
public fun interface LoopClock {
    public fun nowMillis(): Long
}

/** The real clock. */
@InternalLoopApi
public object SystemClock : LoopClock {
    override fun nowMillis(): Long = System.currentTimeMillis()
}
