import Foundation
import LoopCore

/// Options for `LoopAnalytics.start(options:)`.
public struct LoopAnalyticsOptions: Sendable {
    /// Upload as soon as this many events are queued.
    public var flushQueueSize = 30
    /// Upload queued events at least this often (seconds) while the app runs.
    public var flushInterval: TimeInterval = 30
    /// Idle time (seconds) after which the next event or return to the app
    /// starts a new session.
    public var minTimeBetweenSessions: TimeInterval = 300
    /// Most events kept on disk; when full, the oldest 20 are dropped.
    public var maxQueueSize = 1000
    /// Most events sent in one request.
    public var maxBatchSize = 100
    /// A device id to adopt on first run (e.g. the one your previous
    /// analytics SDK generated) so existing anonymous users carry over.
    /// Ignored once a device id is stored, and after `reset()`.
    public var legacyDeviceId: String? = nil

    public init() {}
}

/// Product analytics for Loop.
///
///     Loop.configure(apiKey: "loop_pk_…")
///     LoopAnalytics.start()                  // optional: defaults otherwise
///     LoopAnalytics.track("Item Viewed", ["Index": 1])
///
/// Calls are fire-and-forget: they return at once, run in the order they
/// were made, and never throw into the app. Calls made before
/// `Loop.configure` are dropped. Events are queued on disk and uploaded in
/// batches in the background.
public enum LoopAnalytics {
    /// Starts analytics with `options`. Call it once, after `Loop.configure`
    /// (options passed earlier are kept until then). Without it, the first
    /// call after `Loop.configure` starts analytics with the default
    /// options. Later calls are ignored.
    ///
    /// Analytics keeps the API key and server it started with: calling
    /// `Loop.configure` again later does not change them.
    public static func start(options: LoopAnalyticsOptions = LoopAnalyticsOptions()) {
        AnalyticsRuntime.shared.start(options: options)
    }

    /// Records an event. `properties` may hold strings, numbers, booleans,
    /// arrays and nested dictionaries; nil values are dropped, dates become
    /// ISO 8601 strings and anything else its description.
    public static func track(_ name: String, _ properties: [String: Any?]? = nil) {
        let props = properties.map { Sanitize.props($0) }
        AnalyticsRuntime.shared.enqueue { await $0.track(name, props) }
    }

    /// The signed-in user's id; nil (or empty) means signed out.
    public static func setUserId(_ userId: String?) {
        AnalyticsRuntime.shared.enqueue { await $0.setUserId(userId) }
    }

    /// Merges `properties` into the user properties sent with every event.
    /// A nil (or `NSNull`) value removes that property.
    public static func setUserProperties(_ properties: [String: Any?]) {
        // Sanitising drops exactly the keys whose value is nil or NSNull;
        // here those mean "remove", so they go on as explicit nulls.
        var json = Sanitize.props(properties)
        for key in properties.keys where json[key] == nil { json[key] = .null }
        let merge = json
        AnalyticsRuntime.shared.enqueue { await $0.setUserProperties(merge) }
    }

    /// The RevenueCat app user id (may be `$RCAnonymousID:…`); nil clears it.
    public static func setPurchaserId(_ purchaserId: String?) {
        AnalyticsRuntime.shared.enqueue { await $0.setPurchaserId(purchaserId) }
    }

    /// Uploads queued events now. Returns when the queue is empty or an
    /// upload failed (events stay queued and are retried later).
    public static func flush() async {
        // Ordered with the other calls, but the upload itself runs outside
        // the call queue so a slow network never holds up later calls.
        let upload = await AnalyticsRuntime.shared.perform { engine in
            Task { await engine.flush() }
        }
        await upload?.value
    }

    /// Forgets the current person: a new random device id, no user id, user
    /// properties or purchaser id, and a new session. Events already queued
    /// keep the identity they were tracked with. Opt-out is kept.
    public static func reset() async {
        _ = await AnalyticsRuntime.shared.perform { await $0.reset() }
    }

    /// When true, new events are dropped and nothing is uploaded until it is
    /// set back to false. Queued events are kept and uploaded after opting
    /// back in. Persisted across launches.
    public static func setOptOut(_ optOut: Bool) {
        AnalyticsRuntime.shared.enqueue { await $0.setOptOut(optOut) }
    }

    /// The id events are attributed to; nil until analytics has started.
    public static var deviceId: String? {
        AnalyticsRuntime.shared.published?.deviceId
    }

    /// The current session's start time in ms since epoch; nil until
    /// analytics has started.
    public static var sessionId: Int64? {
        AnalyticsRuntime.shared.published?.sessionId
    }

    /// Test hook: disposes the shared engine and forgets `start(options:)`.
    /// The next engine is built from `environment` (default: the real one).
    static func resetForTesting(environment: (@Sendable () async -> AnalyticsEnvironment)? = nil) {
        AnalyticsRuntime.shared.resetForTesting(environment: environment)
    }
}

/// Owns the shared engine and the serial call queue: one `AsyncStream` of
/// operations consumed by a single task, so calls run in the order they
/// were made.
final class AnalyticsRuntime: @unchecked Sendable {
    static let shared = AnalyticsRuntime()

