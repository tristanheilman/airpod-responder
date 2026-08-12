import Foundation

/// Every number here is a guess pending replay data. They are gathered in one
/// place so the harness can sweep them.
public struct PolicyConfig: Sendable, Equatable {
    public var speechCapacity: Double
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
        speechInterval: TimeInterval = 300,
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
