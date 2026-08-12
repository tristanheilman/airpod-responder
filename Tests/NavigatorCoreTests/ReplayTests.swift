import Foundation
import Testing
@testable import NavigatorCore

@Suite struct ReplayBehavior {
    let jsonl = """
    {"at":"2026-08-11T09:00:00Z","event":{"hook_event_name":"SessionStart","session_id":"s1","cwd":"/p"}}
    {"at":"2026-08-11T09:00:01Z","event":{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/p","prompt":"build it"}}
    {"at":"2026-08-11T09:00:02Z","event":{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/p","tool_name":"Bash","tool_input":{"command":"swift build"}}}
    {"at":"2026-08-11T09:00:03Z","event":{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/p","tool_name":"Bash","tool_input":{"command":"git push --force"}}}
    """

    @Test func parsesJSONLIntoStampedEvents() throws {
        let events = try Replay.parse(jsonl: jsonl)
        #expect(events.count == 4)
        #expect(events[0].event.kind == .sessionStart)
        #expect(events[3].event.command == "git push --force")
    }

    @Test func parseSkipsBlankLines() throws {
        let events = try Replay.parse(jsonl: "\n\n" + jsonl + "\n\n")
        #expect(events.count == 4)
    }

    @Test func summarisesADay() throws {
        let events = try Replay.parse(jsonl: jsonl)
        let (summary, records) = Replay.run(events: events, config: .default)

        #expect(summary.totalEvents == 4)
        #expect(records.count == 4)
        #expect(summary.blocking == 1)   // the force push
        #expect(summary.silent == 3)     // lifecycle x2 + the allowed build
    }

    @Test func utteranceRateIsPerWallClockHour() throws {
        let events = try Replay.parse(jsonl: jsonl)
        let (summary, _) = Replay.run(events: events, config: .default)
        // Four events across three seconds; the rate is extrapolated, so it must
        // at least be finite and positive rather than dividing by zero.
        #expect(summary.utterancesPerHour > 0)
        #expect(summary.utterancesPerHour.isFinite)
    }

    @Test func emptyReplayDoesNotDivideByZero() {
        let (summary, records) = Replay.run(events: [], config: .default)
        #expect(summary.totalEvents == 0)
        #expect(summary.utterancesPerHour == 0)
        #expect(records.isEmpty)
    }

    @Test func tighterBudgetProducesFewerUtterances() throws {
        // The point of the harness: sweep the guess and see what it costs.
        let many = (0..<10).map { i in
            StampedEvent(
                event: HookEvent(kind: .elicitation, sessionID: "s1", cwd: "/p"),
                at: Date(timeIntervalSince1970: 1_000_000 + Double(i) * 30))
        }

        let loose = Replay.run(
            events: many, config: PolicyConfig(speechInterval: 30)).0
        let tight = Replay.run(
            events: many, config: PolicyConfig(speechInterval: 3600)).0

        #expect(tight.spoken < loose.spoken)
    }
}

@Suite struct ReplayingADecisionLog {
    let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    private func record(
        _ tier: Tier, at offset: TimeInterval, session: String = "s",
        kind: HookEventKind = .preToolUse
    ) -> DecisionRecord {
        DecisionRecord(
            at: t0.addingTimeInterval(offset), sessionID: session, kind: kind,
            toolName: "Bash", reversibility: "irreversible: x", route: "on-route",
            tierAssigned: tier, delivered: tier,
            suppressedBecause: nil, permission: .defer, reason: "x")
    }

    @Test func rerunsTheBudgetOverRecordedTiers() {
        // The point of keeping a log: try a budget before living with it.
        let records = (0..<6).map { record(.speak, at: Double($0) * 30) }

        let loose = Replay.rerun(records: records, config: PolicyConfig(speechInterval: 10))
        let tight = Replay.rerun(records: records, config: PolicyConfig(speechInterval: 600))

        #expect(loose.spoken == 6)
        #expect(tight.spoken == 1)
        #expect(tight.earcons == 5, "suppressed speech degrades to an earcon")
    }

    @Test func blockingQuestionsIgnoreTheBudget() {
        let records = (0..<5).map { record(.decisionPoint, at: Double($0)) }
        let summary = Replay.rerun(records: records, config: PolicyConfig(speechInterval: 3600))
        #expect(summary.spoken == 5)
        #expect(summary.blocking == 5)
    }

    @Test func silentRecordsStaySilentAtAnyBudget() {
        let records = (0..<10).map { record(.silent, at: Double($0)) }
        let summary = Replay.rerun(records: records, config: PolicyConfig(speechInterval: 1))
        #expect(summary.spoken == 0)
        #expect(summary.silent == 10)
    }

    @Test func failuresCoalescePerSession() {
        // Two sessions failing at the same moment are two separate bursts.
        let records = [
            record(.earcon, at: 0, session: "a", kind: .postToolUseFailure),
            record(.earcon, at: 5, session: "a", kind: .postToolUseFailure),
            record(.earcon, at: 5, session: "b", kind: .postToolUseFailure),
        ]
        let summary = Replay.rerun(records: records, config: .default)
        #expect(summary.earcons == 2, "a's second failure should coalesce")
    }

    @Test func recordsAreSortedBeforeReplay() {
        // Log files are read per-day and concatenated; order is not guaranteed.
        let records = [
            record(.speak, at: 600),
            record(.speak, at: 0),
        ]
        let summary = Replay.rerun(records: records, config: PolicyConfig(speechInterval: 300))
        #expect(summary.spoken == 2, "out-of-order records made the budget misfire")
    }

    @Test func anEmptyLogIsNotADivideByZero() {
        let summary = Replay.rerun(records: [], config: .default)
        #expect(summary.totalEvents == 0)
        #expect(summary.utterancesPerHour == 0)
    }
}
