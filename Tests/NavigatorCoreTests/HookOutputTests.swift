import Foundation
import Testing
@testable import NavigatorCore

@Suite struct HookOutputEncoding {
    private func decision(
        _ permission: PermissionDecision?, reason: String = "reversible, on route"
    ) -> Decision {
        Decision(tier: .silent, permission: permission,
                 utterance: nil, reason: reason, blocking: false)
    }

    // As with `#expect`, a throwing call cannot sit inside `#require` — the
    // macro expansion does not carry the `try` through. Hoist, then require.

    @Test func allowEmitsPermissionDecision() throws {
        let encoded = try HookOutput.encode(decision(.allow), for: .preToolUse)
        let json = try #require(encoded)
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let specific = try #require(parsed?["hookSpecificOutput"] as? [String: Any])

        #expect(specific["hookEventName"] as? String == "PreToolUse")
        #expect(specific["permissionDecision"] as? String == "allow")
        #expect(specific["permissionDecisionReason"] as? String == "reversible, on route")
    }

    @Test func deferEmitsNothing() throws {
        // Silence IS the defer mechanism: exit 0 with no output leaves the call
        // to the normal permission flow.
        #expect(try HookOutput.encode(decision(.defer), for: .preToolUse) == nil)
    }

    @Test func absentPermissionEmitsNothing() throws {
        #expect(try HookOutput.encode(decision(nil), for: .preToolUse) == nil)
    }

    @Test(arguments: [
        HookEventKind.stop, .notification, .postToolUseFailure,
        .sessionStart, .elicitation, .fileChanged,
    ])
    func nonPreToolUseEventsEmitNothing(_ kind: HookEventKind) throws {
        // Speech happens in the daemon. These hooks have nothing to say back.
        #expect(try HookOutput.encode(decision(.allow), for: kind) == nil)
    }

    @Test func denyIsRefusedAtTheWireBoundary() {
        // The engine never produces deny. This is the last checkpoint before it
        // would reach Claude Code, and it fails loudly rather than emitting it.
        #expect(throws: HookOutputError.denyIsNeverEmitted) {
            try HookOutput.encode(decision(.deny), for: .preToolUse)
        }
    }

    @Test func reasonWithQuotesAndNewlinesIsEscaped() throws {
        // Reasons embed real command text and paths, so this is routine input.
        let nasty = "writes to /Users/t/\"weird dir\"/x\n\tand runs `rm -rf`"
        let encoded = try HookOutput.encode(decision(.allow, reason: nasty), for: .preToolUse)
        let json = try #require(encoded)

        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let specific = try #require(parsed?["hookSpecificOutput"] as? [String: Any])
        #expect(specific["permissionDecisionReason"] as? String == nasty)
    }

    @Test func outputIsASingleLine() throws {
        // The hook writes this to stdout; a multi-line payload risks being
        // split by anything doing line-oriented reads.
        let encoded = try HookOutput.encode(decision(.allow, reason: "a\nb"), for: .preToolUse)
        let json = try #require(encoded)
        #expect(!json.contains("\n"))
    }
}

@Suite struct WireGate {
    /// Every decision the engine can possibly produce.
    private static let decisions: [Decision] = {
        var all: [Decision] = []
        for tier in Tier.allCases {
            for permission: PermissionDecision? in [nil, .allow, .defer, .deny] {
                all.append(Decision(
                    tier: tier, permission: permission,
                    utterance: nil, reason: "r", blocking: tier.isBlocking))
            }
        }
        return all
    }()

