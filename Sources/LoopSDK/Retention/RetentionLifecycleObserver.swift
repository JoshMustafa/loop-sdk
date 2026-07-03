import Foundation
#if canImport(UIKit) && os(iOS)
import UIKit

/// Wires UIKit lifecycle notifications into the retention engine so the
/// auto events need zero host-app code:
///
/// - `didBecomeActive` → `app_opened` (every foreground, including launch)
/// - `didEnterBackground` → immediate flush
///
/// Also probes the current application state once at creation, covering
/// hosts that call `LoopSDK.start` *after* the app is already active (the
/// notification has fired and won't repeat). `trackAppOpened` dedupes per
/// foreground stint, so the probe and the notification can't double-count.
final class RetentionLifecycleObserver: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []

    init(engine: RetentionEngine) {
        let center = NotificationCenter.default

        tokens.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { _ in
            let occurredAt = Date()
            Task { await engine.trackAppOpened(at: occurredAt) }
        })

        tokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task { await engine.handleDidEnterBackground() }
        })

        Task { @MainActor in
            if UIApplication.shared.applicationState == .active {
                await engine.trackAppOpened(at: Date())
            }
        }
    }

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }
}
#endif
