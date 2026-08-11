import Foundation

public struct Decision: Sendable, Equatable {
    public let tier: Tier
    public let permission: PermissionDecision?
    public let utterance: String?
    public let reason: String
    public let blocking: Bool

    public init(
        tier: Tier, permission: PermissionDecision?,
        utterance: String?, reason: String, blocking: Bool
    ) {
        self.tier = tier
        self.permission = permission
        self.utterance = utterance
        self.reason = reason
        self.blocking = blocking
    }
}

/// One line of the decision log.
///
/// This is the primary deliverable alongside the engine itself. The budget and
/// thresholds are guesses; this record is how they get replaced with numbers.
public struct DecisionRecord: Sendable, Equatable, Codable {
    public let at: Date
    public let sessionID: String
    public let kind: HookEventKind
    public let toolName: String?
    public let reversibility: String
    public let route: String
    /// What the classifier asked for, before rationing.
    public let tierAssigned: Tier
    /// What actually happened.
    public let delivered: Tier
    public let suppressedBecause: String?
    public let permission: PermissionDecision?
    public let reason: String

    public init(
        at: Date, sessionID: String, kind: HookEventKind, toolName: String?,
        reversibility: String, route: String, tierAssigned: Tier, delivered: Tier,
        suppressedBecause: String?, permission: PermissionDecision?, reason: String
    ) {
        self.at = at
        self.sessionID = sessionID
        self.kind = kind
        self.toolName = toolName
        self.reversibility = reversibility
        self.route = route
        self.tierAssigned = tierAssigned
        self.delivered = delivered
        self.suppressedBecause = suppressedBecause
        self.permission = permission
        self.reason = reason
    }
}
