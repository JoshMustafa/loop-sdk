import Foundation
#if canImport(UIKit) && os(iOS)
import UIKit
#endif

/// App foreground/background signals; injectable so tests need no UIKit.
protocol LifecycleSource: AnyObject {
    /// Whether the app is in the foreground right now.
    var isForeground: Bool { get }

    /// Starts reporting changes: `true` when the app becomes active, `false`
    /// when it enters the background.
    func start(_ onChange: @escaping @Sendable (Bool) -> Void)

    /// Asks the system for time to finish work started on entering the
    /// background. Called from the `onChange(false)` callback; call the
    /// returned closure when the work is done. By default there is nothing
    /// to ask for.
    func beginBackgroundTask(named name: String) -> @Sendable () -> Void
}

extension LifecycleSource {
    func beginBackgroundTask(named name: String) -> @Sendable () -> Void { {} }
}

/// The lifecycle source for the platform the app runs on.
func makePlatformLifecycle() async -> LifecycleSource {
    #if canImport(UIKit) && os(iOS)
    return await IOSLifecycleSource()
    #else
    return AlwaysForegroundLifecycle()
    #endif
}

/// Platforms without app lifecycle notifications (macOS): always in the
/// foreground.
final class AlwaysForegroundLifecycle: LifecycleSource {
    var isForeground: Bool { true }

    func start(_ onChange: @escaping @Sendable (Bool) -> Void) {}
}

#if canImport(UIKit) && os(iOS)
/// `UIApplication.didBecomeActiveNotification` → foreground,
/// `didEnterBackgroundNotification` → background.
final class IOSLifecycleSource: LifecycleSource, @unchecked Sendable {
    private let lock = NSLock()
    private var foreground: Bool
    private var onChange: (@Sendable (Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []

    /// Reads the state and starts observing on the main thread, so no
    /// transition is missed in between. Launching (`.inactive`) counts as
    /// the foreground.
    @MainActor
    init() {
        foreground = UIApplication.shared.applicationState != .background
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.changed(true)
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.changed(false)
            },
        ]
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    var isForeground: Bool {
        lock.lock(); defer { lock.unlock() }
        return foreground
    }

    func start(_ onChange: @escaping @Sendable (Bool) -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.onChange = onChange
    }

    /// A `UIApplication` background task, ended by the returned closure or
    /// by the system's expiration handler, whichever comes first.
    func beginBackgroundTask(named name: String) -> @Sendable () -> Void {
        let task = BackgroundTask()
        task.begin(named: name)
        return { task.end() }
    }

    private func changed(_ foreground: Bool) {
        lock.lock()
        self.foreground = foreground
        let onChange = self.onChange
        lock.unlock()
        onChange?(foreground)
    }
}

/// One UIKit background task; ends at most once.
private final class BackgroundTask: @unchecked Sendable {
    private let lock = NSLock()
    private var id = UIBackgroundTaskIdentifier.invalid

    func begin(named name: String) {
        let id = UIApplication.shared.beginBackgroundTask(withName: name) { [self] in end() }
        lock.lock(); defer { lock.unlock() }
        self.id = id
    }

    func end() {
        lock.lock()
        let id = self.id
        self.id = .invalid
        lock.unlock()
        guard id != .invalid else { return }
        // The expiration handler runs on the main thread and must end the
        // task before it returns; the flush finishes on any thread.
        if Thread.isMainThread {
            UIApplication.shared.endBackgroundTask(id)
        } else {
            DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(id) }
        }
    }
}
#endif
