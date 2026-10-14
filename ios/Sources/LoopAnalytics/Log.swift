import os

/// The module's internal log. Read it with
/// `log stream --predicate 'subsystem == "io.loop.analytics"'` or in
/// Console.app; there is no public log-level setting yet.
enum Log {
    static let analytics = Logger(subsystem: "io.loop.analytics", category: "analytics")
}
