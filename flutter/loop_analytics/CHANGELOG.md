# Changelog

## 2.0.0

- Rewritten as a Flutter plugin backed by the native Loop SDK (LoopAnalytics on iOS, loop-analytics on Android). Queueing, sessions, uploads and persistence now run natively, so a Flutter app behaves as the native SDKs, which pass the shared conformance cases.
- Breaking changes from the pure-Dart SDK:
  - `deviceId()` and `sessionId()` are now async methods (`Future<String?>` and `Future<int?>`), because they are read from the native SDK.
  - The `userId` and `isOptedOut` getters and `dispose()` are removed.
  - `LoopAnalytics.instance` is now set as soon as `init` is called, not when it completes.
- Calls made before `init` completes are buffered (up to 1000, oldest dropped) and sent in order. `init` stops waiting for the native side after 10 s.
- Installed from the `loop-sdk` repository with a git dependency (`path: flutter/loop_analytics`). Requires Dart `>=3.4.0`, Flutter `>=3.22.0`, iOS 16+, Android compileSdk 34+ and minSdk 21, and Kotlin 1.9+ in the host app.
- iOS setup: no `pod` or JitPack lines are needed; only the iOS 16 platform setting. Set `platform :ios, '16.0'` in `ios/Podfile` and the Runner target's Minimum Deployments to 16.0 (`IPHONEOS_DEPLOYMENT_TARGET = 16.0`); without it `pod install` fails with "required a higher minimum deployment target".
