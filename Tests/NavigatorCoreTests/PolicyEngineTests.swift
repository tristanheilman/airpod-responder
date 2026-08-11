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
            kind: .postToolUseFailure, sessionID: "s1", cwd: "/p", message: "boom at line 3")

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
            message: "cannot find 'Foo' in scope at line 12")

        _ = subject.decide(StampedEvent(event: failure, at: t0))
        _ = subject.decide(StampedEvent(event: failure, at: t0.addingTimeInterval(100)))
        let third = subject.decide(StampedEvent(event: failure, at: t0.addingTimeInterval(200)))

        #expect(third.tier == .speak)
        #expect(third.utterance?.contains("stuck") == true)
    }

    @Test func fileChangeBetweenFailuresPreventsThrashPromotion() {
        var subject = engine()
        let failure = HookEvent(
            kind: .postToolUseFailure, sessionID: "s1", cwd: "/p", message: "same error at line 12")
        let edit = HookEvent(
            kind: .preToolUse, sessionID: "s1", cwd: "/p",
            toolName: "Edit", toolInput: ["file_path": .string("/p/a.swift")])

        _ = subject.decide(StampedEvent(event: failure, at: t0))
        _ = subject.decide(StampedEvent(event: failure, at: t0.addingTimeInterval(100)))
        _ = subject.decide(StampedEvent(event: edit, at: t0.addingTimeInterval(150)))
        let third = subject.decide(StampedEvent(event: failure, at: t0.addingTimeInterval(200)))

        #expect(third.tier != .speak)
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
