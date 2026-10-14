import Foundation

/// Vote direction for an item or reply.
public enum VoteDir: String, Codable, Sendable, Equatable {
    case up
    case down
}

/// Response from the vote endpoint.
public struct LoopVoteResult: Codable, Sendable, Equatable {
    public let id: String
    public let votes: Int
    public let my: VoteDir?
}

/// Response from the submission endpoint.
public struct LoopSubmissionResult: Codable, Sendable, Equatable {
    public let id: String
    public let kind: LoopItem.Kind
    public let status: LoopItem.Status
}
