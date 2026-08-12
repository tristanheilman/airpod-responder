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
