import Flutter
import UIKit

/// The Pigeon `LoopAnalyticsHostApi`, forwarded to the native `Loop` and
/// `LoopAnalytics` modules. They compile into this pod's module, so their
/// types are used without an import.
public class LoopAnalyticsPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    LoopAnalyticsHostApiSetup.setUp(
      binaryMessenger: registrar.messenger(), api: LoopAnalyticsPlugin())
  }
}

extension LoopAnalyticsPlugin: LoopAnalyticsHostApi {
  func configure(
    apiKey: String, options: NativeOptions,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      Log.analytics.warning("LoopAnalytics.init was given an empty API key")
    }
    var loopOptions = LoopOptions()
    if let serverUrl = options.serverUrl {
      guard let url = URL(string: serverUrl) else {
        Log.analytics.error("LoopAnalytics.init ignored: serverUrl is not a valid URL")
        completion(
          .failure(
            LoopAnalyticsPigeonError(
              code: "invalid-server-url", message: "serverUrl is not a valid URL", details: nil)))
        return
      }
      loopOptions = LoopOptions(serverUrl: url)
    }
    // A second configure (e.g. after a hot restart) replaces the
    // configuration; start then only logs that it was ignored.
    Loop.configure(apiKey: apiKey, options: loopOptions)
    LoopAnalytics.start(options: Self.analyticsOptions(options))
    // Replies once the engine is built, so deviceId is set when init
    // returns. Awaited, never blocked on: the build hops to the main actor.
    Task { @MainActor in
      await AnalyticsRuntime.shared.waitForPendingCalls()
      completion(.success(()))
    }
  }

  func track(name: String, properties: [String?: Any?]) {
    LoopAnalytics.track(name, Self.stringKeyed(properties))
  }

  func setUserId(userId: String?) {
    LoopAnalytics.setUserId(userId)
  }

  func setUserProperties(properties: [String?: Any?]) {
    LoopAnalytics.setUserProperties(Self.stringKeyed(properties))
  }

  func setPurchaserId(purchaserId: String?) {
    LoopAnalytics.setPurchaserId(purchaserId)
  }

  func flush(completion: @escaping (Result<Void, Error>) -> Void) {
    Task { @MainActor in
      await LoopAnalytics.flush()
      completion(.success(()))
    }
  }

  func reset(completion: @escaping (Result<Void, Error>) -> Void) {
    Task { @MainActor in
      await LoopAnalytics.reset()
      completion(.success(()))
    }
  }

  func setOptOut(optOut: Bool) {
    LoopAnalytics.setOptOut(optOut)
  }

  func deviceId(completion: @escaping (Result<String?, Error>) -> Void) {
    completion(.success(LoopAnalytics.deviceId))
  }

  func sessionId(completion: @escaping (Result<Int64?, Error>) -> Void) {
    completion(.success(LoopAnalytics.sessionId))
  }

  /// `NativeOptions` (durations in ms) as the native options (seconds).
  static func analyticsOptions(_ options: NativeOptions) -> LoopAnalyticsOptions {
    LoopAnalyticsOptions(
      flushQueueSize: Int(clamping: options.flushQueueSize),
      flushInterval: TimeInterval(options.flushIntervalMillis) / 1000,
      minTimeBetweenSessions: TimeInterval(options.minTimeBetweenSessionsMillis) / 1000,
      maxQueueSize: Int(clamping: options.maxQueueSize),
      maxBatchSize: Int(clamping: options.maxBatchSize),
      legacyDeviceId: options.legacyDeviceId
    )
  }

  /// A Pigeon properties map with its nil keys dropped. Nil values become
  /// `NSNull`, so `setUserProperties` removes those keys; nested values are
  /// passed on as they are, for the native sanitiser.
  static func stringKeyed(_ properties: [String?: Any?]) -> [String: Any?] {
    var out: [String: Any?] = [:]
    for (key, value) in properties {
      guard let key else { continue }
      out.updateValue(value ?? NSNull(), forKey: key)
    }
    return out
  }
}
