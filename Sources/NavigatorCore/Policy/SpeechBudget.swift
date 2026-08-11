import Foundation

/// Rations non-blocking speech.
///
/// The initial rate — one utterance per five minutes — is a guess. It is meant
/// to be replaced by a number the replay harness produces from real days, which
/// is why every degradation is recorded rather than silently applied.
public struct SpeechBudget: Sendable {
    private var bucket: TokenBucket

    public init(capacity: Double = 1, interval: TimeInterval = 300, startingAt: Date) {
        self.bucket = TokenBucket(
            capacity: capacity, refillPerSecond: 1 / interval, startingAt: startingAt)
    }

    /// Returns the tier that should actually be delivered.
    public mutating func admit(_ tier: Tier, at now: Date) -> Tier {
        guard tier.isSpeech else { return tier }
        // A hard block costs nothing you were not already losing, and buys back
        // the context switch. It is exempt, and it does not drain the bucket.
        if tier.isBlocking { return tier }
        return bucket.tryConsume(at: now) ? tier : .earcon
    }
}
