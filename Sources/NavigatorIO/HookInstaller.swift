import Foundation

/// Builds the `hooks` block for `~/.claude/settings.json`.
///
/// Produces the configuration but never writes it — `navigator install` prints
/// it and applies only with `--apply`. Editing a user's Claude Code settings
/// behind their back is not something a notification daemon should do quietly.
public enum HookInstaller {
    /// Every event the engine models. `PreToolUse` carries the decisions;
    /// the rest are what make the log a picture of the day rather than a list
    /// of tool calls.
    public static let observedEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit",
        "PreToolUse", "PostToolUseFailure",
        "Notification", "Elicitation",
        "Stop", "StopFailure", "SubagentStop",
        "TaskCompleted", "TeammateIdle",
    ]

    public static func configuration(
        hookPath: String, timeoutSeconds: Int
    ) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in observedEvents {
            // No `matcher` key: omitted means every tool, and a narrower
            // matcher would hide the routine calls the silence rate is made of.
            hooks[event] = [["hooks": [entry(hookPath: hookPath, timeout: timeoutSeconds)]]]
        }
        return ["hooks": hooks]
    }

    public static func merged(
        into existing: [String: Any], hookPath: String, timeoutSeconds: Int
    ) -> [String: Any] {
        var result = existing
        var hooks = (existing["hooks"] as? [String: Any]) ?? [:]

        for event in observedEvents {
            var groups = (hooks[event] as? [[String: Any]]) ?? []

            // Drop any previous install of *this* hook, leave everything else.
            // Rewriting rather than skipping is what makes a timeout change take
            // effect without stacking a second copy.
            groups = groups.compactMap { group in
                guard var entries = group["hooks"] as? [[String: Any]] else { return group }
                entries.removeAll { $0["command"] as? String == hookPath }
                if entries.isEmpty { return nil }
                var updated = group
                updated["hooks"] = entries
                return updated
            }

            groups.append(["hooks": [entry(hookPath: hookPath, timeout: timeoutSeconds)]])
            hooks[event] = groups
        }

        result["hooks"] = hooks
        return result
    }

    private static func entry(hookPath: String, timeout: Int) -> [String: Any] {
        // The explicit timeout matters: the default for command hooks is 600
        // seconds, which would let a wedged daemon stall a session for ten
        // minutes before Claude Code gave up on it.
        ["type": "command", "command": hookPath, "timeout": timeout]
    }
}
