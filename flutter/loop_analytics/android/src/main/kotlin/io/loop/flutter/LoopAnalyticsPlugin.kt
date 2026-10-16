package io.loop.flutter

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.loop.analytics.AnalyticsRuntime
import io.loop.analytics.Log
import io.loop.analytics.LoopAnalytics
import io.loop.analytics.LoopAnalyticsOptions
import io.loop.core.Loop
import io.loop.core.LoopOptions
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * The Pigeon [LoopAnalyticsHostApi], forwarded to the native `Loop` and
 * `LoopAnalytics` modules compiled into this plugin.
 */
class LoopAnalyticsPlugin : FlutterPlugin, LoopAnalyticsHostApi {
    private lateinit var applicationContext: Context

    /** Runs the suspending calls; cancelled when the engine detaches. */
    private lateinit var scope: CoroutineScope

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        LoopAnalyticsHostApi.setUp(binding.binaryMessenger, this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        LoopAnalyticsHostApi.setUp(binding.binaryMessenger, null)
        // Pending configure/flush/reset calls reply with an error (see replyWhenDone).
        scope.cancel()
    }

    override fun configure(apiKey: String, options: NativeOptions, callback: (Result<Unit>) -> Unit) {
        try {
            if (apiKey.isBlank()) Log.warning("LoopAnalytics.init was given an empty API key")
            val loopOptions = options.serverUrl?.let { LoopOptions(serverUrl = it) } ?: LoopOptions()
            // A second configure (e.g. after a hot restart) replaces the
            // configuration; start then only logs that it was ignored.
            Loop.configure(applicationContext, apiKey, loopOptions)
            LoopAnalytics.start(options.toAnalyticsOptions())
        } catch (e: Exception) {
            callback(Result.failure(e))
            return
        }
        // Replies once the engine is built, so deviceId is set when init returns.
        replyWhenDone(callback) { AnalyticsRuntime.shared.waitForPendingCalls() }
    }

    override fun track(name: String, properties: Map<String?, Any?>) {
        LoopAnalytics.track(name, stringKeyed(properties))
    }

    override fun setUserId(userId: String?) {
        LoopAnalytics.setUserId(userId)
    }

    override fun setUserProperties(properties: Map<String?, Any?>) {
        LoopAnalytics.setUserProperties(stringKeyed(properties))
    }

    override fun setPurchaserId(purchaserId: String?) {
        LoopAnalytics.setPurchaserId(purchaserId)
    }

    override fun flush(callback: (Result<Unit>) -> Unit) {
        replyWhenDone(callback) { LoopAnalytics.flush() }
    }

    override fun reset(callback: (Result<Unit>) -> Unit) {
        replyWhenDone(callback) { LoopAnalytics.reset() }
    }

    override fun setOptOut(optOut: Boolean) {
        LoopAnalytics.setOptOut(optOut)
    }

    override fun deviceId(callback: (Result<String?>) -> Unit) {
        callback(Result.success(LoopAnalytics.deviceId))
    }

    override fun sessionId(callback: (Result<Long?>) -> Unit) {
        callback(Result.success(LoopAnalytics.sessionId))
    }

    /**
     * Runs [body] in [scope] and replies exactly once: with its result, its
     * exception, or an error if the scope is cancelled first (also when it
     * was already cancelled, so the body never ran).
     */
    private fun <T> replyWhenDone(callback: (Result<T>) -> Unit, body: suspend () -> T) {
        val replied = AtomicBoolean(false)
        val reply = { result: Result<T> -> if (replied.compareAndSet(false, true)) callback(result) }
        val job = scope.launch {
            val result = try {
                Result.success(body())
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Result.failure(e)
            }
            reply(result)
        }
        job.invokeOnCompletion { cause ->
            if (cause != null) {
                reply(Result.failure(LoopAnalyticsPigeonError("cancelled", "the Flutter engine detached", null)))
            }
        }
    }
}

/** [NativeOptions] as the native [LoopAnalyticsOptions]; counts outside the Int range are clamped. */
internal fun NativeOptions.toAnalyticsOptions(): LoopAnalyticsOptions = LoopAnalyticsOptions(
    flushQueueSize = flushQueueSize.clampToInt(),
    flushIntervalMillis = flushIntervalMillis,
    minTimeBetweenSessionsMillis = minTimeBetweenSessionsMillis,
    maxQueueSize = maxQueueSize.clampToInt(),
    maxBatchSize = maxBatchSize.clampToInt(),
    legacyDeviceId = legacyDeviceId,
)

/**
 * A Pigeon properties map with its null keys dropped. Null values stay, so
 * `setUserProperties` can remove those keys; nested maps and lists are
 * passed on as they are, for the native sanitiser.
 */
internal fun stringKeyed(properties: Map<String?, Any?>): Map<String, Any?> {
    val out = LinkedHashMap<String, Any?>(properties.size)
    for ((key, value) in properties) {
        if (key != null) out[key] = value
    }
    return out
}

private fun Long.clampToInt(): Int = coerceIn(Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong()).toInt()
