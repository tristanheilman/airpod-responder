import Foundation

public struct TokenBucket: Sendable, Equatable {
    public private(set) var tokens: Double
    private let capacity: Double
    private let refillPerSecond: Double
    private var lastRefill: Date

    public init(capacity: Double, refillPerSecond: Double, startingAt: Date) {
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
        self.tokens = capacity
        self.lastRefill = startingAt
    }

    public mutating func tryConsume(at now: Date) -> Bool {
        refill(to: now)
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }

    private mutating func refill(to now: Date) {
        let elapsed = now.timeIntervalSince(lastRefill)
        // A backwards clock must not mint tokens. Advance the marker anyway so
        // the bucket re-anchors rather than banking the gap when time recovers.
        guard elapsed > 0 else {
            lastRefill = now
            return
        }
        tokens = min(capacity, tokens + elapsed * refillPerSecond)
        lastRefill = now
    }
}
