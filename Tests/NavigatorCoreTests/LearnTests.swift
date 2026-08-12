import Foundation
import Testing
@testable import NavigatorCore

@Suite struct LearnReporting {
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    private func record(
        _ reversibility: String, at offset: TimeInterval = 0, kind: HookEventKind = .preToolUse
    ) -> DecisionRecord {
        DecisionRecord(
            at: t0.addingTimeInterval(offset), sessionID: "s", kind: kind, toolName: "Bash",
            reversibility: reversibility, route: "on-route",
            tierAssigned: .silent, delivered: .silent,
            suppressedBecause: nil, permission: .defer, reason: "")
    }

    @Test func extractsCommandNamesFromUnknownRecords() {
        let found = LearnReport.unknownCommands(in: [
            record("unknown: unrecognised command tailscale"),
            record("unknown: unrecognised command bun"),
        ])
        #expect(found.map(\.command).sorted() == ["bun", "tailscale"])
    }

    @Test func countsAndRanksByFrequency() {
        let found = LearnReport.unknownCommands(in: [
            record("unknown: unrecognised command bun"),
            record("unknown: unrecognised command tailscale"),
            record("unknown: unrecognised command tailscale"),
            record("unknown: unrecognised command tailscale"),
        ])
        #expect(found.first?.command == "tailscale")
        #expect(found.first?.count == 3)
        #expect(found.last?.command == "bun")
    }

    @Test func ignoresRecordsThatAreNotUnknownCommands() {
        let found = LearnReport.unknownCommands(in: [
            record("reversible"),
            record("irreversible: delete files"),
            // These are unknown, but not something a safe-list entry can fix.
            record("unknown: unrecognised tool SomeMCPTool"),
            record("unknown: no tool name"),
            record("unknown: Bash call with no command"),
            record("unknown: deeply nested command substitution"),
        ])
        #expect(found.isEmpty)
    }

    @Test func ignoresCommandsNamedByPath() {
        // `./scripts/deploy.sh` and `/tmp/probe` run code the table never saw.
        // Offering to mark them safe would be offering to vouch for anything
        // that path ever contains.
        let found = LearnReport.unknownCommands(in: [
            record("unknown: unrecognised command ./scripts/deploy.sh"),
            record("unknown: unrecognised command /tmp/probe"),
            record("unknown: unrecognised command tailscale"),
        ])
        #expect(found.map(\.command) == ["tailscale"])
    }

    @Test func honoursASinceCutoff() {
        let found = LearnReport.unknownCommands(
            in: [
                record("unknown: unrecognised command old", at: 0),
                record("unknown: unrecognised command new", at: 10_000),
            ],
            since: t0.addingTimeInterval(5_000))
        #expect(found.map(\.command) == ["new"])
    }

    @Test func reportsTheMostRecentSighting() {
        let found = LearnReport.unknownCommands(in: [
            record("unknown: unrecognised command bun", at: 0),
            record("unknown: unrecognised command bun", at: 500),
        ])
        #expect(found.first?.lastSeen == t0.addingTimeInterval(500))
    }

    @Test func emptyLogYieldsNothing() {
        #expect(LearnReport.unknownCommands(in: []).isEmpty)
    }
}
