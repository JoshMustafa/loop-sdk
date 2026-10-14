import XCTest
import LoopCore
@testable import LoopAnalytics

/// Runs the shared conformance cases (`conformance/cases/analytics`) against
/// `AnalyticsEngine`. The case format is defined in `conformance/README.md`;
/// the Dart reference runner is `loop-sdk-flutter/test/conformance_test.dart`.
final class ConformanceTests: XCTestCase {
    /// Cases in the suite today; fewer loaded means the path is wrong.
    static let minimumCaseCount = 28

    /// Cases this SDK is known to fail, by file name (without `.json`), with
    /// the reason. They stay in the suite and are skipped here only.
    static let knownFailures: [String: String] = [:]

    /// `<repo>/conformance/cases/analytics`, found from this file's path.
    static let casesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // LoopAnalyticsTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // ios
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("conformance/cases/analytics", isDirectory: true)

    static func caseFiles() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: casesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func test_runner_finds_all_cases() throws {
        let files = try Self.caseFiles()
        XCTAssertGreaterThanOrEqual(
            files.count, Self.minimumCaseCount,
            "Only \(files.count) case file(s) in \(Self.casesDirectory.path)"
        )
    }

    @MainActor
    func test_all_conformance_cases() async throws {
        let files = try Self.caseFiles()
        guard files.count >= Self.minimumCaseCount else {
            XCTFail("Only \(files.count) case file(s) in \(Self.casesDirectory.path)")
            return
        }
        for file in files {
            let slug = file.deletingPathExtension().lastPathComponent
            let spec: JSONObject
            do {
                spec = try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: file))
            } catch {
                XCTFail("\(slug): unreadable case file: \(error)")
                continue
            }
            var title = slug
            if case .string(let name)? = spec["name"] { title += ": \(name)" }
            if let reason = Self.knownFailures[slug] {
                XCTContext.runActivity(named: "\(title) (skipped: \(reason))") { _ in }
                continue
            }
            let failure = await ConformanceCaseRunner(spec).run()
            // `runActivity` takes a synchronous block, so the case runs
            // first and its failure is reported inside the activity.
            XCTContext.runActivity(named: title) { _ in
                if let failure { XCTFail("\(slug): \(failure)") }
            }
        }
    }
}

/// A case step or expectation that did not hold. Ends the case.
private struct CaseFailure: Error {
    let message: String
}

/// Drives one case. Storage, the clock, the id counters and the request log
/// live in the harness and survive `restart`.
private final class ConformanceCaseRunner {
    static let endpointPath = "/api/ingest/analytics/batch"
    static let optionKeys: Set<String> = [
        "flushQueueSize", "flushIntervalMs", "minTimeBetweenSessionsMs",
        "maxQueueSize", "maxBatchSize", "legacyDeviceId",
    ]

    private let spec: JSONObject
    private var h: EngineHarness!

    init(_ spec: JSONObject) {
        self.spec = spec
    }

    /// Runs the case; returns the first failure, or nil when it passed.
    func run() async -> String? {
        var failure: String?
        do {
            h = try await EngineHarness(options: try Self.options(spec["options"]))
            await h.engine.waitUntilIdle()
            let steps = try Self.array(spec["steps"] ?? .array([]), "steps")
            for (i, step) in steps.enumerated() {
                let step = try Self.object(step, "steps[\(i)]")
                let op = step["op"].flatMap(Self.string) ?? "?"
                try await perform(step, where: "steps[\(i)] (\(op))")
                await h.engine.waitUntilIdle()
            }
            try checkEveryRequest()
            try await checkExpect(try Self.object(spec["expect"] ?? .object([:]), "expect"))
        } catch let error as CaseFailure {
            failure = error.message
        } catch {
            failure = "\(error)"
        }
        if let h {
            await h.engine?.dispose()
            h.removeStorage()
        }
        return failure
    }

    // MARK: - Steps

