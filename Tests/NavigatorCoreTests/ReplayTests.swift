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
