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
/// - `permissionDecision` accepts only `"allow"` and `"deny"`. There is no
///   `"defer"` and no `"ask"`.
/// - **Deferring is silence.** Exiting 0 with no output means the hook has no
///   decision to report and the call proceeds through the normal permission
///   flow — staying silent does not approve anything. A timeout behaves the
///   same way, which is why the hook's own read deadline is a sufficient guard.
/// - Only `PreToolUse` carries a permission verdict. Every other event is
///   informational; the daemon does the speaking and the hook says nothing.
public enum HookOutput {
    private struct PreToolUseOutput: Encodable {
        let hookEventName = "PreToolUse"
        let permissionDecision: String
        let permissionDecisionReason: String
    }

    private struct Envelope: Encodable {
        let hookSpecificOutput: PreToolUseOutput
    }

    /// Returns the JSON to print, or `nil` when the hook must print nothing.
    public static func encode(
        _ decision: Decision, for kind: HookEventKind
    ) throws -> String? {
        guard kind == .preToolUse else { return nil }
        guard let permission = decision.permission else { return nil }

        switch permission {
        case .defer:
            return nil
        case .deny:
            throw HookOutputError.denyIsNeverEmitted
        case .allow:
            break
        }

        let encoder = JSONEncoder()
        // Sorted keys keep the output stable so it can be asserted on directly.
        // No .prettyPrinted: the payload must stay on one line.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let data = try encoder.encode(Envelope(
            hookSpecificOutput: PreToolUseOutput(
                permissionDecision: permission.rawValue,
                permissionDecisionReason: decision.reason)))

        return String(decoding: data, as: UTF8.self)
    }
}
