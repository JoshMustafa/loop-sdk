import Foundation

/// Pure sanitization rules for analytics events. Runs synchronously on the
/// caller's thread (props arrive as `[String: Any]`, which can't cross into
/// the engine actor), so everything here must stay cheap.
enum RetentionSanitizer {
    /// Names longer than this are dropped rather than truncated — an
    /// over-long name is almost always a bug (interpolated payload, stack
    /// trace, …) and truncating would mint a garbage-but-stable event name.
    static let maxNameLength = 64
    /// Props beyond this cap are dropped, keeping the alphabetically-first
    /// keys so the survivors are deterministic rather than hash-ordered.
    static let maxProps = 16
    /// String prop values are truncated to this many characters.
    static let maxStringLength = 256

    /// Normalizes an event name to lowercase snake_case: lowercases,
    /// converts spaces/hyphens/dots to underscores, strips anything outside
    /// `[a-z0-9_]`, collapses runs of underscores, and trims edge
    /// underscores. Returns `nil` (⇒ drop the event) when nothing valid
    /// remains or the result exceeds `maxNameLength`.
    static func sanitizeName(_ raw: String) -> String? {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out = String.UnicodeScalarView()
        for scalar in lowered.unicodeScalars {
            switch scalar {
            case "a"..."z", "0"..."9", "_":
                out.append(scalar)
            case " ", "-", ".":
                out.append("_")
            default:
                break // strip
            }
        }
        var name = String(out)
        while name.contains("__") {
            name = name.replacingOccurrences(of: "__", with: "_")
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        guard !name.isEmpty, name.count <= maxNameLength else { return nil }
        return name
    }

    /// Filters props down to scalar values (String/Int/Double/Bool),
    /// truncates strings to `maxStringLength`, and caps the dictionary at
    /// `maxProps` entries (alphabetically-first keys win).
    static func sanitizeProps(_ raw: [String: Any]?) -> [String: RetentionPropValue]? {
        guard let raw else { return nil }
        var out: [String: RetentionPropValue] = [:]
        for key in raw.keys.sorted() {
            if out.count >= maxProps { break }
            guard let raw = raw[key], let value = sanitizeValue(raw) else { continue }
            out[key] = value
        }
        return out
    }

    private static func sanitizeValue(_ value: Any) -> RetentionPropValue? {
        // Bool before Int/Double: NSNumber-bridged booleans would otherwise
        // be misread as integers.
        switch value {
        case let string as String:
            return .string(String(string.prefix(maxStringLength)))
        case let bool as Bool:
            return .bool(bool)
        case let int as Int:
            return .int(int)
        case let double as Double:
            return .double(double)
        default:
            return nil
        }
    }
}
