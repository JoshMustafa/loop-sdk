# Changelog

## 2.0.0

- Rewritten as a Flutter plugin backed by the native Loop SDK (LoopAnalytics on iOS, loop-analytics on Android). Queueing, sessions, uploads and persistence now run natively, so a Flutter app behaves exactly like a native one and passes the same conformance cases.
- The Dart API is unchanged from the pure-Dart SDK except that `deviceId()` and `sessionId()` are now async methods (`Future<String?>` and `Future<int?>`), because they are read from the native SDK.
- `LoopAnalytics.instance` is set as soon as `init` is called. Calls made before `init` completes are buffered (up to 1000, oldest dropped) and sent in order. `init` stops waiting for the native side after 10 s.
- Installed from the `loop-sdk` repository with a git dependency (`path: flutter/loop_analytics`). Requires iOS 16+, Android minSdk 21 and Kotlin 1.9+ in the host app.
