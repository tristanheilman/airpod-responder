import Foundation

/// Something the navigator had to say, whether or not it got to say it.
public struct Utterance: Sendable, Equatable {
    public let at: Date
    public let sessionName: String
    public let text: String
    public let tier: Tier
    /// False when the budget, mute, or the concurrency gate suppressed it.
    /// Recorded either way: catch-up exists for exactly the suppressed ones.
    public let wasSpoken: Bool

    public init(
        at: Date, sessionName: String, text: String, tier: Tier, wasSpoken: Bool
    ) {
        self.at = at
        self.sessionName = sessionName
        self.text = text
        self.tier = tier
        self.wasSpoken = wasSpoken
    }
}
