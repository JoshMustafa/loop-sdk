# loop_analytics

Product analytics for Flutter apps, backed by the native Loop SDK on iOS and Android. Events, user id, user properties, purchaser id, sessions and opt-out.

## Install

```yaml
dependencies:
  loop_analytics:
    git:
      url: https://github.com/JoshMustafa/loop-sdk.git
      path: flutter/loop_analytics
      ref: 2.0.0
```

No `pod` or JitPack lines are needed; only the iOS 16 platform setting. The plugin compiles the native sources from the checkout.

### Requirements

| | Minimum |
|---|---|
| Dart | `>=3.4.0` |
| Flutter | `>=3.22.0` |
| iOS | 16.0 |
| Android `compileSdk` | 34 |
| Android `minSdk` | 21 |
| Kotlin (host app) | 1.9 (coroutines 1.9 needs it) |

### iOS setup

The native SDK needs iOS 16. A new Flutter app targets a lower version, so `pod install` fails with "required a higher minimum deployment target" until you raise it in two places:

1. In `ios/Podfile`, set the platform (Flutter's template has this line commented out, and CocoaPods then assumes iOS 12):

   ```ruby
   platform :ios, '16.0'
   ```

2. In Xcode, select the Runner target, then General → Minimum Deployments → 16.0 (this sets `IPHONEOS_DEPLOYMENT_TARGET = 16.0`). Otherwise the app links an iOS 16 framework into a lower-target app.

## Quick start

```dart
import 'package:flutter/material.dart';
import 'package:loop_analytics/loop_analytics.dart';

// Placeholders: replace with your own values.
const String? previousSdkDeviceId = null; // device id from a previous analytics SDK, if any
const String? revenueCatAppUserId = null; // your purchases SDK's app user id, if any

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LoopAnalytics.init(
    apiKey: 'loop_pk_…',
    options: const LoopOptions(legacyDeviceId: previousSdkDeviceId), // optional
  );
  runApp(const MaterialApp(home: Scaffold()));
}

Future<void> examples() async {
  final loop = LoopAnalytics.instance!;
  loop.track('Item Viewed', {'Index': 1});
  loop.setUserId('12345');                       // null when signed out
  loop.setUserProperties({'Plan': 'annual'});    // a null value removes a property
  loop.setPurchaserId(revenueCatAppUserId);
  await loop.flush();
  await loop.reset();                            // new device id, no user, new session
  loop.setOptOut(true);
  final deviceId = await loop.deviceId();
  final sessionId = await loop.sessionId();
  debugPrint('ids ready: ${deviceId != null}, ${sessionId != null}');
}
```

- `init` completes once the native engine has started. It gives up waiting for the native side after 10 s (logged), so a missing reply never blocks launch.
- `LoopAnalytics.instance` is set as soon as `init` is called. Calls made before `init` completes are buffered and sent in order; up to 1000 are kept, and past that the oldest is dropped.
- Calling `init` again returns the existing instance and logs a warning.
- Calls never throw into the app; errors are logged.
- `sessionId()` may return null just after `init`, until the first event or lifecycle change.

### Changes from the pure-Dart SDK

- `deviceId()` and `sessionId()` are now async (`Future<String?>` and `Future<int?>`); they were getters (`deviceId` was non-null).
- The `userId` and `isOptedOut` getters and `dispose()` are removed.
- `LoopAnalytics.instance` is now set as soon as `init` is called, not when it completes.

`init`, `instance`, `track`, `setUserId`, `setUserProperties`, `setPurchaserId`, `flush`, `reset`, `setOptOut` and `LoopOptions` keep their signatures. Queueing, sessions and uploads run in the native SDK, so the plugin behaves as the native SDKs, which pass the shared conformance cases.

## Options

| Option | Default | Meaning |
|---|---|---|
| `serverUrl` | `https://loop-analytics-api.fly.dev` | Base URL of the Loop analytics API |
| `flushQueueSize` | `30` | Upload as soon as this many events are queued |
| `flushInterval` | `30 s` | Upload queued events at least this often |
| `minTimeBetweenSessions` | `5 min` | Idle time after which a new session starts |
| `maxQueueSize` | `1000` | Most events kept on disk; when full, the oldest 20 are dropped |
| `maxBatchSize` | `100` | Most events sent in one request |
| `legacyDeviceId` | `null` | A device id to adopt on first run, so anonymous users from a previous analytics SDK carry over |
| `logLevel` | `LoopLogLevel.warning` | How much the Dart side logs |

## Notes

- Use either this plugin or the native Loop SDK in one app, not both.
- Host Swift code can `import loop_analytics` and reach the native API. Don't: it bypasses the Dart state.
- On iOS an invalid `serverUrl` is rejected with an error; Android passes it through.
- After a hot restart the native SDK keeps the first `apiKey` and `serverUrl`; a full restart applies changes.

## Developing the plugin

The plugin's iOS sources are symlinks to `ios/Sources` in the repository root. After adding, removing or renaming a native file, run `tool/link_native_sources.sh`; CI checks the links are up to date.

```bash
flutter test
cd example && flutter test integration_test -d <device>   # not run in CI
```