    typealias Operation = @Sendable () async -> Void
    typealias EnvironmentFactory = @Sendable () async -> AnalyticsEnvironment

    private static let productionEnvironment: EnvironmentFactory = { await AnalyticsEnvironment.production() }

    private let operations: AsyncStream<Operation>.Continuation
    private let lock = NSLock()
    /// The engine for this run, once something started it. Guarded by `lock`.
    private var slot: EngineSlot?
    /// Options from `start(options:)`. Guarded by `lock`.
    private var startOptions: LoopAnalyticsOptions?
    /// Builds the next engine's environment. Guarded by `lock`.
    private var makeEnvironment: EnvironmentFactory = AnalyticsRuntime.productionEnvironment

    private init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Operation.self)
        operations = continuation
        Task.detached(priority: .utility) {
            for await operation in stream { await operation() }
        }
    }

    var published: PublishedIdentity? {
        lock.lock()
        let slot = self.slot
        lock.unlock()
        return slot?.engine?.published
    }

    func start(options: LoopAnalyticsOptions) {
        lock.lock(); defer { lock.unlock() }
        guard slot == nil, startOptions == nil else {
            Log.analytics.warning("LoopAnalytics.start(options:) ignored: analytics was already started")
            slot?.warnIfReconfigured()
            return
        }
        startOptions = options
        _ = startedSlot()
    }

    /// Queues `body` to run on the engine after every earlier call. Dropped
    /// before `Loop.configure`.
    func enqueue(_ body: @escaping @Sendable (AnalyticsEngine) async -> Void) {
        _ = enqueueOperation { engine in
            if let engine { await body(engine) }
        }
    }

    /// `enqueue`, then waits for `body` to finish and returns its result;
    /// nil when the call was dropped.
    func perform<T: Sendable>(_ body: @escaping @Sendable (AnalyticsEngine) async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let queued = enqueueOperation { engine in
                var result: T?
                if let engine { result = await body(engine) }
                continuation.resume(returning: result)
            }
            if !queued { continuation.resume(returning: nil) }
        }
    }

    /// Test hook: returns once every call queued so far has run.
    func waitForPendingCalls() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            operations.yield { continuation.resume() }
        }
    }

    func resetForTesting(environment: EnvironmentFactory?) {
        lock.lock(); defer { lock.unlock() }
        let previous = slot
        slot = nil
        startOptions = nil
        makeEnvironment = environment ?? Self.productionEnvironment
        operations.yield { await previous?.engine?.dispose() }
    }

    /// Queues `operation` with the engine it should run on (nil if the engine
    /// could not be built). Returns false, queuing nothing, before
    /// `Loop.configure`.
    private func enqueueOperation(_ operation: @escaping @Sendable (AnalyticsEngine?) async -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let slot = startedSlot() else { return false }
        slot.warnIfReconfigured()
        operations.yield { await operation(slot.engine) }
        return true
    }

    /// The running engine's slot, starting the engine if `Loop.configure` has
    /// been called and nothing started it yet. Call with `lock` held.
    private func startedSlot() -> EngineSlot? {
        if let slot { return slot }
        // Read before the configuration, so a `Loop.configure` racing with
        // this can only cause a needless warning, never hide a real one.
        let version = LoopRuntime.shared.configurationVersion
        guard let configuration = LoopRuntime.shared.configuration else { return nil }
        let slot = EngineSlot(configurationVersion: version)
        self.slot = slot
        let options = startOptions ?? LoopAnalyticsOptions()
        let makeEnvironment = self.makeEnvironment
        // Queued first, so every call queued after it finds the engine built.
        operations.yield {
            slot.engine = await AnalyticsEngine(
                apiKey: configuration.apiKey,
                serverUrl: configuration.options.serverUrl,
                options: options,
                environment: await makeEnvironment()
            )
        }
        return slot
    }
}

/// Holds the engine once its (asynchronous) start has run, and the
/// `Loop.configure` it was built from.
final class EngineSlot: @unchecked Sendable {
    /// `LoopRuntime.configurationVersion` when the engine was built.
    private let configurationVersion: Int
    private let lock = NSLock()
    private var _engine: AnalyticsEngine?
    private var warnedAboutReconfigure = false

    init(configurationVersion: Int) {
        self.configurationVersion = configurationVersion
    }

    var engine: AnalyticsEngine? {
        get { lock.lock(); defer { lock.unlock() }; return _engine }
        set { lock.lock(); defer { lock.unlock() }; _engine = newValue }
    }

    /// Logs once if `Loop.configure` was called again after this engine was
    /// built: the engine keeps its original key and server.
    func warnIfReconfigured() {
        guard LoopRuntime.shared.configurationVersion != configurationVersion else { return }
        lock.lock()
        let warn = !warnedAboutReconfigure
        warnedAboutReconfigure = true
        lock.unlock()
        guard warn else { return }
        Log.analytics.warning("Loop.configure was called again after analytics started; analytics keeps the API key and server it started with. Call Loop.configure once, at launch.")
    }
}
