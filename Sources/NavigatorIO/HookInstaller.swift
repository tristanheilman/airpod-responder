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
        "PreToolUse", "PermissionRequest", "PostToolUseFailure",
        "Notification", "Elicitation",
        "Stop", "StopFailure", "SubagentStop",
        "TaskCompleted", "TeammateIdle",
    ]

    /// The one event the daemon holds open while you decide.
    public static let parkingEvent = "PermissionRequest"

    /// Three deadlines, strictly ordered: **daemon 20 < hook 25 < Claude Code
    /// 30**. Each is a backstop for the one before it, so a failure at any
    /// level still releases the agent. Only the parking event gets this rope;
    /// everywhere else a wedged daemon still costs the short timeout.
    public static let parkingTimeoutSeconds = 30

    public static func configuration(
        hookPath: String, timeoutSeconds: Int
    ) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in observedEvents {
            // No `matcher` key: omitted means every tool, and a narrower
            // matcher would hide the routine calls the silence rate is made of.
            hooks[event] = [["hooks": [entry(
                hookPath: hookPath, timeout: timeout(for: event, default: timeoutSeconds))]]]
        }
        return ["hooks": hooks]
    }

    private static func timeout(for event: String, default timeoutSeconds: Int) -> Int {
        event == parkingEvent ? parkingTimeoutSeconds : timeoutSeconds
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

            groups.append(["hooks": [entry(
                hookPath: hookPath, timeout: timeout(for: event, default: timeoutSeconds))]])
            hooks[event] = groups
        }

        result["hooks"] = hooks
        return result
    }

    /// Strips every hook entry whose command contains `needle`, leaving other
    /// tools' hooks and every other setting untouched.
    ///
    /// Uninstalling matters more than installing: settings left pointing at a
    /// deleted binary is exactly the quiet failure the stable prefix exists to
    /// prevent, and the user needs a way back out.
    public static func removed(
        from settings: [String: Any], matching needle: String
    ) -> (settings: [String: Any], count: Int) {
        guard var hooks = settings["hooks"] as? [String: Any] else { return (settings, 0) }
        var removed = 0

        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }

            let kept: [[String: Any]] = groups.compactMap { group in
                guard var entries = group["hooks"] as? [[String: Any]] else { return group }
                let before = entries.count
                entries.removeAll { ($0["command"] as? String)?.contains(needle) == true }
                removed += before - entries.count
                if entries.isEmpty { return nil }
                var updated = group
                updated["hooks"] = entries
                return updated
            }

            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }

        var result = settings
        if hooks.isEmpty { result.removeValue(forKey: "hooks") } else { result["hooks"] = hooks }
        return (result, removed)
    }

    private static func entry(hookPath: String, timeout: Int) -> [String: Any] {
        // The explicit timeout matters: the default for command hooks is 600
        // seconds, which would let a wedged daemon stall a session for ten
        // minutes before Claude Code gave up on it.
        ["type": "command", "command": hookPath, "timeout": timeout]
    }
}
