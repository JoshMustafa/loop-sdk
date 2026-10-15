import Flutter
import UIKit

public class LoopAnalyticsPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "loop_analytics", binaryMessenger: registrar.messenger())
    let instance = LoopAnalyticsPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("iOS " + UIDevice.current.systemVersion)
    case "configure":
      // TEMPORARY (Task 1 spike): proves the native LoopCore sources compile
      // into this pod and link. Replaced by the Pigeon host API in Task 3.
      Loop.configure(apiKey: call.arguments as? String ?? "")
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
