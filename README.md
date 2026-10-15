<div align="center">

<img src="./loop-mark.svg" alt="Loop" width="96" height="96" />

# Loop SDK

**Bug & feature reporting, diagnostics and product analytics for mobile apps.**

Native SwiftUI on iOS (no WebView), survives offline, anonymous by default. Configure once, then pick the modules you need.

</div>

---

## Modules

| Module | What it does | iOS | Android | Flutter |
|---|---|---|---|---|
| **LoopCore** | API key, ids, networking, device info. Every module depends on it. | ✅ | ✅ | (inside each plugin) |
| **LoopFeedback** | Bug & feature reporter UI: lists, votes, replies, new reports, optional email | ✅ | later | later |
| **LoopDiagnostics** | Breadcrumbs and captured problems | ✅ | later | later |
| **LoopAnalytics** | Events, user id, user properties, sessions | ✅ | ✅ | planned |

Modules never depend on each other, so an app that only wants feedback doesn't ship analytics, and vice versa.

## Install

Available from release `2.0.0` (the first release with the module split).

**Swift Package Manager.** Add `https://github.com/JoshMustafa/loop-sdk` (from `2.0.0`) and tick the products you need (`LoopCore` plus any of `LoopFeedback`, `LoopDiagnostics` and `LoopAnalytics`).

**CocoaPods.** Installed straight from GitHub. Add the modules you use, plus `LoopCore`:

```ruby
pod 'LoopCore',        :git => 'https://github.com/JoshMustafa/loop-sdk.git', :tag => '2.0.0'
pod 'LoopFeedback',    :git => 'https://github.com/JoshMustafa/loop-sdk.git', :tag => '2.0.0'
pod 'LoopDiagnostics', :git => 'https://github.com/JoshMustafa/loop-sdk.git', :tag => '2.0.0'
pod 'LoopAnalytics',   :git => 'https://github.com/JoshMustafa/loop-sdk.git', :tag => '2.0.0'
```

Requires iOS 16+.

**Android (Gradle, via JitPack).** `loop-core` and `loop-analytics` are available on Android. Add JitPack to your repositories (in `settings.gradle.kts`):

```kotlin
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
    }
}
```

Then add the dependency (it brings in `loop-core`):

```kotlin
implementation("com.github.JoshMustafa.loop-sdk:loop-analytics:2.0.0")
```

Requires minSdk 21. `kotlinx-coroutines-android` is an `api` dependency (the async `flushAsync()`/`resetAsync()` return a coroutines `Job`); `androidx.lifecycle:lifecycle-process` is pulled in for foreground/background detection.

## Quick start

```swift
import LoopCore
import LoopFeedback
import LoopDiagnostics

// Once, at launch
Loop.configure(apiKey: "loop_pk_…")

// SwiftUI: show the reporter in a sheet
.sheet(isPresented: $showingFeedback) { LoopFeedbackView() }

// UIKit
LoopFeedback.present(from: viewController)

// Open straight on the compose form
LoopComposerView(kind: .bug)

// Diagnostics
LoopDiagnostics.breadcrumb("Tapped sync")
LoopDiagnostics.capture("sync_failed", severity: .error, context: ["code": "504"])
```

`LoopDiagnostics` calls made before `Loop.configure` are safe: breadcrumbs are kept and captures are dropped. Presenting `LoopFeedbackView` before `Loop.configure` stops with a clear error, so a missing key shows up during integration rather than as silent failures.

### Analytics

```swift
import LoopCore
import LoopAnalytics

Loop.configure(apiKey: "loop_pk_…")
LoopAnalytics.start()                                   // optional; defaults are used otherwise
LoopAnalytics.track("Item Viewed", ["Index": 1])
LoopAnalytics.setUserId("12345")                        // nil when signed out
LoopAnalytics.setUserProperties(["Plan": "annual"])    // nil value removes a property
LoopAnalytics.setPurchaserId(revenueCatAppUserID)
```

The fire-and-forget calls return at once; `flush()` and `reset()` are async. All calls run in the order they were made and never throw into the app. Also available: `await LoopAnalytics.flush()`, `await LoopAnalytics.reset()` (new device id, no user id, user properties or purchaser id, new session), `LoopAnalytics.setOptOut(_:)`, and the read-only `LoopAnalytics.deviceId` and `LoopAnalytics.sessionId`.

`LoopAnalyticsOptions` (all optional):

| Option | Default | Meaning |
|---|---|---|
| `flushQueueSize` | `30` | Upload as soon as this many events are queued |
| `flushInterval` | `30` s | Upload queued events at least this often |
| `minTimeBetweenSessions` | `300` s | Idle time after which a new session starts |
| `maxQueueSize` | `1000` | Most events kept on disk; when full, the oldest 20 are dropped |
| `maxBatchSize` | `100` | Most events sent in one request |
| `legacyDeviceId` | `nil` | A device id to adopt on first run, so anonymous users from a previous analytics SDK carry over |

