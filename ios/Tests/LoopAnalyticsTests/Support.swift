import Foundation
import LoopCore
@testable import LoopAnalytics

extension LoopEvent {
    /// A fixed event for queue tests (port of the Dart `testEvent` helper).
    static func sample(
        id: String,
        name: String = "Test Event",
        props: JSONObject = [:],
        context: JSONObject? = nil
    ) -> LoopEvent {
        LoopEvent(
            id: id,
            name: name,
            occurredAtMillis: 1_791_968_400_000, // 2026-10-14T09:00:00.000Z
            sessionId: 1_760_432_400_000,
            deviceId: "device-1",
            userId: nil,
            props: props,
            userProps: [:],
            context: context
        )
    }
}

extension JSONValue {
    /// The value as a Foundation object for `JSONSerialization`.
    func foundation() -> Any {
        switch self {
        case .string(let s): return s
        case .number(let d): return NSNumber(value: d)
        case .int(let i): return NSNumber(value: i)
        case .bool(let b): return NSNumber(value: b)
        case .null: return NSNull()
        case .array(let a): return a.map { $0.foundation() }
        case .object(let o): return o.foundation()
        }
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    /// The object as a Foundation dictionary for `JSONSerialization`.
    func foundation() -> [String: Any] {
        mapValues { $0.foundation() }
    }
}

/// A settable clock. Thread-safe: the test sets it while the engine reads it.
final class FakeClock: LoopClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Int64

    init(_ now: Int64) { _now = now }

    var now: Int64 {
        get { lock.lock(); defer { lock.unlock() }; return _now }
        set { lock.lock(); defer { lock.unlock() }; _now = newValue }
    }

    func nowMillis() -> Int64 { now }
}

// MARK: - Engine harness

/// A thread-safe counter for sequential ids (shared across restarts).
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

struct TimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { "Timed out waiting for \(what)" }
}

/// Records every upload and answers with the queued replies (default:
/// `202 {"accepted":<n>,"dropped":0}`). Usable without `await`.
final class RecordingTransport: AnalyticsTransport, @unchecked Sendable {
    enum Reply {
        case status(Int, headers: [String: String], body: String)
        case networkError
    }

    private let lock = NSLock()
    private var _requests: [Sent] = []
    private var replies: [Reply] = []
    /// How long the next request hangs, in ns.
    private var holdNext: UInt64?

    /// Every request so far, gzip-decoded.
    var requests: [Sent] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    /// Every event sent so far, in order.
    var sentEvents: [JSONObject] { requests.flatMap(\.events) }

    /// The names of every event sent so far, in order.
    var sentNames: [String] {
        sentEvents.compactMap { if case .string(let name)? = $0["name"] { return name } else { return nil } }
    }

    /// Queues the reply for the next request.
    func respond(_ status: Int, headers: [String: String] = [:], body: String = "") {
        lock.lock(); defer { lock.unlock() }
        replies.append(.status(status, headers: headers, body: body))
    }

    /// The next request fails with a network error.
    func failNext() {
        lock.lock(); defer { lock.unlock() }
        replies.append(.networkError)
    }

    /// The next request never completes on its own: it hangs until the
    /// uploader gives up on it (its request timeout) and cancels it.
    func hold() {
        hold(for: 3600)
    }

    /// The next request is answered only after `seconds` (real time).
    func hold(for seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        holdNext = UInt64(seconds * 1_000_000_000)
    }

