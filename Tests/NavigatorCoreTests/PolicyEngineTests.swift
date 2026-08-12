import Foundation
import Testing
@testable import NavigatorCore

@Suite struct PolicyEngineBehavior {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func engine() -> PolicyEngine {
        var engine = PolicyEngine(startingAt: t0)
        engine.decideDiscarding(HookEvent(kind: .sessionStart, sessionID: "s1", cwd: "/p"), at: t0)
        engine.decideDiscarding(
            HookEvent(kind: .userPromptSubmit, sessionID: "s1", cwd: "/p", prompt: "build it"),
            at: t0)
        return engine
    }

    private func bash(_ command: String) -> HookEvent {
        HookEvent(kind: .preToolUse, sessionID: "s1", cwd: "/p",
                  toolName: "Bash", toolInput: ["command": .string(command)])
    }

    @Test func routineToolCallIsSilentlyAllowed() {
        var subject = engine()
        let decision = subject.decide(StampedEvent(event: bash("swift build"), at: t0))
        #expect(decision.tier == .silent)
        #expect(decision.permission == .allow)
        #expect(decision.utterance == nil)
    }

    @Test func irreversibleToolCallBlocksAndSpeaks() {
        var subject = engine()
        let decision = subject.decide(
            StampedEvent(event: bash("git push --force"), at: t0))
        #expect(decision.tier == .decisionPoint)
        #expect(decision.permission == .defer)
        #expect(decision.blocking)
        #expect(decision.utterance != nil)
    }

    @Test func secondQuestionWhileOneIsLiveDefersImmediately() {
        var subject = engine()
        _ = subject.decide(StampedEvent(event: bash("git push --force"), at: t0))
        let second = subject.decide(
            StampedEvent(event: bash("rm -rf build"), at: t0.addingTimeInterval(1)))

        #expect(second.permission == .defer)
        #expect(second.tier == .silent)
        #expect(second.reason.contains("another question"))
    }

    @Test func resolvingAQuestionAdmitsTheNextOne() {
        var subject = engine()
        _ = subject.decide(StampedEvent(event: bash("git push --force"), at: t0))
        subject.resolveQuestion()
        let second = subject.decide(
            StampedEvent(event: bash("rm -rf build"), at: t0.addingTimeInterval(1)))
        #expect(second.tier == .decisionPoint)
    }

    @Test func mutingSuppressesSpeechAndDefers() {
        var subject = engine()
        subject.setMuted(true)
        let decision = subject.decide(StampedEvent(event: bash("git push --force"), at: t0))
        #expect(decision.tier == .silent)
        #expect(decision.permission == .defer)
        #expect(decision.reason.contains("muted"))
    }

    @Test func mutingDoesNotBlockRoutineWork() {
        // Muted must mean "do not speak", not "stop working".
        var subject = engine()
        subject.setMuted(true)
        let decision = subject.decide(StampedEvent(event: bash("swift build"), at: t0))
        #expect(decision.permission == .allow)
        #expect(decision.tier == .silent)
    }

    @Test func nonBlockingSpeechDegradesOnceBudgetIsSpent() {
        var subject = engine()
        let first = subject.decide(StampedEvent(
            event: HookEvent(kind: .elicitation, sessionID: "s1", cwd: "/p"), at: t0))
        let second = subject.decide(StampedEvent(
            event: HookEvent(kind: .elicitation, sessionID: "s1", cwd: "/p"),
            at: t0.addingTimeInterval(5)))

        #expect(first.tier == .needsInput)
        #expect(second.tier == .earcon)
    }

    @Test func repeatedFailuresCoalesceToOneEarcon() {
        var subject = engine()
        let failure = HookEvent(
            kind: .postToolUseFailure, sessionID: "s1", cwd: "/p", error: "boom at line 3")

        let first = subject.decide(StampedEvent(event: failure, at: t0))
        let second = subject.decide(StampedEvent(event: failure, at: t0.addingTimeInterval(5)))

        #expect(first.tier == .earcon)
        #expect(second.tier == .silent)
        #expect(second.reason.contains("coalesced"))
    }

