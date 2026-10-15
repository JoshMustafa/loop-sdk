package io.loop.flutter

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.loop.core.Loop

/** LoopAnalyticsPlugin */
class LoopAnalyticsPlugin : FlutterPlugin, LoopAnalyticsHostApi {
  private lateinit var context: Context

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    LoopAnalyticsHostApi.setUp(binding.binaryMessenger, this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    LoopAnalyticsHostApi.setUp(binding.binaryMessenger, null)
  }

  // TEMPORARY (Task 2): no-op host API so the Pigeon channel is registered
  // and the plugin compiles. Task 3 replaces it with calls into the native SDK.

  override fun configure(apiKey: String, options: NativeOptions, callback: (Result<Unit>) -> Unit) {
    // Keeps the Task 1 proof that the native loop-core sources link.
    Loop.configure(context, apiKey)
    callback(Result.success(Unit))
  }

  override fun track(name: String, properties: Map<String?, Any?>) {}

  override fun setUserId(userId: String?) {}

  override fun setUserProperties(properties: Map<String?, Any?>) {}

  override fun setPurchaserId(purchaserId: String?) {}

  override fun flush(callback: (Result<Unit>) -> Unit) {
    callback(Result.success(Unit))
  }

  override fun reset(callback: (Result<Unit>) -> Unit) {
    callback(Result.success(Unit))
  }

  override fun setOptOut(optOut: Boolean) {}

  override fun deviceId(callback: (Result<String?>) -> Unit) {
    callback(Result.success(null))
  }

  override fun sessionId(callback: (Result<Long?>) -> Unit) {
    callback(Result.success(null))
  }
}
