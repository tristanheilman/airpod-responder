import Foundation

public struct Decision: Sendable, Equatable {
    /// What actually happens — after mute, budget and concurrency have had
    /// their say.
    public let tier: Tier
    /// What the classifier asked for, before any of that.
    ///
    /// Both are needed downstream: a delivered `.silent` means "routine, ignore
    /// it" when that is also what was intended, and "you missed this" when it
    /// was not. Collapsing them makes catch-up unable to report the one thing
    /// it exists for.
    public let intendedTier: Tier
    public let permission: PermissionDecision?
    public let utterance: String?
    public let reason: String
    public let blocking: Bool

    public init(
        tier: Tier, intendedTier: Tier? = nil, permission: PermissionDecision?,
        utterance: String?, reason: String, blocking: Bool
    ) {
        self.tier = tier
        self.intendedTier = intendedTier ?? tier
        self.permission = permission
        self.utterance = utterance
        self.reason = reason
        self.blocking = blocking
    }

    /// True when something was meant to reach you and did not.
    public var wasSuppressed: Bool { tier != intendedTier }
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
