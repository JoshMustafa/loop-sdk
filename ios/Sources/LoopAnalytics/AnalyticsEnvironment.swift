import Foundation
import LoopCore

/// Stops a scheduled timer.
protocol Cancellable {
    func cancel()
}

/// Runs the periodic flush. Injectable so tests fire ticks themselves.
protocol Scheduler: AnyObject {
    /// Calls `tick` every `seconds` until the returned handle is cancelled.
    func every(_ seconds: TimeInterval, _ tick: @escaping @Sendable () -> Void) -> Cancellable
}

/// The engine's platform dependencies. `production()` builds the real ones;
/// tests and the conformance runner pass fakes.
struct AnalyticsEnvironment {
    var clock: LoopClock
    var transport: AnalyticsTransport
    /// The queue file; nil keeps the queue in memory only.
    var queueURL: URL?
    var kv: KeyValueStore
    /// The device and app facts as of now; read for every event.
    var context: @Sendable () -> LoopContext
    var lifecycle: LifecycleSource
    var newEventId: @Sendable () -> String
    var newDeviceId: @Sendable () -> String
    var scheduler: Scheduler
    /// Sent as `context.sdk`.
    var sdk: (name: String, version: String)
    /// How long one upload request may take. Also bounds how long
    /// `AnalyticsEngine.dispose()` waits for the request in flight.
    var requestTimeout: Duration = Uploader.defaultRequestTimeout
}

extension AnalyticsEnvironment {
    static let sdk = (name: "loop-ios", version: "2.0.0")
    static let userDefaultsSuite = "io.loop.analytics"

    /// The real environment: system clock, `URLSession`, the queue file in
    /// Application Support, the `io.loop.analytics` defaults suite, UIKit
    /// lifecycle and a dispatch timer.
    static func production() async -> AnalyticsEnvironment {
        let device = await DeviceContext.start()
        return AnalyticsEnvironment(
            clock: SystemClock(),
            transport: URLSessionTransport(),
            queueURL: defaultQueueURL(),
            kv: UserDefaultsStore(suiteName: userDefaultsSuite),
            context: { device.current },
            lifecycle: await makePlatformLifecycle(),
            newEventId: { newEventId() },
            newDeviceId: { generateDeviceId() },
            scheduler: TimerScheduler(),
            sdk: sdk
        )
    }

    /// A random UUID v4, lower-case: the server's dedup key for an event.
    static func newEventId() -> String {
        UUID().uuidString.lowercased()
    }

    /// `<Application Support>/Loop/analytics-queue.jsonl`, or nil (the queue
    /// then lives in memory only) when the directory cannot be created.
    static func defaultQueueURL() -> URL? {
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return try queueURL(in: support)
        } catch {
            Log.analytics.error("No directory for the analytics queue; events will not persist: \(error.localizedDescription)")
            return nil
        }
    }

    /// Creates `<base>/Loop/`, excludes it from backup, and returns the queue
    /// file inside it.
    ///
    /// The flag goes on the directory, not the file: the queue is rewritten
    /// by renaming a new file over the old one, which would drop a flag (or
    /// file protection) set on the file itself.
    static func queueURL(in base: URL) throws -> URL {
        var directory = base.appendingPathComponent("Loop", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try directory.setResourceValues(values)
        } catch {
            Log.analytics.error("Could not exclude the analytics queue from backup: \(error.localizedDescription)")
        }
        return directory.appendingPathComponent("analytics-queue.jsonl")
    }
}

/// The device context, captured on the main thread (it reads `UIDevice`) and
/// recaptured when the user changes the locale, so events can read it from
/// any thread.
final class DeviceContext: @unchecked Sendable {
    private let lock = NSLock()
    private var context: LoopContext
    private var observer: NSObjectProtocol?

    private init(_ context: LoopContext) {
        self.context = context
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var current: LoopContext {
        lock.lock(); defer { lock.unlock() }
        return context
    }

    @MainActor
    static func start() -> DeviceContext {
        let device = DeviceContext(LoopContext.capture())
        device.observer = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak device] _ in
            device?.update(LoopContext.capture())
        }
        return device
    }

    private func update(_ context: LoopContext) {
        lock.lock(); defer { lock.unlock() }
        self.context = context
    }
}

/// `Scheduler` over a `DispatchSourceTimer`.
final class TimerScheduler: Scheduler {
    /// Longest interval honoured, so the conversion to nanoseconds cannot
    /// overflow (a year).
    private static let maxInterval: TimeInterval = 365 * 24 * 3600

    func every(_ seconds: TimeInterval, _ tick: @escaping @Sendable () -> Void) -> Cancellable {
        // A zero, negative or non-finite interval means no periodic flush
        // rather than a timer that spins.
        guard seconds.isFinite, seconds > 0 else { return DispatchTimer(nil) }
        let interval = min(seconds, Self.maxInterval)
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        // Up to 10 % (at most 1 s) of slack lets the system batch wake-ups.
        let leeway = DispatchTimeInterval.milliseconds(Int(min(interval * 100, 1000)))
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        source.setEventHandler(handler: tick)
        source.resume()
        return DispatchTimer(source)
    }

    private final class DispatchTimer: Cancellable {
        private let source: DispatchSourceTimer?

        init(_ source: DispatchSourceTimer?) {
            self.source = source
        }

        deinit { source?.cancel() }

        func cancel() { source?.cancel() }
    }
}
