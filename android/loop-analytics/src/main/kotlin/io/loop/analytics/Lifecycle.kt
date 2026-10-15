package io.loop.analytics

import android.os.Handler
import android.os.Looper
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner

/** App foreground/background signals; injectable so tests need no Android. */
internal fun interface LifecycleSource {
    /**
     * Starts reporting. [onState] is called once with the state when
     * observing began (`initial` true: not itself a lifecycle event), then
     * on every change: `foreground` true when the app comes to the
     * foreground, false when it goes to the background. It may be called on
     * any thread.
     */
    fun start(onState: (foreground: Boolean, initial: Boolean) -> Unit)
}

/**
 * The whole process's lifecycle from [ProcessLifecycleOwner]: `ON_START`
 * is the foreground and `ON_STOP` the background. (`ON_STOP` arrives
 * shortly after the last activity stops, so a rotation is not a trip to the
 * background.) Going to the background needs no extra time from the system
 * on Android.
 *
 * The observer is added on the main thread, as the lifecycle requires;
 * [start] called on another thread posts the registration there.
 */
internal class ProcessLifecycleSource(
    internal val owner: LifecycleOwner = ProcessLifecycleOwner.get(),
) : LifecycleSource {
    override fun start(onState: (foreground: Boolean, initial: Boolean) -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            register(onState)
        } else {
            Handler(Looper.getMainLooper()).post { register(onState) }
        }
    }

    /**
     * On the main thread: adds the observer and reads the state in one
     * step, so no transition is missed in between.
     */
    private fun register(onState: (foreground: Boolean, initial: Boolean) -> Unit) {
        val lifecycle = owner.lifecycle
        var registering = true
        lifecycle.addObserver(
            LifecycleEventObserver { _, event ->
                // addObserver replays every event up to the current state;
                // that state is reported once below instead.
                if (registering) return@LifecycleEventObserver
                when (event) {
                    Lifecycle.Event.ON_START -> onState(true, false)
                    Lifecycle.Event.ON_STOP -> onState(false, false)
                    else -> Unit
                }
            },
        )
        registering = false
        onState(lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED), true)
    }
}