    @Test func sustainedThrashPromotesToSpeech() {
        var subject = engine()
        let failure = HookEvent(
            kind: .postToolUseFailure, sessionID: "s1", cwd: "/p",
            error: "cannot find 'Foo' in scope at line 12")

        _ = subject.decide(StampedEvent(event: failure, at: t0))
        _ = subject.decide(StampedEvent(event: failure, at: t0.addingTimeInterval(100)))
        let third = subject.decide(StampedEvent(event: failure, at: t0.addingTimeInterval(200)))

        #expect(third.tier == .speak)
        #expect(third.utterance?.contains("stuck") == true)
    }

    @Test func threeUnrelatedFailuresDoNotTripThrash() {
        // Regression: the signature was built from `message`, which failure
        // events never carry. Every failure hashed to "<none>", so any three
        // errors — however unrelated — looked like a stuck session.
        var subject = engine()
        let errors = [
            "cannot find 'Foo' in scope",
            "network timeout contacting registry",
            "permission denied writing /tmp/x",
        ]

        var last: Decision?
        for (i, message) in errors.enumerated() {
            let failure = HookEvent(
                kind: .postToolUseFailure, sessionID: "s1", cwd: "/p", error: message)
            last = subject.decide(
                StampedEvent(event: failure, at: t0.addingTimeInterval(Double(i) * 100)))
        }

        #expect(last?.tier != .speak)
    }

    @Test func fileChangeBetweenFailuresPreventsThrashPromotion() {
        var subject = engine()
        let failure = HookEvent(
            kind: .postToolUseFailure, sessionID: "s1", cwd: "/p", error: "same error at line 12")
        let edit = HookEvent(
            kind: .preToolUse, sessionID: "s1", cwd: "/p",
            toolName: "Edit", toolInput: ["file_path": .string("/p/a.swift")])

        _ = subject.decide(StampedEvent(event: failure, at: t0))
        _ = subject.decide(StampedEvent(event: failure, at: t0.addingTimeInterval(100)))
        _ = subject.decide(StampedEvent(event: edit, at: t0.addingTimeInterval(150)))
        let third = subject.decide(StampedEvent(event: failure, at: t0.addingTimeInterval(200)))

        #expect(third.tier != .speak)
    }

    @Test func spokenSentenceIsGrammatical() {
        // The entire product is read aloud. An earlier version produced
        // "wants to force push rewrites remote history", because the rule
        // reasons were descriptions rather than verb phrases. Nothing caught it
        // because every test built its own reason string.
        var subject = engine()
        let decision = subject.decide(
            StampedEvent(event: bash("git push --force origin main"), at: t0))

        #expect(decision.utterance == "p wants to force push, which rewrites remote history. Approve?")
    }

    @Test func offRouteSentenceReadsAsOneClause() {
        var subject = engine()
        let write = HookEvent(
            kind: .preToolUse, sessionID: "s1", cwd: "/p",
            toolName: "Write", toolInput: ["file_path": .string("/etc/hosts")])
        let decision = subject.decide(StampedEvent(event: write, at: t0))

        // Reversible but off-route, so an earcon with no words. The reason still
        // has to read as a phrase for catch-up, which reads it back.
        #expect(decision.reason == "write to /etc/hosts, outside /p")
    }

    @Test func everyDecisionIsLogged() {
        var subject = engine()
        let before = subject.log.count
        _ = subject.decide(StampedEvent(event: bash("swift build"), at: t0))
        _ = subject.decide(StampedEvent(event: bash("git push --force"), at: t0))
        #expect(subject.log.count == before + 2)
    }

    @Test func logRecordsSuppressionReason() throws {
        var subject = engine()
        subject.setMuted(true)
        _ = subject.decide(StampedEvent(event: bash("git push --force"), at: t0))
        let record = try #require(subject.log.last)

        #expect(record.tierAssigned == .decisionPoint)
        #expect(record.delivered == .silent)
        #expect(record.suppressedBecause?.contains("muted") == true)
    }