    func send(_ request: URLRequest) async throws -> (Int, [String: String], Data) {
        let sent = try Sent(request)
        let (reply, held) = record(sent)
        if let held { try await Task.sleep(nanoseconds: held) }
        switch reply {
        case nil:
            return (202, [:], Data(#"{"accepted":\#(sent.events.count),"dropped":0}"#.utf8))
        case .status(let status, let headers, let body)?:
            return (status, Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) }), Data(body.utf8))
        case .networkError?:
            throw URLError(.notConnectedToInternet)
        }
    }

    /// Records `sent`; returns its queued reply and how long to hold it.
    private func record(_ sent: Sent) -> (Reply?, UInt64?) {
        lock.lock(); defer { lock.unlock() }
        _requests.append(sent)
        let held = holdNext
        holdNext = nil
        return (replies.isEmpty ? nil : replies.removeFirst(), held)
    }

    /// Polls (real time) until at least `n` requests were recorded.
    func waitForRequests(_ n: Int, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while requests.count < n {
            guard Date() < deadline else { throw TimedOut(what: "\(n) request(s); got \(requests.count)") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// A lifecycle the test drives with `emit`.
final class FakeLifecycle: LifecycleSource, @unchecked Sendable {
    private let lock = NSLock()
    private var foreground: Bool
    private var onChange: (@Sendable (Bool) -> Void)?
    private var _backgroundTasks: [String] = []
    private var _endedBackgroundTasks = 0

    init(isForeground: Bool = true) {
        foreground = isForeground
    }

    var isForeground: Bool {
        get { lock.lock(); defer { lock.unlock() }; return foreground }
        set { lock.lock(); defer { lock.unlock() }; foreground = newValue }
    }

    /// Names of the background tasks begun so far.
    var backgroundTasks: [String] {
        lock.lock(); defer { lock.unlock() }
        return _backgroundTasks
    }

    var endedBackgroundTasks: Int {
        lock.lock(); defer { lock.unlock() }
        return _endedBackgroundTasks
    }

    func start(_ onChange: @escaping @Sendable (Bool) -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.onChange = onChange
    }

    /// The app moves to the foreground (`true`) or the background.
    func emit(_ foreground: Bool) {
        lock.lock()
        self.foreground = foreground
        let onChange = self.onChange
        lock.unlock()
        onChange?(foreground)
    }

    func beginBackgroundTask(named name: String) -> @Sendable () -> Void {
        lock.lock(); defer { lock.unlock() }
        _backgroundTasks.append(name)
        return { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self._endedBackgroundTasks += 1
        }
    }
}

/// Periodic timers that fire only when the test advances the fake clock.
///
/// Every timer's state is read and written under `lock` only: cancelling
/// (from the engine) and advancing (from the test) can come from different
/// threads.
final class FakeScheduler: Scheduler, @unchecked Sendable {
    private struct Entry {
        let interval: Int64
        var due: Int64
        let tick: @Sendable () -> Void
        var cancelled = false
    }

    /// Cancels its entry through the scheduler, under the scheduler's lock.
    private final class Handle: Cancellable, @unchecked Sendable {
        private weak var scheduler: FakeScheduler?
        private let index: Int

        init(_ scheduler: FakeScheduler, _ index: Int) {
            self.scheduler = scheduler
            self.index = index
        }

        func cancel() { scheduler?.cancel(index) }
    }

    private let lock = NSLock()
    private let clock: FakeClock
    /// Guarded by `lock`. Entries are never removed, so an index stays valid.
    private var entries: [Entry] = []

    init(clock: FakeClock) {
        self.clock = clock
    }

    /// Timers scheduled and not cancelled.
    var activeTimers: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { !$0.cancelled }.count
    }

    /// The interval of every timer scheduled so far, in ms.
    var intervals: [Int64] {
        lock.lock(); defer { lock.unlock() }
        return entries.map(\.interval)
    }

    func every(_ seconds: TimeInterval, _ tick: @escaping @Sendable () -> Void) -> Cancellable {
        let interval = max(1, Int64((seconds * 1000).rounded()))
        let due = clock.now + interval
        lock.lock(); defer { lock.unlock() }
        entries.append(Entry(interval: interval, due: due, tick: tick))
        return Handle(self, entries.count - 1)
    }

    /// Moves the clock forward by `ms`, firing every periodic tick that comes
    /// due, in time order, with the clock set to the tick's due time.
    /// `settle` runs after each tick (e.g. `engine.waitUntilIdle()`).
    func advance(by ms: Int64, settle: () async -> Void) async {
        let target = clock.now + ms
        while let next = takeNextDue(upTo: target) {
            clock.now = next.due
            next.tick()
            await settle()
        }
        clock.now = target
    }

    /// The earliest tick due at or before `target` (ties in the order the
    /// timers were scheduled), with that timer already moved to its next
    /// due time.
    private func takeNextDue(upTo target: Int64) -> (due: Int64, tick: @Sendable () -> Void)? {
        lock.lock(); defer { lock.unlock() }
        let candidates = entries.indices.filter { !entries[$0].cancelled && entries[$0].due <= target }
        guard let index = candidates.min(by: { entries[$0].due < entries[$1].due }) else { return nil }
        let due = entries[index].due
        entries[index].due += entries[index].interval
        return (due, entries[index].tick)
    }

    private func cancel(_ index: Int) {
        lock.lock(); defer { lock.unlock() }
        entries[index].cancelled = true
    }
}

/// The conformance runner's device context, settable per test.
final class ContextBox: @unchecked Sendable {
    static let conformance = LoopContext(
        platform: "iOS",
        osName: "ios",
        osVersion: "18.0",
        appVersion: "1.0.0",
        appBuild: "1",
        deviceModel: "iPhone15,3",
        deviceManufacturer: "Apple",
        isTablet: false,
        locale: "en-GB"
    )

    private let lock = NSLock()
    private var _value = ContextBox.conformance

    var value: LoopContext {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

/// One engine over a fake environment: a temp-directory queue file, an
/// in-memory key-value store, a fake clock, transport, lifecycle and
/// scheduler, and sequential ids. `restarted()` builds a new engine over the
/// same storage, clock and id counters with a fresh lifecycle, scheduler and
/// (unless one is passed) transport.
final class EngineHarness: @unchecked Sendable {
    static let apiKey = "loop_pk_test"
    static let serverUrl = URL(string: "https://loop.test")!
    /// 2026-01-01T00:00:00.000Z
    static let clockStart: Int64 = 1_767_225_600_000

    let directory: URL
    let queueURL: URL
    let kv: MemoryKeyValueStore
    let clock: FakeClock
    let eventIds: Counter
    let deviceIds: Counter
    let context: ContextBox
    let transport: RecordingTransport
    let lifecycle: FakeLifecycle
    let scheduler: FakeScheduler
    let options: LoopAnalyticsOptions
    let requestTimeout: Duration
    private(set) var engine: AnalyticsEngine!

    /// - Parameter startEngine: false to only build the environment (e.g.
    ///   to hand it to the facade).
    convenience init(
        options: LoopAnalyticsOptions = LoopAnalyticsOptions(),
        requestTimeout: Duration = .milliseconds(500),
        startEngine: Bool = true
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loop_engine_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clock = FakeClock(Self.clockStart)
        self.init(
            directory: directory,
            kv: MemoryKeyValueStore(),
            clock: clock,
            eventIds: Counter(),
            deviceIds: Counter(),
            context: ContextBox(),
            transport: RecordingTransport(),
            options: options,
            requestTimeout: requestTimeout
        )
        if startEngine { await start() }
    }

    private init(
        directory: URL,
        kv: MemoryKeyValueStore,
        clock: FakeClock,
        eventIds: Counter,
        deviceIds: Counter,
        context: ContextBox,
        transport: RecordingTransport,
        options: LoopAnalyticsOptions,
        requestTimeout: Duration
    ) {
        self.directory = directory
        self.queueURL = directory.appendingPathComponent("analytics-queue.jsonl")
        self.kv = kv
        self.clock = clock
        self.eventIds = eventIds
        self.deviceIds = deviceIds
        self.context = context
        self.transport = transport
        self.lifecycle = FakeLifecycle() // every (re)start is in the foreground
        self.scheduler = FakeScheduler(clock: clock)
        self.options = options
        self.requestTimeout = requestTimeout
    }

    func environment() -> AnalyticsEnvironment {
        let eventIds = eventIds
        let deviceIds = deviceIds
        let context = context
        return AnalyticsEnvironment(
            clock: clock,
            transport: transport,
            queueURL: queueURL,
            kv: kv,
            context: { context.value },
            lifecycle: lifecycle,
            newEventId: { String(format: "00000000-0000-4000-8000-%012ld", eventIds.next()) },
            newDeviceId: { "DEVICE-\(deviceIds.next())R" },
            scheduler: scheduler,
            sdk: AnalyticsEnvironment.sdk,
            requestTimeout: requestTimeout
        )
    }

    private func start() async {
        engine = await AnalyticsEngine(
            apiKey: Self.apiKey,
            serverUrl: Self.serverUrl,
            options: options,
            environment: environment()
        )
    }

    /// A new engine over the same storage (the previous one should be
    /// disposed first). Every (re)start is in the foreground.
    func restarted(
        options: LoopAnalyticsOptions? = nil,
        context: ContextBox? = nil,
        transport: RecordingTransport? = nil
    ) async throws -> EngineHarness {
        let next = EngineHarness(
            directory: directory,
            kv: kv,
            clock: clock,
            eventIds: eventIds,
            deviceIds: deviceIds,
            context: context ?? self.context,
            transport: transport ?? RecordingTransport(),
            options: options ?? self.options,
            requestTimeout: requestTimeout
        )
        await next.start()
        return next
    }

    /// Moves the fake clock, firing due flush timers and settling after each.
    func advance(_ ms: Int64) async {
        await scheduler.advance(by: ms) { await self.engine.waitUntilIdle() }
    }

    /// The lines in the queue file.
    func queueFileLines() -> [String] {
        let text = (try? String(contentsOf: queueURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    func removeStorage() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Records what the module logs while it is alive (until `stop()`).
final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(level: Log.Level, message: String)] = []
    private var token: Int?

    init() {
        token = Log.addObserver { [weak self] level, message in self?.record(level, message) }
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        let token = self.token
        self.token = nil
        lock.unlock()
        if let token { Log.removeObserver(token) }
    }

    func messages(_ level: Log.Level) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.level == level }.map(\.message)
    }

    private func record(_ level: Log.Level, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        entries.append((level, message))
    }
}
