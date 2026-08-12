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
