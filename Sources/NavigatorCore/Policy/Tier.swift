import Foundation

public enum Tier: String, Sendable, Codable, Equatable, CaseIterable {
    /// Speech, and the agent waits for the answer.
    case decisionPoint
    /// Speech: the agent is stopped and needs you.
    case needsInput
    /// Speech: worth saying, but nothing is blocked on it.
    case speak
    /// A sound, no words.
    case earcon
    /// Held for the next `status` request.
    case silentQueue
    /// Nothing at all.
    case silent

    public var isSpeech: Bool {
        switch self {
        case .decisionPoint, .needsInput, .speak: true
        case .earcon, .silentQueue, .silent: false
        }
    }

    public var isBlocking: Bool { self == .decisionPoint }
}

/// The engine's verdict on a tool call.
///
/// Only `allow` and `deny` exist on the wire. `defer` is engine-internal and is
/// rendered as *silence* — a hook that exits 0 with no output leaves the call to
/// the normal permission flow, which is exactly the fallback we want. There is
/// no `ask`: it has no wire representation, so modelling it would invent a
/// behaviour the hook cannot actually produce.
public enum PermissionDecision: String, Sendable, Codable, Equatable {
    case allow
    /// Never emitted by the engine — see `BlastRadiusInvariant`. Present only
    /// because the hook protocol defines it.
    case deny
    case `defer`
}

public struct TierVerdict: Sendable, Equatable {
    public let tier: Tier
    /// Only `PreToolUse` produces a permission verdict; nil for every other event.
    public let permission: PermissionDecision?
    public let reason: String

    public init(tier: Tier, permission: PermissionDecision?, reason: String) {
        self.tier = tier
        self.permission = permission
        self.reason = reason
    }
}
