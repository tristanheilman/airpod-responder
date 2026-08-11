import Foundation
import Testing
@testable import NavigatorCore

// Note: `#expect` expands its argument into a closure whose captured receiver is
// immutable, so `mutating` calls cannot appear inside the macro. Every consume /
// admit below is hoisted into a local for that reason, not for readability.

@Suite struct TokenBucketBehavior {
    let t0 = Date(timeIntervalSince1970: 0)

    @Test func consumesUntilEmpty() {
        var bucket = TokenBucket(capacity: 2, refillPerSecond: 0, startingAt: t0)
        let first = bucket.tryConsume(at: t0)
        let second = bucket.tryConsume(at: t0)
        let third = bucket.tryConsume(at: t0)
        #expect(first)
        #expect(second)
        #expect(!third)
    }

    @Test func refillsOverTime() {
        var bucket = TokenBucket(capacity: 1, refillPerSecond: 1.0 / 300.0, startingAt: t0)
        let first = bucket.tryConsume(at: t0)
        let tooSoon = bucket.tryConsume(at: t0.addingTimeInterval(299))
        let refilled = bucket.tryConsume(at: t0.addingTimeInterval(300))
        #expect(first)
        #expect(!tooSoon)
        #expect(refilled)
    }

    @Test func doesNotRefillAboveCapacity() {
        var bucket = TokenBucket(capacity: 1, refillPerSecond: 1.0 / 300.0, startingAt: t0)
        // An hour of idling must not bank twelve utterances.
        let first = bucket.tryConsume(at: t0.addingTimeInterval(3600))
        let second = bucket.tryConsume(at: t0.addingTimeInterval(3600))
        #expect(first)
        #expect(!second)
    }

    @Test func clockGoingBackwardsDoesNotGrantTokens() {
        var bucket = TokenBucket(capacity: 1, refillPerSecond: 1.0 / 300.0, startingAt: t0)
        let first = bucket.tryConsume(at: t0)
        let backwards = bucket.tryConsume(at: t0.addingTimeInterval(-600))
        #expect(first)
        #expect(!backwards)
    }
}

@Suite struct SpeechBudgetBehavior {
    let t0 = Date(timeIntervalSince1970: 0)

    @Test func blockingSpeechIsFree() {
        var budget = SpeechBudget(startingAt: t0)
        // Ten in a row, no degradation: the agent is already stopped.
        for _ in 0..<10 {
            let delivered = budget.admit(.decisionPoint, at: t0)
            #expect(delivered == .decisionPoint)
        }
    }

    @Test func firstNonBlockingUtteranceIsAdmitted() {
        var budget = SpeechBudget(startingAt: t0)
        let delivered = budget.admit(.speak, at: t0)
        #expect(delivered == .speak)
    }

    @Test func secondUtteranceDegradesToEarcon() {
        var budget = SpeechBudget(startingAt: t0)
        _ = budget.admit(.speak, at: t0)
        let second = budget.admit(.speak, at: t0.addingTimeInterval(1))
        #expect(second == .earcon)
    }

    @Test func budgetRecoversAfterTheInterval() {
        var budget = SpeechBudget(startingAt: t0)
        _ = budget.admit(.speak, at: t0)
        let later = budget.admit(.speak, at: t0.addingTimeInterval(300))
        #expect(later == .speak)
    }

    @Test func needsInputIsRationedToo() {
        var budget = SpeechBudget(startingAt: t0)
        _ = budget.admit(.needsInput, at: t0)
        let second = budget.admit(.needsInput, at: t0.addingTimeInterval(1))
        #expect(second == .earcon)
    }

    @Test func nonSpeechTiersPassThroughUntouched() {
        var budget = SpeechBudget(startingAt: t0)
        let earcon = budget.admit(.earcon, at: t0)
        let queued = budget.admit(.silentQueue, at: t0)
        let silent = budget.admit(.silent, at: t0)
        // And none of that consumed the speech budget.
        let speech = budget.admit(.speak, at: t0)

        #expect(earcon == .earcon)
        #expect(queued == .silentQueue)
        #expect(silent == .silent)
        #expect(speech == .speak)
    }

    @Test func blockingSpeechDoesNotDrainTheBudgetForOthers() {
        var budget = SpeechBudget(startingAt: t0)
        _ = budget.admit(.decisionPoint, at: t0)
        let speech = budget.admit(.speak, at: t0)
        #expect(speech == .speak)
    }
}