    @Test func closedGateEmitsNothingForAnyInputAtAll() throws {
        // This is the observer-build safety guarantee: not "the engine won't
        // decide badly", but "nothing the engine decides can reach the wire".
        for decision in Self.decisions {
            for kind in HookEventKind.allCases {
                let out = try HookOutput.encode(decision, for: kind, emitDecisions: false)
                #expect(out == nil,
                        "gate leaked for \(kind) \(String(describing: decision.permission))")
            }
        }
    }

    @Test func closedGateDoesNotThrowOnDeny() throws {
        // With the gate shut, deny is not an error — nothing is being emitted,
        // so there is nothing to refuse. The throw belongs to the open gate.
        let deny = Decision(tier: .silent, permission: .deny,
                            utterance: nil, reason: "r", blocking: false)
        let out = try HookOutput.encode(deny, for: .preToolUse, emitDecisions: false)
        #expect(out == nil)
    }

    @Test func openGateStillEmitsAllow() throws {
        let allow = Decision(tier: .silent, permission: .allow,
                             utterance: nil, reason: "ok", blocking: false)
        let out = try HookOutput.encode(allow, for: .preToolUse, emitDecisions: true)
        #expect(out != nil)
    }

    @Test func defaultConfigHasTheGateClosed() {
        #expect(PolicyConfig.default.emitDecisions == false)
    }
}

@Suite struct WireGateCoversEveryOutboundPath {
    /// The gate was checked exhaustively when PreToolUse was the only way out.
    /// New ones are being added; the guarantee has to grow with them.
    @Test func closedGateBlocksAnsweredDenials() throws {
        #expect(try HookOutput.answeredDenial(
            for: .permissionRequest, reason: "r", emitDecisions: false) == nil)
    }

    @Test func closedGateBlocksInstructions() throws {
        #expect(try HookOutput.instruction(
            "add tests", for: .stop, emitDecisions: false) == nil)
    }

    @Test func openGateEmitsAnInstruction() throws {
        let out = try #require(try HookOutput.instruction(
            "add tests for the parser", for: .stop, emitDecisions: true))
        let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]

        // Stop uses a top-level decision, not hookSpecificOutput.
        #expect(parsed?["decision"] as? String == "block")
        #expect((parsed?["reason"] as? String)?.contains("add tests") == true)
    }

    @Test func permissionRequestSpellsItsVerdictAsBehavior() throws {
        // PreToolUse: `"permissionDecision":"allow"`. PermissionRequest:
        // `"decision":{"behavior":"allow"}`. Verified against the installed
        // Claude Code binary (2.1.282), whose validator says exactly:
        //   PermissionRequest decision must be {"behavior": "allow"} or
        //   {"behavior": "deny", "message": "..."}
        // The wrong shape is valid JSON that Claude Code rejects with a hook
        // error — which is how the first version of this shipped broken.
        let allow = Decision(tier: .silent, permission: .allow,
                             utterance: nil, reason: "ok", blocking: false)
        let out = try #require(try HookOutput.encode(
            allow, for: .permissionRequest, emitDecisions: true))
        let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        let specific = try #require(parsed?["hookSpecificOutput"] as? [String: Any])
        let decision = try #require(specific["decision"] as? [String: Any])

        #expect(specific["hookEventName"] as? String == "PermissionRequest")
        #expect(decision["behavior"] as? String == "allow")
        #expect(specific["permissionDecision"] == nil)
    }

    @Test func anAnsweredDenialCarriesItsMessage() throws {
        let out = try #require(try HookOutput.answeredDenial(
            for: .permissionRequest, reason: "you said no", emitDecisions: true))
        let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        let specific = try #require(parsed?["hookSpecificOutput"] as? [String: Any])
        let decision = try #require(specific["decision"] as? [String: Any])

        #expect(decision["behavior"] as? String == "deny")
        #expect(decision["message"] as? String == "you said no")
    }

    @Test func anAnsweredDenialOnPreToolUseUsesThatEventsSpelling() throws {
        let out = try #require(try HookOutput.answeredDenial(
            for: .preToolUse, reason: "no", emitDecisions: true))
        let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        let specific = try #require(parsed?["hookSpecificOutput"] as? [String: Any])
        #expect(specific["permissionDecision"] as? String == "deny")
    }

    @Test func everyNewPathIsShutWithTheGateClosed() throws {
        for kind in HookEventKind.allCases {
            for permission: PermissionDecision? in [nil, .allow, .defer, .deny] {
                let decision = Decision(
                    tier: .decisionPoint, permission: permission,
                    utterance: "x", reason: "r", blocking: true)
                #expect(try HookOutput.encode(
                    decision, for: kind, emitDecisions: false) == nil)
            }
            #expect(try HookOutput.answeredDenial(
                for: kind, reason: "r", emitDecisions: false) == nil)
        }
    }
}
