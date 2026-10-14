import Foundation

/// Renders a `Breadcrumb` into the JSON-ready dictionary shape the ingest
/// contract expects: `{ "t": "-6.1s", "msg": "…", "fail": true }`.
///
/// `t` is the crumb's age relative to the capture moment, formatted to one
/// decimal place with a trailing `s`. A crumb 6.1s before capture renders
/// `"-6.1s"`; the most recent crumb renders near `"0.0s"`. The `fail` key is
/// included only when true (a false flag is omitted to keep payloads lean).
enum BreadcrumbFormatter {
    static func render(_ crumb: Breadcrumb, relativeTo capture: Date) -> [String: Any] {
        let delta = crumb.timestamp.timeIntervalSince(capture) // <= 0
        var dict: [String: Any] = [
            "t": relativeString(delta),
            "msg": crumb.message
        ]
        if crumb.fail {
            dict["fail"] = true
        }
        return dict
    }

    /// Formats a (non-positive) delta in seconds as e.g. "-6.1s" / "0.0s".
    /// Rounds to one decimal; values that round to zero render "0.0s"
    /// (no negative-zero sign).
    static func relativeString(_ delta: TimeInterval) -> String {
        let rounded = (delta * 10).rounded() / 10
        let normalized = rounded == 0 ? 0 : rounded
        return String(format: "%.1fs", normalized)
    }
}
