import Foundation

public enum HookOutputError: Error, Equatable {
    /// The engine is not allowed to auto-deny — denied agents fail mysteriously.
    /// Reaching here means the invariant was broken upstream.
    case denyIsNeverEmitted
}

/// Renders an engine `Decision` as the JSON a hook writes to stdout.
///
/// The whole contract in one place, because it is easy to get subtly wrong:
///
/// - `PreToolUse` takes `permissionDecision`, which accepts only `"allow"` and
///   `"deny"`. There is no `"defer"` and no `"ask"`.
/// - `PermissionRequest` nests it: `"decision": {"behavior": "allow"}` or
///   `{"behavior": "deny", "message": "..."}`. Checked against the installed
///   Claude Code binary, whose validator names exactly those two shapes. An
///   earlier design assumed an `"escalate"` value; it does not exist.
/// - **Deferring is silence.** Exiting 0 with no output means the hook has no
///   decision to report and the call proceeds through the normal permission
///   flow — staying silent does not approve anything. A timeout behaves the
///   same way, which is why the hook's own read deadline is a sufficient guard.
///   On `PermissionRequest` this *is* the escalation: nothing printed, prompt
///   shown.
/// - `Stop` takes a top-level `decision: "block"` with a reason, which is how
///   text gets fed back into a running conversation.
/// - Every other event is informational; the daemon does the speaking and the
///   hook says nothing.
public enum HookOutput {
    private struct PreToolUseOutput: Encodable {
        let hookEventName = "PreToolUse"
        let permissionDecision: String
        let permissionDecisionReason: String
    }

    private struct Envelope: Encodable {
        let hookSpecificOutput: PreToolUseOutput
    }

    private struct PermissionRequestOutput: Encodable {
        let hookEventName = "PermissionRequest"
        let decision: Behavior
    }

    private struct Behavior: Encodable {
        let behavior: String
        /// Only a denial carries one; the validator rejects it on allow.
        let message: String?
    }

    private struct PermissionEnvelope: Encodable {
        let hookSpecificOutput: PermissionRequestOutput
    }

    /// `Stop` takes a top-level decision rather than a hookSpecificOutput.
    private struct StopBlock: Encodable {
        let decision = "block"
        let reason: String
    }

    /// Returns the JSON to print, or `nil` when the hook must print nothing.
    ///
    /// `emitDecisions: false` is the observer build's guarantee. It short-circuits
    /// before any other consideration, so no decision — not even a malformed one —
    /// can reach Claude Code. That is a property of this function rather than of
    /// the policy engine's correctness, which is why it is checked exhaustively.
    public static func encode(
        _ decision: Decision, for kind: HookEventKind, emitDecisions: Bool = true
    ) throws -> String? {
        guard emitDecisions else { return nil }
        guard kind == .preToolUse || kind == .permissionRequest else { return nil }
        guard let permission = decision.permission else { return nil }

        switch permission {
        case .defer:
            return nil
        case .deny:
            throw HookOutputError.denyIsNeverEmitted
        case .allow:
            break
        }

        return try verdict(permission.rawValue, for: kind, reason: decision.reason)
    }

    /// A denial a person gave. Separate from `encode`, which refuses `deny`
    /// because the *engine* must never produce one; an answered no is not the
    /// engine's doing, so it gets its own path rather than a weaker guard.
    public static func answeredDenial(
        for kind: HookEventKind, reason: String, emitDecisions: Bool
    ) throws -> String? {
        guard emitDecisions else { return nil }
        return try verdict(PermissionDecision.deny.rawValue, for: kind, reason: reason)
    }

    /// Feed spoken direction back into a running conversation.
    ///
    /// This is the mechanism that makes "takes over" true: `Stop` returning
    /// `decision: "block"` puts the reason in front of the agent and keeps it
    /// working, rather than ending the turn.
    public static func instruction(
        _ text: String, for kind: HookEventKind, emitDecisions: Bool
    ) throws -> String? {
        guard emitDecisions, kind == .stop, !text.isEmpty else { return nil }
        return try line(StopBlock(reason: text))
    }

    private static func verdict(
        _ value: String, for kind: HookEventKind, reason: String
    ) throws -> String? {
        switch kind {
        case .preToolUse:
            return try line(Envelope(
                hookSpecificOutput: PreToolUseOutput(
                    permissionDecision: value, permissionDecisionReason: reason)))
        case .permissionRequest:
            return try line(PermissionEnvelope(
                hookSpecificOutput: PermissionRequestOutput(decision: Behavior(
                    behavior: value,
                    message: value == PermissionDecision.deny.rawValue ? reason : nil))))
        default:
            return nil
        }
    }

    private static func line<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        // Sorted keys keep the output stable so it can be asserted on directly.
        // No .prettyPrinted: the payload must stay on one line.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
