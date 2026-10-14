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
| **LoopCore** | API key, ids, networking, device info. Every module depends on it. | ✅ | planned | (inside each plugin) |
| **LoopFeedback** | Bug & feature reporter UI: lists, votes, replies, new reports, optional email | ✅ | later | later |
| **LoopDiagnostics** | Breadcrumbs and captured problems | ✅ | later | later |
| **LoopAnalytics** | Events, user id, user properties, sessions | next release | planned | planned |

Modules never depend on each other, so an app that only wants feedback doesn't ship analytics, and vice versa.

## Install

**Swift Package Manager.** Add `https://github.com/JoshMustafa/loop-sdk` and tick the products you need (`LoopCore` plus `LoopFeedback` and/or `LoopDiagnostics`).

**CocoaPods.** Installed straight from GitHub. Add the modules you use, plus `LoopCore`:

```ruby
pod 'LoopCore',        :git => 'https://github.com/JoshMustafa/loop-sdk.git', :tag => 'v0.1.0'
pod 'LoopFeedback',    :git => 'https://github.com/JoshMustafa/loop-sdk.git', :tag => 'v0.1.0'
pod 'LoopDiagnostics', :git => 'https://github.com/JoshMustafa/loop-sdk.git', :tag => 'v0.1.0'
```

Requires iOS 16+.

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

### Tagging reports with the user's subscription tier

Every report and diagnostic can carry an optional `user.tier` string that the dashboard shows as a pill (`Paid` / `Trial` / `Free`, or any custom value such as `pro`).

**If your app uses RevenueCat, this works with no code.** `Loop.configure(apiKey:)` auto-detects RevenueCat through the Objective-C runtime (no build-time dependency) and sends `"paid"` when the user has an active entitlement, `"free"` otherwise.

To supply your own value, or turn it off:

```swift
Loop.configure(apiKey: "loop_pk_…", options: LoopOptions(tierProvider: {
    Purchases.shared.cachedCustomerInfo?
        .entitlements.active.keys.contains("pro") == true ? "pro" : "free"
}))

Loop.configure(apiKey: "loop_pk_…", options: LoopOptions(tierProvider: nil))
```

The provider is read on every send, must be cheap and non-blocking, and an empty value means "unknown". End users never see the tier.

## Migrating from `LoopSDK`

The package was renamed from `LoopSDK` to `Loop` and split into modules.

| Before | Now |
|---|---|
| package `LoopSDK`, `import LoopSDK` | package `Loop`; `import LoopCore` + `LoopFeedback` and/or `LoopDiagnostics` |
| `LoopSDK.start(apiKey:)` / `start(configuration:)` | `Loop.configure(apiKey:options:)` |
| `LoopConfiguration` | `LoopOptions` |
| `apiBase:` | `LoopOptions(serverUrl:)` (default `https://loop-analytics-api.fly.dev`) |
| `LoopSDK.presentReporter(from:)` / `LoopReporterView()` | `LoopFeedback.present(from:)` / `LoopFeedbackView()` |
| `LoopSDK.currentReporterId()` | `Loop.reporterId` |
| `LoopSDK.breadcrumb` / `captureDiagnostic` | `LoopDiagnostics.breadcrumb` / `capture` |
| `LoopSDK.track` / `identify` / `resetIdentity` | Removed. Use `LoopAnalytics` (next release). |
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

## App Store review

Each module ships its own `PrivacyInfo.xcprivacy`:

- **LoopCore**: no tracking, no collected data types, no required-reason APIs.
- **LoopFeedback**: declares the optional email address (linked, not tracking, app functionality).
- **LoopDiagnostics**: no manifest entries beyond Core's.

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

## Repository layout

```
Package.swift          SwiftPM manifest (sources under ios/)
*.podspec              one podspec per module
ios/Sources/           LoopCore, LoopFeedback, LoopDiagnostics
ios/Tests/             one test target per module + shared LoopTestSupport
ios/Examples/          minimal SwiftUI host app (see its README)
```

Android (`android/`) and Flutter (`flutter/`) land in later releases, sharing one conformance suite so every platform behaves the same.

## Tests

```bash
swift test
xcodebuild -scheme Loop-Package -destination 'generic/platform=iOS Simulator' build
```

The UI is tested by hand with the example app.

## License

Proprietary — © 2026 Josh Mustafa. All rights reserved. See [LICENSE](./LICENSE).