    @Test func logIsRoundTrippable() throws {
        var subject = engine()
        _ = subject.decide(StampedEvent(event: bash("git push --force"), at: t0))
        let record = try #require(subject.log.last)

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(DecisionRecord.self, from: data)
        #expect(decoded == record)
    }

    @Test func registryIsUpdatedAsASideEffectOfDeciding() {
        let subject = engine()
        #expect(subject.registry.session(id: "s1")?.route == "build it")
    }
}

extension PolicyEngine {
    mutating func decideDiscarding(_ event: HookEvent, at date: Date) {
        _ = decide(StampedEvent(event: event, at: date))
    }
}

@Suite struct QuestionDeadline {
    let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    private func engine() -> PolicyEngine {
        var engine = PolicyEngine(startingAt: t0)
        _ = engine.decide(StampedEvent(
            event: HookEvent(kind: .sessionStart, sessionID: "s1", cwd: "/p"), at: t0))
        return engine
    }

    private func force(_ at: TimeInterval) -> StampedEvent {
        StampedEvent(
            event: HookEvent(
                kind: .preToolUse, sessionID: "s1", cwd: "/p", toolName: "Bash",
                toolInput: ["command": .string("git push --force")]),
            at: t0.addingTimeInterval(at))
    }

    @Test func anUnansweredQuestionStopsBlockingAfterTheDeadline() {
        // Found in a real log: nothing calls resolveQuestion in the observer
        // build, so the in-flight flag latched on the first decision point and
        // silently swallowed every one after it — half the announcements that
        // matter most, for the lifetime of the daemon.
        var subject = engine()

        let first = subject.decide(force(0))
        #expect(first.tier == .decisionPoint)

        // Still in flight a moment later.
        let during = subject.decide(force(5))
        #expect(during.tier == .silent)
        #expect(during.reason.contains("another question"))

        // Past the deadline it is not, whether or not anyone answered.
        let after = subject.decide(force(60))
        #expect(after.tier == .decisionPoint, "the flag latched: \(after.reason)")
    }

    @Test func answeringClearsItImmediately() {
        var subject = engine()
        _ = subject.decide(force(0))
        subject.resolveQuestion()
        #expect(subject.decide(force(1)).tier == .decisionPoint)
    }

    @Test func theDeadlineIsConfigurable() {
        var subject = PolicyEngine(
            config: PolicyConfig(questionDeadline: 5), startingAt: t0)
        _ = subject.decide(StampedEvent(
            event: HookEvent(kind: .sessionStart, sessionID: "s1", cwd: "/p"), at: t0))

        _ = subject.decide(force(0))
        #expect(subject.decide(force(3)).tier == .silent)
        #expect(subject.decide(force(10)).tier == .decisionPoint)
    }
}

@Suite struct LongRunningDaemon {
    let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    private func engine(_ config: PolicyConfig = .default) -> PolicyEngine {
        PolicyEngine(config: config, startingAt: t0)
    }

    private func call(_ session: String, _ at: TimeInterval) -> StampedEvent {
        StampedEvent(
            event: HookEvent(
                kind: .preToolUse, sessionID: session, cwd: "/p",
                toolName: "Bash", toolInput: ["command": .string("swift build")]),
            at: t0.addingTimeInterval(at))
    }

    @Test func theInMemoryLogIsBounded() {
        // The daemon reads only the most recent record, but ran for weeks
        // appending every decision it ever made to an array nobody trimmed.
        var subject = engine(PolicyConfig(recentLogCapacity: 50))
        for i in 0..<500 { _ = subject.decide(call("s", Double(i))) }

        #expect(subject.log.count == 50)
        #expect(subject.log.last?.at == t0.addingTimeInterval(499))
    }

    @Test func theMostRecentRecordIsStillCorrect() {
        // The daemon's only reader is `log.last`; trimming must not disturb it.
        var subject = engine(PolicyConfig(recentLogCapacity: 3))
        for i in 0..<10 { _ = subject.decide(call("s", Double(i))) }
        #expect(subject.log.last?.at == t0.addingTimeInterval(9))
    }