Pass only the options you want to change:

```swift
LoopAnalytics.start(options: .init(legacyDeviceId: previousSdkDeviceId))
```

When migrating from another analytics SDK, passing its device id as `legacyDeviceId` keeps your existing anonymous users: on first run the device keeps the id it already had instead of counting as a new one.

How it behaves:

- Events are queued on disk and uploaded in gzip batches of up to 100. An upload happens at 30 queued events, every 30 s, when the app goes to the background or returns to the foreground, at startup, and when opting back in.
- A full queue (1000) drops the oldest 20 events.
- A `401`/`403` keeps the events and retries hourly.
- A session ends after 5 minutes idle; there is no timeout while the app is in the foreground.
- `setOptOut(true)` drops new events and stops uploads; events already queued are kept and uploaded after opting back in.
- Calls made before `Loop.configure` are dropped. Options passed to `start` before then are kept and applied once configured. Calling `Loop.configure` a second time logs a warning, and analytics keeps the key it started with.
- Safe to link into app extensions. Inside an extension the app is treated as always in the foreground and no background task is used. An app extension that links LoopAnalytics reports as a separate device with its own queue unless the app shares storage through an app group; app groups are not supported in 2.0.0.

### Tagging reports with the user's subscription tier

Every report and diagnostic can carry an optional `user.tier` string that the dashboard shows as a pill (`Paid` / `Trial` / `Free`, or any custom value such as `pro`).

**If your app uses RevenueCat, this works with no code.** `Loop.configure(apiKey:)` auto-detects RevenueCat through the Objective-C runtime (no build-time dependency) and sends `"paid"` when the user has an active entitlement, `"free"` when RevenueCat reports none, and nothing while it cannot tell yet.

To supply your own value, or turn it off:

```swift
Loop.configure(apiKey: "loop_pk_…", options: LoopOptions(tierProvider: {
    Purchases.shared.cachedCustomerInfo?
        .entitlements.active.keys.contains("pro") == true ? "pro" : "free"
}))

Loop.configure(apiKey: "loop_pk_…", options: LoopOptions(tierProvider: nil))
```

The provider is read on every send, must be cheap and non-blocking, and an empty value means "unknown". End users never see the tier.

## Android quick start

```kotlin
import android.app.Application
import io.loop.analytics.LoopAnalytics
import io.loop.analytics.LoopAnalyticsOptions
import io.loop.core.Loop

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        Loop.configure(this, "loop_pk_…")
        // Optional: without it, defaults are used. Only the first call counts.
        // Options take times in milliseconds on Android.
        LoopAnalytics.start(LoopAnalyticsOptions(flushIntervalMillis = 60_000))
    }
}

// Anywhere in the app, e.g. in an Activity
fun onItemOpened(index: Int, userId: String?, revenueCatAppUserId: String?) {
    LoopAnalytics.track("Item Viewed", mapOf("Index" to index))
    LoopAnalytics.setUserId(userId)                                // null when signed out
    LoopAnalytics.setUserProperties(mapOf("Plan" to "annual"))     // null value removes a property
    LoopAnalytics.setPurchaserId(revenueCatAppUserId)
}
```

From Java: `LoopAnalytics.flushAsync(null);` (the `Runnable` callback, when given, runs on the main thread once done).

The fire-and-forget calls behave as on iOS. `flush()` and `reset()` are `suspend` functions; Java callers use `flushAsync(Runnable?)` and `resetAsync(Runnable?)`. Also available: `setOptOut(Boolean)`, and the read-only `deviceId` and `sessionId`. `LoopAnalyticsOptions` is a data class with the same defaults as iOS, except that times are in milliseconds: `flushIntervalMillis` (30 000) and `minTimeBetweenSessionsMillis` (300 000).

Android notes:

- The queue lives in `noBackupFilesDir`, so it is never backed up or restored to another device.
- Foreground and background are detected with `ProcessLifecycleOwner`. If your app removes androidx.startup's `InitializationProvider`, uploads on foreground and background stop and a warning is logged; uploads on the timer and on queue size still happen.
- The 30 s upload timer pauses while the app is in the background.
- A sample app lives in `android/sample/` (`./gradlew :sample:assembleDebug` from `android/`, with your key in place of `loop_pk_REPLACE_ME`). It is not published.



## Migrating from `LoopSDK`

The package was renamed from `LoopSDK` to `Loop` and split into modules.

