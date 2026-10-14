import Foundation
import LoopCore

/// One running analytics instance: wires the event store, identity,
/// sessions, uploader, flush timer and app lifecycle together (port of
/// `loop_analytics.dart`).
///
/// Never throws into the host app; problems are logged. Every call is a
/// no-op after `dispose()`. Background work it starts itself (startup flush,
/// timer ticks, lifecycle changes, flushes at `flushQueueSize`) is tracked so
/// `waitUntilIdle()` can wait for it.
actor AnalyticsEngine {
    /// Server limit on one event's wire JSON.
    static let maxEventBytes = 32 * 1024
    static let backgroundTaskName = "LoopAnalytics.flush"

    private let options: LoopAnalyticsOptions
    private let environment: AnalyticsEnvironment
    private let store: EventStore
    private let identity: IdentityStore
    private let session: SessionTracker
    private let uploader: Uploader
    private let gate: UploadGate
    private let work = BackgroundWork()
    private let sizeEncoder: JSONEncoder
    private var timer: Cancellable?
    private var disposed = false
    private var lastContext: ContextSnapshot?

    /// Device and session id, readable without awaiting the actor.
    nonisolated let published = PublishedIdentity()

    /// Loads the queue and identity, starts lifecycle observation and the
    /// flush timer, and uploads anything left from the previous run.
    init(apiKey: String, serverUrl: URL, options: LoopAnalyticsOptions, environment: AnalyticsEnvironment) async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            Log.analytics.error("The Loop API key is empty; analytics uploads will fail")
        }
        let store = await EventStore(fileURL: environment.queueURL, maxQueueSize: options.maxQueueSize)
        let identity = IdentityStore(
            kv: environment.kv,
            legacyDeviceId: options.legacyDeviceId,
            newDeviceId: environment.newDeviceId
        )
        let gate = UploadGate(optedOut: identity.optOut)
        let engine = EngineReference()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes

        self.options = options
        self.environment = environment
        self.store = store
        self.identity = identity
        self.session = SessionTracker(
            kv: environment.kv,
            minTimeBetweenSessionsMillis: Self.millis(options.minTimeBetweenSessions),
            clock: environment.clock
        )
        self.gate = gate
        self.sizeEncoder = encoder
        self.uploader = Uploader(
            store: store,
            transport: environment.transport,
            serverUrl: serverUrl,
            apiKey: key,
            // Only for queued events stored without a context snapshot.
            context: { await engine.value?.currentContext() ?? [:] },
            maxBatchSize: options.maxBatchSize,
            clock: environment.clock,
            isEnabled: { gate.isOpen },
            requestTimeout: environment.requestTimeout
        )
        engine.value = self
        await start()
    }

    private func start() async {
        let work = self.work
        let gate = self.gate
        environment.lifecycle.start { [weak self, weak lifecycle = environment.lifecycle] foreground in
            guard let self, !gate.isClosed else { return }
            // Begun before this callback returns, while the app is still
            // allowed to run.
            let finish = foreground ? nil : lifecycle?.beginBackgroundTask(named: Self.backgroundTaskName)
            work.spawn {
                await self.onLifecycle(foreground)
                finish?()
            }
        }
        if environment.lifecycle.isForeground { session.onForeground() }
        timer = environment.scheduler.every(options.flushInterval) { [weak self] in
            guard let self else { return }
            work.spawn { await self.onTick() }
        }
        publish()
        if await store.count > 0 {
            // Fixed before init returns, so the app's first track() cannot
            // join the batch left from the previous run.
            await uploader.primePendingBatch()
            flushInBackground()
        }
    }

    // MARK: - State

    var deviceId: String { identity.deviceId }
    var userId: String? { identity.userId }
    /// The current session's start time in ms since epoch.
    var sessionId: Int64? { session.sessionId }
    var isOptedOut: Bool { identity.optOut }

    /// Events stored and not yet acknowledged by the server.
    func queueLength() async -> Int { await store.count }

    // MARK: - Calls

    /// Records an event. Null property values are stripped. The event is on
    /// disk when this returns.
    func track(_ name: String, _ properties: JSONObject?) async {
        guard !disposed else { return }
        guard !identity.optOut else {
            Log.analytics.debug("Dropped event \"\(name)\": analytics is opted out")
            return
        }
        guard Sanitize.isValidEventName(name) else {
            // Logged publicly, so not the name itself: an invalid one may
            // not be a name the developer chose.
            let length = name.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
            Log.analytics.warning("Dropped event: its name is \(length) characters once trimmed; names must be 1–\(Sanitize.maxEventNameLength)")
            return
        }
        let event = LoopEvent(
            id: environment.newEventId(),
            name: name,
            occurredAtMillis: environment.clock.nowMillis(),
            sessionId: session.onEvent(),
            deviceId: identity.deviceId,
            userId: identity.userId,
            props: Sanitize.props(properties?.mapValues { $0 as Any? }),
            userProps: identity.userProperties,
            context: contextSnapshot()
        )
        publish()
        guard let size = try? sizeEncoder.encode(event.wireJSON()).count else {
            Log.analytics.error("Dropped event \"\(name)\": it could not be encoded as JSON")
            return
        }
        guard size <= Self.maxEventBytes else {
            Log.analytics.warning("Dropped event \"\(name)\": \(size) bytes exceeds the \(Self.maxEventBytes) byte limit")
            return
        }
        await store.add(event)
        if await store.count >= options.flushQueueSize { flushInBackground() }
    }

    /// The signed-in user's id; nil or empty means signed out.
    func setUserId(_ userId: String?) {
        guard !disposed else { return }
        identity.setUserId(Self.nonEmpty(userId))
    }

    /// Merges `properties` into the user-property snapshot sent with every
    /// event. A `.null` value removes that property.
    func setUserProperties(_ properties: JSONObject) {
        guard !disposed else { return }
        // Sanitising strips nulls (nested ones included), but a top-level
        // null here means "remove", so put those back.
        var merged = Sanitize.props(properties.mapValues { $0 as Any? })
        for (key, value) in properties where value == .null { merged[key] = .null }
        identity.mergeUserProperties(merged)
    }

    /// The RevenueCat app user id; nil or empty clears it.
    func setPurchaserId(_ purchaserId: String?) {
        guard !disposed else { return }
        identity.setPurchaserId(Self.nonEmpty(purchaserId))
    }

    /// Uploads queued events now. Returns when the queue is empty or an
    /// upload failed (the events stay queued and are retried with backoff).
    func flush() async {
        guard !disposed else { return }
        await uploader.flush()
    }

    /// A new random device id, no user id, user properties or purchaser id,
    /// and a new session. Queued events keep the identity they were tracked
    /// with. Opt-out is kept.
    func reset() {
        guard !disposed else { return }
        identity.reset()
        session.startNew()
        publish()
    }

    /// When true, new events are dropped and nothing is uploaded; queued
    /// events are kept and uploaded (at once) after opting back in.
    /// Persisted.
    func setOptOut(_ optOut: Bool) async {
        guard !disposed else { return }
        identity.setOptOut(optOut)
        gate.setOptedOut(optOut)
        if !optOut, await store.count > 0 { flushInBackground() }
    }

    /// Returns once no background work is running and no upload is in
    /// flight.
    func waitUntilIdle() async {
        repeat {
            await work.idle()
            await uploader.waitForInFlight()
        } while work.isBusy
    }

    /// Stops the timer and lifecycle handling and waits for the upload in
    /// flight, if any (bounded by the request timeout). Starts no new
    /// upload: queued events stay on disk for the next start.
    func dispose() async {
        guard !disposed else { return }
        disposed = true
        gate.close()
        timer?.cancel()
        timer = nil
        await waitUntilIdle()
    }

    // MARK: - Background work

    private func onLifecycle(_ foreground: Bool) async {
        guard !disposed else { return }
        if foreground {
            session.onForeground()
            publish()
            if await store.count > 0 { await uploader.flush() }
        } else {
            session.onBackground()
            publish()
            await uploader.flush()
        }
    }

    private func onTick() async {
        guard !disposed, await store.count > 0 else { return }
        await uploader.flush()
    }

    private func flushInBackground() {
        let uploader = self.uploader
        work.spawn { await uploader.flush() }
    }

    private func publish() {
        published.set(deviceId: identity.deviceId, sessionId: session.sessionId)
    }

    // MARK: - Context

    private struct ContextSnapshot {
        let context: LoopContext
        let purchaserId: String?
        let json: JSONObject
    }

    /// The batch `context` as of now. Reused while nothing changes.
    private func contextSnapshot() -> JSONObject {
        let context = environment.context()
        let purchaserId = identity.purchaserId
        if let last = lastContext, last.context == context, last.purchaserId == purchaserId {
            return last.json
        }
        // `LoopContext.json` holds Foundation values; sanitising turns them
        // into JSON but also strips the `NSNull` it uses for a missing
        // purchaser id, which the wire keeps as an explicit null.
        var json = Sanitize.props(context.json(purchaserId: purchaserId, sdk: environment.sdk))
        json["purchaserId"] = purchaserId.map(JSONValue.string) ?? .null
        lastContext = ContextSnapshot(context: context, purchaserId: purchaserId, json: json)
        return json
    }

    private func currentContext() -> JSONObject {
        contextSnapshot()
    }

    // MARK: - Helpers

    private static func nonEmpty(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return id
    }

    /// Seconds to whole milliseconds, clamped to `0...Int64.max`.
    private static func millis(_ seconds: TimeInterval) -> Int64 {
        let ms = (seconds * 1000).rounded()
        guard ms > 0 else { return 0 }
        guard ms < 9.2e18 else { return .max }
        return Int64(ms)
    }
}

