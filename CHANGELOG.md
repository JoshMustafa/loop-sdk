# Changelog

## 2.0.0

The package is renamed from `LoopSDK` to `Loop` and split into modules.

### Modules

- **LoopCore**: API key, ids, networking, device info. Every module depends on it.
- **LoopFeedback**: the bug & feature reporter UI.
- **LoopDiagnostics**: breadcrumbs and captured problems.
- **LoopAnalytics** (new): events, user id, user properties, purchaser id, sessions, opt-out. Events are queued on disk and uploaded as gzip batches to `POST /api/ingest/analytics/batch`. Ships its own privacy manifest. Behaviour is pinned by the shared cases in `conformance/`.

Each module is its own SwiftPM product and CocoaPods pod (tags have no `v` prefix, e.g. `2.0.0`).

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
