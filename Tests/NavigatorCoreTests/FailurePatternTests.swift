import Foundation
import Testing
@testable import NavigatorCore

// Mutating calls are hoisted into locals throughout: `#expect` captures its
// receiver immutably and will not compile with a mutating call inside it.

@Suite struct FailureCoalescing {
    let t0 = Date(timeIntervalSince1970: 0)

    @Test func firstFailureInWindowIsAdmitted() {
        var coalescer = FailureCoalescer(window: 60)
        let admitted = coalescer.admit(sessionID: "s1", at: t0)
        #expect(admitted)
    }

    @Test func furtherFailuresInWindowAreSuppressed() {
        var coalescer = FailureCoalescer(window: 60)
        _ = coalescer.admit(sessionID: "s1", at: t0)
        let atTen = coalescer.admit(sessionID: "s1", at: t0.addingTimeInterval(10))
        let atFiftyNine = coalescer.admit(sessionID: "s1", at: t0.addingTimeInterval(59))
        #expect(!atTen)
        #expect(!atFiftyNine)
    }

    @Test func newWindowAdmitsAgain() {
        var coalescer = FailureCoalescer(window: 60)
        _ = coalescer.admit(sessionID: "s1", at: t0)
        let later = coalescer.admit(sessionID: "s1", at: t0.addingTimeInterval(61))
        #expect(later)
    }

    @Test func sessionsCoalesceIndependently() {
        var coalescer = FailureCoalescer(window: 60)
        let one = coalescer.admit(sessionID: "s1", at: t0)
        let two = coalescer.admit(sessionID: "s2", at: t0)
        #expect(one)
        #expect(two)
    }
}

@Suite struct ThrashDetection {
    let t0 = Date(timeIntervalSince1970: 0)

    @Test func singleFailureIsQuiet() {
        var detector = ThrashDetector()
        let verdict = detector.recordFailure(sessionID: "s1", signature: "E1", at: t0)
        #expect(verdict == .quiet)
    }

    @Test func repeatsBelowThresholdAreQuiet() {
        var detector = ThrashDetector(repeatThreshold: 3, minimumDuration: 180)
        _ = detector.recordFailure(sessionID: "s1", signature: "E1", at: t0)
        let second = detector.recordFailure(
            sessionID: "s1", signature: "E1", at: t0.addingTimeInterval(200))
        #expect(second == .quiet)
    }

    @Test func repeatsAtThresholdAndDurationReportThrashing() {
        var detector = ThrashDetector(repeatThreshold: 3, minimumDuration: 180)
        _ = detector.recordFailure(sessionID: "s1", signature: "E1", at: t0)
        _ = detector.recordFailure(sessionID: "s1", signature: "E1", at: t0.addingTimeInterval(100))
        let verdict = detector.recordFailure(
            sessionID: "s1", signature: "E1", at: t0.addingTimeInterval(200))

        guard case .thrashing(let signature, let elapsed, let count) = verdict else {
            Issue.record("expected thrashing")
            return
        }
        #expect(signature == "E1")
        #expect(elapsed == 200)
        #expect(count == 3)
    }

    @Test func fastRepeatsBelowMinimumDurationAreQuiet() {
        // Three failures in four seconds is a tight loop, not a stuck agent.
        var detector = ThrashDetector(repeatThreshold: 3, minimumDuration: 180)
        _ = detector.recordFailure(sessionID: "s1", signature: "E1", at: t0)
        _ = detector.recordFailure(sessionID: "s1", signature: "E1", at: t0.addingTimeInterval(2))
        let third = detector.recordFailure(
            sessionID: "s1", signature: "E1", at: t0.addingTimeInterval(4))
        #expect(third == .quiet)
    }

    @Test func differentSignatureResetsTheStreak() {
        var detector = ThrashDetector(repeatThreshold: 3, minimumDuration: 180)
        _ = detector.recordFailure(sessionID: "s1", signature: "E1", at: t0)
        _ = detector.recordFailure(sessionID: "s1", signature: "E1", at: t0.addingTimeInterval(100))
        _ = detector.recordFailure(sessionID: "s1", signature: "E2", at: t0.addingTimeInterval(150))
        let back = detector.recordFailure(
            sessionID: "s1", signature: "E1", at: t0.addingTimeInterval(400))
        #expect(back == .quiet)
    }

    @Test func fileChangeResetsTheStreak() {
        // Progress is being made, so the same error is a new attempt, not a loop.
        var detector = ThrashDetector(repeatThreshold: 3, minimumDuration: 180)
        _ = detector.recordFailure(sessionID: "s1", signature: "E1", at: t0)
        _ = detector.recordFailure(sessionID: "s1", signature: "E1", at: t0.addingTimeInterval(100))
        detector.noteFileChanged(sessionID: "s1")
        let after = detector.recordFailure(
            sessionID: "s1", signature: "E1", at: t0.addingTimeInterval(400))
        #expect(after == .quiet)
    }

    @Test func sessionsThrashIndependently() {
        var detector = ThrashDetector(repeatThreshold: 2, minimumDuration: 0)
        _ = detector.recordFailure(sessionID: "s1", signature: "E1", at: t0)
        let other = detector.recordFailure(sessionID: "s2", signature: "E1", at: t0)
        #expect(other == .quiet)
    }

    @Test func signatureIgnoresVolatileDetail() {
        // Line numbers, addresses, and durations change between runs; the same
        // failure must hash the same or nothing ever reaches the threshold.
        let a = ThrashDetector.signature(from: "error at line 42: cannot find 'Foo' (0.31s)")
        let b = ThrashDetector.signature(from: "error at line 87: cannot find 'Foo' (1.02s)")
        #expect(a == b)
    }

    @Test func signatureDistinguishesDifferentErrors() {
        let a = ThrashDetector.signature(from: "cannot find 'Foo' in scope")
        let b = ThrashDetector.signature(from: "cannot find 'Bar' in scope")
        #expect(a != b)
    }

    @Test func signatureOfNilIsStable() {
        #expect(ThrashDetector.signature(from: nil) == ThrashDetector.signature(from: nil))
    }
}