/// Whether uploads may run: not opted out and not disposed. Read by the
/// uploader without awaiting the engine.
final class UploadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var optedOut: Bool
    private var closed = false

    init(optedOut: Bool) {
        self.optedOut = optedOut
    }

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return !optedOut && !closed
    }

    /// True once the engine is disposed.
    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    func setOptedOut(_ optedOut: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.optedOut = optedOut
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
    }
}

/// Tasks the engine starts on its own, so `waitUntilIdle()` can await them.
final class BackgroundWork: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var nextKey = 0

    var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return !tasks.isEmpty
    }

    func spawn(_ body: @escaping @Sendable () async -> Void) {
        lock.lock(); defer { lock.unlock() }
        let key = nextKey
        nextKey += 1
        // Registered under the lock, so the task's own removal (which takes
        // the lock) always comes after.
        tasks[key] = Task {
            await body()
            self.finished(key)
        }
    }

    /// Returns once every task, including ones started meanwhile, is done.
    func idle() async {
        while true {
            let pending = running()
            if pending.isEmpty { return }
            for task in pending { await task.value }
        }
    }

    private func running() -> [Task<Void, Never>] {
        lock.lock(); defer { lock.unlock() }
        return Array(tasks.values)
    }

    private func finished(_ key: Int) {
        lock.lock(); defer { lock.unlock() }
        tasks[key] = nil
    }
}

/// The engine's device and session id for synchronous readers.
final class PublishedIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var _deviceId: String?
    private var _sessionId: Int64?

    var deviceId: String? {
        lock.lock(); defer { lock.unlock() }
        return _deviceId
    }

    var sessionId: Int64? {
        lock.lock(); defer { lock.unlock() }
        return _sessionId
    }

    func set(deviceId: String, sessionId: Int64?) {
        lock.lock(); defer { lock.unlock() }
        _deviceId = deviceId
        _sessionId = sessionId
    }
}

/// Lets the uploader's context closure reach the engine created after it.
private final class EngineReference: @unchecked Sendable {
    private let lock = NSLock()
    private weak var engine: AnalyticsEngine?

    var value: AnalyticsEngine? {
        get { lock.lock(); defer { lock.unlock() }; return engine }
        set { lock.lock(); defer { lock.unlock() }; engine = newValue }
    }
}
