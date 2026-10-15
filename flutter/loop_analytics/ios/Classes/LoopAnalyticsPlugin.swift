import Flutter
import UIKit

public class LoopAnalyticsPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    LoopAnalyticsHostApiSetup.setUp(
      binaryMessenger: registrar.messenger(), api: LoopAnalyticsPlugin())
  }
}

// TEMPORARY (Task 2): no-op host API so the Pigeon channel is registered and
// the plugin compiles. Task 3 replaces it with calls into the native SDK.
extension LoopAnalyticsPlugin: LoopAnalyticsHostApi {
  func configure(
    apiKey: String, options: NativeOptions,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    // Keeps the Task 1 proof that the native LoopCore sources link.
    Loop.configure(apiKey: apiKey)
    completion(.success(()))
  }

  func track(name: String, properties: [String?: Any?]) {}

  func setUserId(userId: String?) {}

  func setUserProperties(properties: [String?: Any?]) {}

  func setPurchaserId(purchaserId: String?) {}

  func flush(completion: @escaping (Result<Void, Error>) -> Void) {
    completion(.success(()))
  }

  func reset(completion: @escaping (Result<Void, Error>) -> Void) {
    completion(.success(()))
  }

  func setOptOut(optOut: Bool) {}

  func deviceId(completion: @escaping (Result<String?, Error>) -> Void) {
    completion(.success(nil))
  }

  func sessionId(completion: @escaping (Result<Int64?, Error>) -> Void) {
    completion(.success(nil))
  }
}
