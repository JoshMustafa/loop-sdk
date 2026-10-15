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

No Podfile or JitPack lines are needed: the plugin compiles the native sources from the checkout.

Requires iOS 16+, Android minSdk 21, and Kotlin 1.9 or newer in the host app (coroutines 1.9 needs it).

## Quick start

```dart
import 'package:loop_analytics/loop_analytics.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LoopAnalytics.init(
    apiKey: 'loop_pk_…',
    options: LoopOptions(legacyDeviceId: previousSdkDeviceId), // optional
  );
  runApp(const MyApp());
}

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
```

- `init` completes once the native engine has started. It gives up waiting for the native side after 10 s (logged), so a missing reply never blocks launch.
- `LoopAnalytics.instance` is set as soon as `init` is called. Calls made before `init` completes are buffered and sent in order; up to 1000 are kept, and past that the oldest is dropped.
- Calling `init` again returns the existing instance and logs a warning.
- Calls never throw into the app; errors are logged.
- `deviceId()` and `sessionId()` are async. This is the only change from the pure-Dart SDK, where they were getters. `sessionId()` may return null just after `init`, until the first event or lifecycle change.

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

## Developing the plugin

The plugin's iOS sources are symlinks to `ios/Sources` in the repository root. After adding, removing or renaming a native file, run `tool/link_native_sources.sh`; CI checks the links are up to date.

```bash
flutter test
cd example && flutter test integration_test -d <device>   # not run in CI
```
