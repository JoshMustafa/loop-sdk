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

/// The lifecycle source for the platform the app runs on. Inside an app
/// extension (or wherever no `UIApplication` exists) it is always in the
/// foreground and asks for no background time.
func makePlatformLifecycle() async -> LifecycleSource {
    #if canImport(UIKit) && os(iOS)
    if let source = await IOSLifecycleSource.make() { return source }
    #endif
    return AlwaysForegroundLifecycle()
}

/// Whether the bundle at `bundleURL` is an app extension (`.appex`).
func isAppExtension(bundleURL: URL) -> Bool {
    bundleURL.pathExtension == "appex"
}

/// Platforms or processes without app lifecycle notifications (macOS, app
/// extensions): always in the foreground.
final class AlwaysForegroundLifecycle: LifecycleSource {
    var isForeground: Bool { true }

    func start(_ onChange: @escaping @Sendable (Bool) -> Void) {}
}

#if canImport(UIKit) && os(iOS)
/// The app's `UIApplication`, looked up at runtime because
/// `UIApplication.shared` is unavailable to code linked into app extensions.
/// Nil inside an extension.
@MainActor
func hostApplication() -> UIApplication? {
    guard !isAppExtension(bundleURL: Bundle.main.bundleURL) else { return nil }
    return UIApplication.value(forKey: "sharedApplication") as? UIApplication
}

/// `UIApplication.didBecomeActiveNotification` → foreground,
/// `didEnterBackgroundNotification` → background.
final class IOSLifecycleSource: LifecycleSource, @unchecked Sendable {
    private let application: UIApplication
    private let lock = NSLock()
    private var foreground: Bool
    private var onChange: (@Sendable (Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []

    /// The source for the running app; nil inside an app extension.
    @MainActor
    static func make() -> IOSLifecycleSource? {
        hostApplication().map(IOSLifecycleSource.init)
    }

    /// Reads the state and starts observing on the main thread, so no
    /// transition is missed in between. Launching (`.inactive`) counts as
    /// the foreground.
    @MainActor
    private init(application: UIApplication) {
        self.application = application
        foreground = application.applicationState != .background
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
        let task = BackgroundTask(application)
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
    private let application: UIApplication
    private let lock = NSLock()
    private var id = UIBackgroundTaskIdentifier.invalid

    init(_ application: UIApplication) {
        self.application = application
    }

    func begin(named name: String) {
        let id = application.beginBackgroundTask(withName: name) { [self] in end() }
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
            application.endBackgroundTask(id)
        } else {
            DispatchQueue.main.async { self.application.endBackgroundTask(id) }
        }
    }
}
#endif
