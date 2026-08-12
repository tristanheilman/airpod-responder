import Foundation
import Testing
@testable import NavigatorCore

@Suite struct TierAssignment {
    let subject = TierAssigner()

    private func preToolUse(_ r: Reversibility, _ route: RouteStatus) -> TierVerdict {
        subject.assign(kind: .preToolUse, reversibility: r, route: route, notificationType: nil)
    }

    @Test func reversibleOnRouteIsSilentAndAllowed() {
        let verdict = preToolUse(.reversible, .onRoute)
        #expect(verdict.tier == .silent)
        #expect(verdict.permission == .allow)
    }

    @Test func reversibleOffRouteEarconsAndDefers() {
        let verdict = preToolUse(.reversible, .offRoute(reason: "writes to /etc"))
        #expect(verdict.tier == .earcon)
        #expect(verdict.permission == .defer)
    }

    @Test func irreversibleOnRouteSpeaksAndDefers() {
        let verdict = preToolUse(.irreversible(reason: "force push"), .onRoute)
        #expect(verdict.tier == .decisionPoint)
        #expect(verdict.permission == .defer)
        #expect(verdict.reason.contains("force push"))
    }

    @Test func irreversibleOffRouteLeadsWithTheRouteReason() {
        let verdict = preToolUse(
            .irreversible(reason: "deletes files"),
            .offRoute(reason: "writes to /Users/t/.zshrc, outside /Users/t/Projects/app"))
        #expect(verdict.tier == .decisionPoint)
        #expect(verdict.permission == .defer)
        #expect(verdict.reason.hasPrefix("writes to /Users/t/.zshrc"))
    }

    @Test func unknownIsSilentAndDefers() {
        // Deferring shows the on-screen prompt. Narrating it would be noise.
        let verdict = preToolUse(.unknown(reason: "unrecognised command frobnicate"), .onRoute)
        #expect(verdict.tier == .silent)
        #expect(verdict.permission == .defer)
    }

    @Test func unknownOffRouteStillDefersSilently() {
        let verdict = preToolUse(.unknown(reason: "x"), .offRoute(reason: "y"))
        #expect(verdict.permission == .defer)
    }

    @Test(arguments: [
        (HookEventKind.stop, Tier.silentQueue),
        (.taskCompleted, .silentQueue),
        (.subagentStop, .silentQueue),
        (.teammateIdle, .silentQueue),
        (.postToolUseFailure, .earcon),
        (.stopFailure, .earcon),
        (.elicitation, .needsInput),
        (.sessionStart, .silent),
        (.sessionEnd, .silent),
        (.userPromptSubmit, .silent),
    ])
    func mapsNonToolEventsToTiers(_ kind: HookEventKind, _ expected: Tier) {
        let verdict = subject.assign(
            kind: kind, reversibility: .reversible, route: .onRoute, notificationType: nil)
        #expect(verdict.tier == expected)
        #expect(verdict.permission == nil, "only PreToolUse yields a permission verdict")
    }

    @Test(arguments: ["agent_needs_input", "permission_prompt"])
    func matchedNotificationsNeedInput(_ type: String) {
        let verdict = subject.assign(
            kind: .notification, reversibility: .reversible,
            route: .onRoute, notificationType: type)
        #expect(verdict.tier == .needsInput)
    }

    @Test(arguments: ["idle_prompt", "agent_completed", "auth_success", "elicitation_complete"])
    func unmatchedNotificationTypesAreQueued(_ type: String) {
        let verdict = subject.assign(
            kind: .notification, reversibility: .reversible,
            route: .onRoute, notificationType: type)
        #expect(verdict.tier == .silentQueue)
    }

    @Test func notificationMatchingIsExactNotSubstring() {
        // notification_type is an enumerated field, so a near-miss must not
        // match. Substring matching here would fire on unrelated types.
        let verdict = subject.assign(
            kind: .notification, reversibility: .reversible,
            route: .onRoute, notificationType: "elicitation_agent_needs_input_complete")
        #expect(verdict.tier == .silentQueue)
    }

    @Test func notificationWithNoTypeIsQueued() {
        let verdict = subject.assign(
            kind: .notification, reversibility: .reversible,
            route: .onRoute, notificationType: nil)
        #expect(verdict.tier == .silentQueue)
    }

    @Test func fileChangedOffRouteAndIrreversibleSpeaks() {
        let verdict = subject.assign(
            kind: .fileChanged, reversibility: .irreversible(reason: "deletes files"),
            route: .offRoute(reason: "outside project"), notificationType: nil)
        #expect(verdict.tier == .speak)
    }

    @Test func fileChangedOffRouteAndReversibleEarcons() {
        let verdict = subject.assign(
            kind: .fileChanged, reversibility: .reversible,
            route: .offRoute(reason: "outside project"), notificationType: nil)
        #expect(verdict.tier == .earcon)
    }

    @Test func fileChangedOnRouteIsSilent() {
        let verdict = subject.assign(
            kind: .fileChanged, reversibility: .reversible,
            route: .onRoute, notificationType: nil)
        #expect(verdict.tier == .silent)
    }

    @Test func tierPropertiesAreConsistent() {
        #expect(Tier.decisionPoint.isBlocking)
        #expect(Tier.decisionPoint.isSpeech)
        #expect(Tier.needsInput.isSpeech)
        #expect(Tier.speak.isSpeech)
        #expect(!Tier.needsInput.isBlocking)
        #expect(!Tier.earcon.isSpeech)
        #expect(!Tier.silent.isSpeech)
        #expect(!Tier.silentQueue.isSpeech)
    }
}

@Suite struct BlastRadiusInvariant {
    let subject = TierAssigner()

    private static let reversibilities: [Reversibility] = [
        .reversible, .irreversible(reason: "r"), .unknown(reason: "u"),
    ]
    private static let routes: [RouteStatus] = [.onRoute, .offRoute(reason: "o")]

    @Test func allowRequiresReversibleAndOnRoute() {
        for r in Self.reversibilities {
            for route in Self.routes {
                for kind in HookEventKind.allCases {
                    let verdict = subject.assign(
                        kind: kind, reversibility: r, route: route, notificationType: nil)
                    guard verdict.permission == .allow else { continue }
                    #expect(r == .reversible, "allowed a non-reversible action: \(kind) \(r)")
                    #expect(route == .onRoute, "allowed an off-route action: \(kind) \(route)")
                }
            }
        }
    }

    @Test func neverAutoDenies() {
        for r in Self.reversibilities {
            for route in Self.routes {
                for kind in HookEventKind.allCases {
                    let verdict = subject.assign(
                        kind: kind, reversibility: r, route: route, notificationType: nil)
                    #expect(verdict.permission != .deny,
                            "auto-denied \(kind) — agents must never fail mysteriously")
                }
            }
        }
    }
}
