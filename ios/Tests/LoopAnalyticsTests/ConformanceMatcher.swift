import Foundation
@testable import LoopAnalytics

/// Matches recorded values against a conformance case's expected values
/// (port of `expectMatches` in the Dart reference runner; the rules are in
/// `conformance/README.md` under "Matching").
enum ConformanceMatcher {
    /// The first mismatch between `actual` and `expected`, or nil when they
    /// match. `root` is what `$sameAs` paths resolve against; `path` names
    /// the value in the message.
    static func mismatch(_ actual: JSONValue?, _ expected: JSONValue, root: JSONValue, path: String) -> String? {
        if case .string(let token) = expected {
            switch token {
            case "<uuid>":
                guard case .string(let s)? = actual, s.range(of: uuidPattern, options: .regularExpression) != nil else {
                    return "\(path): expected a UUID, got \(describe(actual))"
                }
                return nil
            case "<int>":
                guard case .int? = actual else { return "\(path): expected an int, got \(describe(actual))" }
                return nil
            case "<iso8601>":
                guard case .string(let s)? = actual, s.range(of: iso8601Pattern, options: .regularExpression) != nil else {
                    return "\(path): expected an ISO-8601 string, got \(describe(actual))"
                }
                return nil
            case "<any>":
                return nil
            default:
                break
            }
        }

        switch expected {
        case .object(let want):
            if let length = want["$stringLength"] {
                // Dart's String.length counts UTF-16 code units.
                guard case .string(let s)? = actual, equal(.int(Int64(s.utf16.count)), length) else {
                    let got: String
                    if case .string(let s)? = actual { got = "length \(s.utf16.count)" } else { got = describe(actual) }
                    return "\(path): expected a string of length \(describe(length)), got \(got)"
                }
                return nil
            }
            if case .string(let source)? = want["$sameAs"] {
                guard let resolved = resolve(source, in: root) else { return "$sameAs: no \(source)" }
                guard let actual, equal(actual, resolved) else {
                    return "\(path): expected the same as \(source) (\(describe(resolved))), got \(describe(actual))"
                }
                return nil
            }
            guard case .object(let got)? = actual else { return "\(path): expected an object, got \(describe(actual))" }
            let partial = want["$partial"] == .bool(true)
            let keys = Set(want.keys).subtracting(["$partial"])
            if !partial {
                let missing = keys.subtracting(got.keys)
                let extra = Set(got.keys).subtracting(keys)
                if !missing.isEmpty || !extra.isEmpty {
                    return "\(path): key mismatch (missing \(missing.sorted()), unexpected \(extra.sorted())) in \(describe(actual))"
                }
            }
            for key in keys.sorted() {
                guard let value = got[key] else { return "\(path): missing key \"\(key)\" in \(describe(actual))" }
                if let failure = mismatch(value, want[key]!, root: root, path: "\(path).\(key)") { return failure }
            }
            return nil

        case .array(let want):
            guard case .array(let got)? = actual else { return "\(path): expected an array, got \(describe(actual))" }
            guard got.count == want.count else {
                return "\(path): expected \(want.count) element(s), got \(got.count): \(describe(actual))"
            }
            for (i, element) in want.enumerated() {
                if let failure = mismatch(got[i], element, root: root, path: "\(path)[\(i)]") { return failure }
            }
            return nil

        default:
            guard let actual, equal(actual, expected) else {
                return "\(path): expected \(describe(expected)), got \(describe(actual))"
            }
            return nil
        }
    }

    /// Deep equality where an integer and a double with the same value are
    /// equal (as in Dart, where `1 == 1.0`).
    static func equal(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.int(let x), .number(let y)), (.number(let y), .int(let x)):
            return Double(x) == y
        case (.array(let x), .array(let y)):
            return x.count == y.count && zip(x, y).allSatisfy { equal($0, $1) }
        case (.object(let x), .object(let y)):
            return x.count == y.count && x.allSatisfy { key, value in y[key].map { equal(value, $0) } ?? false }
        default:
            return a == b
        }
    }

    /// Resolves a path like `requests[0].events` against `root`.
    static func resolve(_ path: String, in root: JSONValue) -> JSONValue? {
        guard let regex = try? NSRegularExpression(pattern: #"([^.\[\]]+)|\[(\d+)\]"#) else { return nil }
        var node = root
        let ns = path as NSString
        for match in regex.matches(in: path, range: NSRange(location: 0, length: ns.length)) {
            if match.range(at: 2).location != NSNotFound {
                guard case .array(let list) = node,
                      let i = Int(ns.substring(with: match.range(at: 2))),
                      i < list.count
                else { return nil }
                node = list[i]
            } else {
                guard case .object(let map) = node, let next = map[ns.substring(with: match.range(at: 1))] else { return nil }
                node = next
            }
        }
        return node
    }

    /// `value` as compact JSON for failure messages.
    static func describe(_ value: JSONValue?) -> String {
        guard let value else { return "<absent>" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), var text = String(data: data, encoding: .utf8) else {
            return "\(value)"
        }
        if text.count > 2000 { text = String(text.prefix(2000)) + "…" }
        return text
    }

    private static let uuidPattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
    private static let iso8601Pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$"#
}
