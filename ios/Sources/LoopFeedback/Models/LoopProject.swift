import Foundation

/// Lightweight project metadata returned by `GET /api/ingest/project`.
/// The SDK uses this to brand its UI (project name + accent colour) and to
/// learn which optional features the developer has switched on for this project.
public struct LoopProject: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let icon: String
    public let accent: String
    public let version: String

    /// Whether this project collects reporter email addresses.
    ///
    /// Mirrors `projects.collect_email`, which defaults to **false**. The point
    /// of that default is that a routine SDK bump can never start collecting
    /// PII — the decision ships with the developer's own project settings, not
    /// with a version number — so the SDK reads the flag here and only offers
    /// the post-submit email prompt when it is true.
    public let collectEmail: Bool

    public init(
        id: String,
        name: String,
        icon: String,
        accent: String,
        version: String,
        collectEmail: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.accent = accent
        self.version = version
        self.collectEmail = collectEmail
    }

    /// Hand-written so a missing `collectEmail` decodes as `false` rather than
    /// throwing. A newer SDK talking to a backend that predates the flag must
    /// still get its project blob — losing it would take the branded UI down
    /// with it — and "absent" has exactly one safe reading: not opted in.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decode(String.self, forKey: .icon)
        accent = try container.decode(String.self, forKey: .accent)
        version = try container.decode(String.self, forKey: .version)
        collectEmail = try container.decodeIfPresent(Bool.self, forKey: .collectEmail) ?? false
    }
}
