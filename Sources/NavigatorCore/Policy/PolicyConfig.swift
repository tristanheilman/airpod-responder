import Foundation

/// Every number here is a guess pending real use. They are gathered in one
/// place so the harness can sweep them and the config file can override them.
public struct PolicyConfig: Sendable, Equatable, Codable {
    public var speechCapacity: Double

    /// Seconds between non-blocking utterances.
    ///
    /// 60 rather than 300: the right value depends on how much interruption
    /// this particular person tolerates, which cannot be learned from a log of a
    /// silent day. Starting loose and tightening by feel is the only way to find
    /// it, and a too-quiet tool reads as broken rather than as restrained.
    public var speechInterval: TimeInterval

    public var failureWindow: TimeInterval
    public var thrashRepeatThreshold: Int
    public var thrashMinimumDuration: TimeInterval

    /// Whether decisions may reach Claude Code at all.
    ///
    /// Off for the observer build. The engine still computes and logs the real
    /// verdict, so the log shows exactly what would have happened — which is how
    /// this gets turned on with evidence rather than optimism.
    public var emitDecisions: Bool

    public init(
        speechCapacity: Double = 1,
        speechInterval: TimeInterval = 60,
        failureWindow: TimeInterval = 60,
        thrashRepeatThreshold: Int = 3,
        thrashMinimumDuration: TimeInterval = 180,
        emitDecisions: Bool = false
    ) {
        self.speechCapacity = speechCapacity
        self.speechInterval = speechInterval
        self.failureWindow = failureWindow
        self.thrashRepeatThreshold = thrashRepeatThreshold
        self.thrashMinimumDuration = thrashMinimumDuration
        self.emitDecisions = emitDecisions
    }

    public static let `default` = PolicyConfig()
}
