# Changelog

## 2.0.0

The package is renamed from `LoopSDK` to `Loop` and split into modules.

### Modules

- **LoopCore**: API key, ids, networking, device info. Every module depends on it.
- **LoopFeedback**: the bug & feature reporter UI.
- **LoopDiagnostics**: breadcrumbs and captured problems.
- **LoopAnalytics** (new): events, user id, user properties, purchaser id, sessions, opt-out. Events are queued on disk and uploaded as gzip batches to `POST /api/ingest/analytics/batch`. Ships its own privacy manifest. Behaviour is pinned by the shared cases in `conformance/`.

Each module is its own SwiftPM product and CocoaPods pod (tags have no `v` prefix, e.g. `2.0.0`).

### Android

- **loop-core** and **loop-analytics** (new) for Android, in `android/`. Install from JitPack: `implementation("com.github.JoshMustafa.loop-sdk:loop-analytics:2.0.0")` with `maven { url = uri("https://jitpack.io") }`. minSdk 21.
- Same wire format, defaults and behaviour as iOS, pinned by the same `conformance/` cases (Kotlin runner `ConformanceTest`).
- `Loop.configure(context, apiKey, options)`; `LoopAnalytics.start`, `track`, `setUserId`, `setUserProperties`, `setPurchaserId`, `setOptOut`, `deviceId`, `sessionId`; suspend `flush()`/`reset()` plus Java-friendly `flushAsync(Runnable?)`/`resetAsync(Runnable?)`. `LoopAnalyticsOptions` takes times in milliseconds (`flushIntervalMillis`, `minTimeBetweenSessionsMillis`).
- The queue lives in `noBackupFilesDir`. Foreground/background uploads use `ProcessLifecycleOwner`; removing androidx.startup's `InitializationProvider` disables them (with a logged warning) while timer and queue-size uploads continue. The upload timer pauses in the background.
- `kotlinx-coroutines-android` is an `api` dependency.
- A minimal sample app in `android/sample/` (not published).

### Flutter

- **loop_analytics** (new) Flutter plugin in `flutter/loop_analytics`, backed by the native LoopAnalytics (iOS) and loop-analytics (Android) modules. It replaces the pure-Dart SDK, so Flutter apps share the native wire format, defaults and behaviour.
- Installed as a git dependency (`url: https://github.com/JoshMustafa/loop-sdk.git`, `path: flutter/loop_analytics`, `ref: 2.0.0`). iOS 16+, Android minSdk 21, Kotlin 1.9+ in the host app.
- Same Dart API as the pure-Dart SDK, except `deviceId()` and `sessionId()` are now async. Calls made before `init` completes are buffered (up to 1000) and sent in order.

### Renamed

| 1.x | 2.0.0 |
|---|---|
| `import LoopSDK` | `import LoopCore` + the modules you use |
| `LoopSDK.start(apiKey:)` / `start(configuration:)` | `Loop.configure(apiKey:options:)` |
| `LoopConfiguration` | `LoopOptions` |
| `apiBase:` | `LoopOptions(serverUrl:)` |
| `LoopSDK.presentReporter(from:)` / `LoopReporterView()` | `LoopFeedback.present(from:)` / `LoopFeedbackView()` |
| `LoopSDK.currentReporterId()` | `Loop.reporterId` |
| `LoopSDK.breadcrumb` / `captureDiagnostic` | `LoopDiagnostics.breadcrumb` / `capture` |
| `LoopSDK.track` / `identify` / `resetIdentity` | `LoopAnalytics.track` / `setUserId` / `reset` |

See the migration table in the README for details.

### Removed

- The Retention subsystem, replaced by `LoopAnalytics`.
- `LoopSDK.defineFunnel`. Funnels are built in the Loop Analytics dashboard.

### Changed

- The default server URL is now `https://loop-analytics-api.fly.dev` (was `https://loop-backend.fly.dev`).