    @Test func endedSessionsAreForgotten() {
        // One entry per session, kept forever. A machine that opens a few
        // Claude Code windows a day accumulates them indefinitely.
        var subject = engine()
        for i in 0..<200 {
            let id = "session-\(i)"
            _ = subject.decide(StampedEvent(
                event: HookEvent(kind: .sessionStart, sessionID: id, cwd: "/p"),
                at: t0.addingTimeInterval(Double(i))))
            _ = subject.decide(StampedEvent(
                event: HookEvent(kind: .sessionEnd, sessionID: id, cwd: "/p"),
                at: t0.addingTimeInterval(Double(i) + 0.5)))
        }

        #expect(subject.registry.activeSessions.isEmpty)
        #expect(subject.registry.trackedCount < 200,
                "ended sessions were retained: \(subject.registry.trackedCount)")
    }

    @Test func aLiveSessionIsNeverForgotten() {
        var subject = engine()
        _ = subject.decide(StampedEvent(
            event: HookEvent(kind: .sessionStart, sessionID: "keep", cwd: "/p"), at: t0))

        for i in 0..<200 {
            let id = "other-\(i)"
            _ = subject.decide(StampedEvent(
                event: HookEvent(kind: .sessionStart, sessionID: id, cwd: "/p"),
                at: t0.addingTimeInterval(Double(i))))
            _ = subject.decide(StampedEvent(
                event: HookEvent(kind: .sessionEnd, sessionID: id, cwd: "/p"),
                at: t0.addingTimeInterval(Double(i) + 0.5)))
        }

        #expect(subject.registry.session(id: "keep") != nil)
        #expect(subject.registry.activeSessions.count == 1)
    }
}

extension LongRunningDaemon {
    @Test func aWeekOfWorkDoesNotAccumulate() {
        // 500 sessions x 40 tool calls — roughly a heavy week. Every per-session
        // structure has to come back down, not just the obvious one.
        var subject = engine()

        for s in 0..<500 {
            let id = "s\(s)"
            let base = Double(s) * 100

            _ = subject.decide(StampedEvent(
                event: HookEvent(kind: .sessionStart, sessionID: id, cwd: "/p"),
                at: t0.addingTimeInterval(base)))

            for i in 0..<40 {
                _ = subject.decide(call(id, base + Double(i)))
                _ = subject.decide(StampedEvent(
                    event: HookEvent(
                        kind: .postToolUseFailure, sessionID: id, cwd: "/p",
                        error: "boom"),
                    at: t0.addingTimeInterval(base + Double(i) + 0.5)))
            }

            _ = subject.decide(StampedEvent(
                event: HookEvent(kind: .sessionEnd, sessionID: id, cwd: "/p"),
                at: t0.addingTimeInterval(base + 60)))
        }

        #expect(subject.log.count <= PolicyConfig.default.recentLogCapacity)
        #expect(subject.registry.trackedCount <= 60,
                "sessions accumulated: \(subject.registry.trackedCount)")
        #expect(subject.registry.activeSessions.isEmpty)
    }
}

extension PolicyEngineBehavior {
    @Test func theLogRecordsWhichNotificationItWas() {
        // Without this the log said "unmatched notification" and nothing more,
        // so there was no way to review whether ignoring it was the right call.
        var subject = engine()
        _ = subject.decide(StampedEvent(
            event: HookEvent(
                kind: .notification, sessionID: "s1", cwd: "/p",
                notificationType: "agent_completed", message: "done"),
            at: t0))

        #expect(subject.log.last?.detail == "agent_completed")
        #expect(subject.log.last?.tierAssigned == .silentQueue)
    }

    @Test func theLogRecordsTheKindOfFailure() {
        var subject = engine()
        _ = subject.decide(StampedEvent(
            event: HookEvent(
                kind: .postToolUseFailure, sessionID: "s1", cwd: "/p",
                error: "boom", errorType: "compile_error"),
            at: t0))

        #expect(subject.log.last?.detail == "compile_error")
    }

    @Test func detailIsAbsentWhenTheEventHasNoSubType() {
        var subject = engine()
        _ = subject.decide(StampedEvent(event: bash("swift build"), at: t0))
        #expect(subject.log.last?.detail == nil)
    }
}