| Before | Now |
|---|---|
| package `LoopSDK`, `import LoopSDK` | package `Loop`; `import LoopCore` + `LoopFeedback`, `LoopDiagnostics` and/or `LoopAnalytics` |
| `LoopSDK.start(apiKey:)` / `start(configuration:)` | `Loop.configure(apiKey:options:)` |
| `LoopConfiguration` | `LoopOptions` |
| `apiBase:` | `LoopOptions(serverUrl:)` (default `https://loop-analytics-api.fly.dev`) |
| `LoopSDK.presentReporter(from:)` / `LoopReporterView()` | `LoopFeedback.present(from:)` / `LoopFeedbackView()` |
| `LoopSDK.currentReporterId()` | `Loop.reporterId` |
| `LoopSDK.breadcrumb` / `captureDiagnostic` | `LoopDiagnostics.breadcrumb` / `capture` |
| `LoopSDK.track` / `identify` / `resetIdentity` | `LoopAnalytics.track` / `setUserId` / `reset` |
| `LoopSDK.defineFunnel` | Removed. Funnels are built in the Loop Analytics dashboard. |

Nothing is lost on upgrade: the reporter id (Keychain) and any diagnostics still waiting to send are picked up by the new modules.

## What the user sees

- Every bug and feature filed against the project, split into Bugs / Features.
- Up/down votes on each item (voting twice doesn't double-count) and reply threads.
- A "+" button to file a new report: pick Bug or Feature, add a title and a few sentences, send.
- If the project has it switched on, an optional prompt after sending to leave an email for follow-up.
- Device, OS, app version, locale, network type and a per-launch session id are attached automatically.

## What the user doesn't see

- No login and no Apple ID.
- Each device gets a stable anonymous id like `r_8af3bc9e1234`, created on first use and kept in the Keychain (not synced to iCloud), so you can recognise repeat reporters without knowing who they are.

## Privacy disclosure (paste into your privacy policy)

> This app uses Loop to let you report bugs and request features. When you
> submit a report, Loop attaches your device model, OS version, app version,
> locale, network type and a per-launch session id, plus a random per-device
> id stored in your device's Keychain so the developer can recognise repeat
> reports from the same device. If you choose to leave an email address
> after sending a report, it is stored with that id so the developer can
> reply. Loop does not track you across apps or websites.

If you use **LoopAnalytics**, add:

> This app uses Loop to measure how the app is used. Loop records the
> actions you take in the app (product interaction) with a random per-device
> id, and, if the app supplies them, the app's own user id and user
> properties. This data is linked to that user id, used only for analytics,
> and not used to track you across apps or websites.

## App Store review

Each module ships its own `PrivacyInfo.xcprivacy`:

- **LoopCore**: no tracking, no collected data types, no required-reason APIs.
- **LoopFeedback**: declares the optional email address (linked, not tracking, app functionality).
- **LoopDiagnostics**: no manifest entries beyond Core's.
- **LoopAnalytics**: declares device id, user id, product interaction and other data types (the user properties your app supplies), all linked, not tracking, purpose Analytics; plus `UserDefaults` with reason `CA92.1`.

There is no `ATTrackingManager` prompt anywhere.

## Endpoints

Every request carries `Authorization: Bearer loop_pk_…` and `X-Loop-Reporter-Id: r_…`.

| Module | Method | Path |
|---|---|---|
| Feedback | GET | `/api/ingest/project` |
| Feedback | GET | `/api/ingest/bugs?limit=&cursor=` |
| Feedback | GET | `/api/ingest/features?limit=&cursor=` |
| Feedback | GET | `/api/ingest/items/:id` |
| Feedback | POST | `/api/ingest/items/:id/vote` |
| Feedback | POST | `/api/ingest/items/:id/replies` |
| Feedback | POST | `/api/ingest/submissions` |
| Feedback | POST | `/api/ingest/contact` |
| Diagnostics | POST | `/api/ingest/events` |
| Analytics | POST | `/api/ingest/analytics/batch` |

Analytics bodies are gzip-compressed (`Content-Encoding: gzip`).

## Repository layout

```
Package.swift          SwiftPM manifest (sources under ios/)
*.podspec              one podspec per module
conformance/           shared, platform-neutral behaviour cases (JSON)
ios/Sources/           LoopCore, LoopFeedback, LoopDiagnostics, LoopAnalytics
ios/Tests/             one test target per module + shared LoopTestSupport
ios/Examples/          minimal SwiftUI host app (see its README)
android/               loop-core, loop-analytics (Gradle) and a sample app
```

Flutter (`flutter/`) lands in a later release. Every platform shares one conformance suite so they all behave the same.

## Tests

```bash
swift test
xcodebuild -scheme Loop-Package -destination 'generic/platform=iOS Simulator' build
```

The UI is tested by hand with the example app.

`conformance/` holds the shared analytics cases that every platform's SDK must pass (see [conformance/README.md](./conformance/README.md)). The iOS runner:

```bash
swift test --filter ConformanceTests
```

The Android runner (from `android/`):

```bash
./gradlew :loop-analytics:testDebugUnitTest --tests '*ConformanceTest*'
```

## License

Proprietary — © 2026 Josh Mustafa. All rights reserved. See [LICENSE](./LICENSE).