    private func perform(_ step: JSONObject, where at: String) async throws {
        let engine = h.engine!
        switch step["op"].flatMap(Self.string) {
        case "track":
            var props: JSONObject? = try step["props"].map { try Self.object($0, "\(at).props") }
            if let fill = step["fill"] {
                let fill = try Self.object(fill, "\(at).fill")
                guard let key = fill["key"].flatMap(Self.string), case .int(let count)? = fill["count"] else {
                    throw CaseFailure(message: "\(at): fill needs a string key and an int count")
                }
                props = props ?? [:]
                props![key] = .string(String(repeating: "x", count: Int(count)))
            }
            await engine.track(try Self.requiredString(step["name"], "\(at).name"), props)
        case "setUserId":
            await engine.setUserId(step["userId"].flatMap(Self.string))
        case "setUserProperties":
            await engine.setUserProperties(try Self.object(step["props"] ?? .null, "\(at).props"))
        case "setPurchaserId":
            await engine.setPurchaserId(step["purchaserId"].flatMap(Self.string))
        case "flush":
            await engine.flush()
        case "reset":
            await engine.reset()
        case "setOptOut":
            guard case .bool(let optOut)? = step["optOut"] else { throw CaseFailure(message: "\(at): optOut must be a bool") }
            await engine.setOptOut(optOut)
        case "advance":
            await h.advance(try Self.int(step["ms"], "\(at).ms"))
        case "lifecycle":
            switch step["state"].flatMap(Self.string) {
            case "foreground": h.lifecycle.emit(true)
            case "background": h.lifecycle.emit(false)
            default: throw CaseFailure(message: "\(at): unknown lifecycle state \(ConformanceMatcher.describe(step["state"]))")
            }
        case "respond":
            if step["error"].flatMap(Self.string) == "network" {
                h.transport.failNext()
            } else {
                var headers: [String: String] = [:]
                for (name, value) in try Self.object(step["headers"] ?? .object([:]), "\(at).headers") {
                    headers[name] = try Self.requiredString(value, "\(at).headers.\(name)")
                }
                h.transport.respond(
                    Int(try Self.int(step["status"], "\(at).status")),
                    headers: headers,
                    body: step["body"].flatMap(Self.string) ?? ""
                )
            }
        case "restart":
            // Explicit options replace the case options; absent, they stay
            // (nil keeps the harness's options).
            let options = try step["options"].map { try Self.options($0) }
            await engine.dispose()
            h = try await h.restarted(options: options, transport: h.transport)
        case "check":
            if let want = step["requests"] {
                let n = try Self.int(want, "\(at).requests")
                let got = h.transport.requests.count
                guard got == n else { throw CaseFailure(message: "\(at): requests so far: expected \(n), got \(got)") }
            }
            if let want = step["queueLength"] {
                let n = try Self.int(want, "\(at).queueLength")
                let got = await engine.queueLength()
                guard got == n else { throw CaseFailure(message: "\(at): queued events: expected \(n), got \(got)") }
            }
        default:
            throw CaseFailure(message: "\(at): unknown op")
        }
    }

    // MARK: - Expectations

    private func checkEveryRequest() throws {
        for (i, sent) in h.transport.requests.enumerated() {
            let request = sent.request
            let path = request.url?.path
            guard path == Self.endpointPath else {
                throw CaseFailure(message: "requests[\(i)] path: expected \(Self.endpointPath), got \(path ?? "nil")")
            }
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            guard authorization == "Bearer \(EngineHarness.apiKey)" else {
                throw CaseFailure(message: "requests[\(i)] Authorization: got \(authorization ?? "nil")")
            }
            let encoding = request.value(forHTTPHeaderField: "Content-Encoding")
            guard encoding == "gzip" else {
                throw CaseFailure(message: "requests[\(i)] Content-Encoding: got \(encoding ?? "nil")")
            }
        }
    }

    private func checkExpect(_ expect: JSONObject) async throws {
        let bodies = JSONValue.array(h.transport.requests.map { .object($0.body) })
        if let want = expect["requests"] {
            if let failure = ConformanceMatcher.mismatch(bodies, want, root: .object(["requests": bodies]), path: "requests") {
                throw CaseFailure(message: failure)
            }
        }
        if let want = expect["queueLength"] {
            let n = try Self.int(want, "expect.queueLength")
            let got = await h.engine.queueLength()
            guard got == n else { throw CaseFailure(message: "expect.queueLength: expected \(n), got \(got)") }
        }
    }

    // MARK: - Case JSON

    /// The case's `options` (all keys optional) as engine options.
    private static func options(_ value: JSONValue?) throws -> LoopAnalyticsOptions {
        let o = try object(value ?? .object([:]), "options")
        let unknown = Set(o.keys).subtracting(optionKeys)
        guard unknown.isEmpty else { throw CaseFailure(message: "Unknown options: \(unknown.sorted())") }
        var options = LoopAnalyticsOptions()
        if let v = o["flushQueueSize"] { options.flushQueueSize = Int(try int(v, "options.flushQueueSize")) }
        if let v = o["flushIntervalMs"] { options.flushInterval = Double(try int(v, "options.flushIntervalMs")) / 1000 }
        if let v = o["minTimeBetweenSessionsMs"] {
            options.minTimeBetweenSessions = Double(try int(v, "options.minTimeBetweenSessionsMs")) / 1000
        }
        if let v = o["maxQueueSize"] { options.maxQueueSize = Int(try int(v, "options.maxQueueSize")) }
        if let v = o["maxBatchSize"] { options.maxBatchSize = Int(try int(v, "options.maxBatchSize")) }
        options.legacyDeviceId = o["legacyDeviceId"].flatMap(string)
        return options
    }

    private static func string(_ value: JSONValue) -> String? {
        if case .string(let s) = value { return s }
        return nil
    }

    private static func requiredString(_ value: JSONValue?, _ what: String) throws -> String {
        guard let value, let s = string(value) else { throw CaseFailure(message: "\(what): expected a string") }
        return s
    }

    private static func int(_ value: JSONValue?, _ what: String) throws -> Int64 {
        guard case .int(let n)? = value else { throw CaseFailure(message: "\(what): expected an int") }
        return n
    }

    private static func object(_ value: JSONValue, _ what: String) throws -> JSONObject {
        guard case .object(let o) = value else { throw CaseFailure(message: "\(what): expected an object") }
        return o
    }

    private static func array(_ value: JSONValue, _ what: String) throws -> [JSONValue] {
        guard case .array(let a) = value else { throw CaseFailure(message: "\(what): expected an array") }
        return a
    }
}
