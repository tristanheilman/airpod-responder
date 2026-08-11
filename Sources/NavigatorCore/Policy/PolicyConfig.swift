import Foundation

/// Every number here is a guess pending replay data. They are gathered in one
/// place so the harness can sweep them.
public struct PolicyConfig: Sendable, Equatable {
    public var speechCapacity: Double
    public var speechInterval: TimeInterval
    public var failureWindow: TimeInterval
    public var thrashRepeatThreshold: Int
    public var thrashMinimumDuration: TimeInterval

    public init(
        speechCapacity: Double = 1,
        speechInterval: TimeInterval = 300,
        failureWindow: TimeInterval = 60,
        thrashRepeatThreshold: Int = 3,
        thrashMinimumDuration: TimeInterval = 180
    ) {
        self.speechCapacity = speechCapacity
        self.speechInterval = speechInterval
        self.failureWindow = failureWindow
        self.thrashRepeatThreshold = thrashRepeatThreshold
        self.thrashMinimumDuration = thrashMinimumDuration
    }

    public static let `default` = PolicyConfig()
}
