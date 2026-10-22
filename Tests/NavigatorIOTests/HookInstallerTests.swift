import Foundation
import Testing
@testable import NavigatorIO

@Suite struct HookInstalling {
    @Test func configuresEveryObservedEvent() {
        let config = HookInstaller.configuration(hookPath: "/x/navigator-hook", timeoutSeconds: 5)
        let hooks = config["hooks"] as? [String: Any]

        for event in HookInstaller.observedEvents {
            #expect(hooks?[event] != nil, "missing \(event)")
        }
    }

    @Test func setsAnExplicitShortTimeout() throws {
        // Claude Code's default for command hooks is 600 seconds. Inheriting
        // that would let a wedged daemon stall a session for ten minutes.
        let config = HookInstaller.configuration(hookPath: "/x/navigator-hook", timeoutSeconds: 5)
        let hooks = try #require(config["hooks"] as? [String: Any])
        let preToolUse = try #require(hooks["PreToolUse"] as? [[String: Any]])
        let entries = try #require(preToolUse.first?["hooks"] as? [[String: Any]])

        #expect(entries.first?["timeout"] as? Int == 5)
        #expect(entries.first?["type"] as? String == "command")
        #expect(entries.first?["command"] as? String == "/x/navigator-hook")
    }

    @Test func theHookTimeoutExceedsTheAnswerDeadlineOnlyWhereItParks() throws {
        // Claude Code kills a hook at its own timeout. Installed at 5s it would
        // cut every question off a quarter of the way through. But only
        // PermissionRequest parks, so only it gets the long rope: a wedged
        // daemon must still cost every other event five seconds, not thirty.
        let config = HookInstaller.configuration(hookPath: "/x/h", timeoutSeconds: 5)
        let hooks = try #require(config["hooks"] as? [String: Any])

        let asking = try #require(
            (hooks["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect((asking.first?["timeout"] as? Int ?? 0) > 25)

        let observing = try #require(
            (hooks["PreToolUse"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect(observing.first?["timeout"] as? Int == 5)
    }

    @Test func omitsMatcherSoEveryToolIsObserved() throws {
        let config = HookInstaller.configuration(hookPath: "/x/h", timeoutSeconds: 5)
        let hooks = try #require(config["hooks"] as? [String: Any])
        let preToolUse = try #require(hooks["PreToolUse"] as? [[String: Any]])
        // An omitted matcher matches all tools. Narrowing it would blind the
        // decision log to exactly the routine calls we need to count.
        #expect(preToolUse.first?["matcher"] == nil)
    }

    @Test func preservesUnrelatedExistingSettings() throws {
        let existing: [String: Any] = [
            "theme": "dark-ansi",
            "enabledPlugins": ["some-plugin": true],
        ]
        let merged = HookInstaller.merged(
            into: existing, hookPath: "/x/h", timeoutSeconds: 5)

        #expect(merged["theme"] as? String == "dark-ansi")
        #expect(merged["enabledPlugins"] != nil)
        #expect(merged["hooks"] != nil)
    }

    @Test func preservesForeignHooksOnTheSameEvent() throws {
        let existing: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["hooks": [["type": "command", "command": "/other/tool"]]]
                ]
            ]
        ]
        let merged = HookInstaller.merged(into: existing, hookPath: "/x/h", timeoutSeconds: 5)
        let hooks = try #require(merged["hooks"] as? [String: Any])
        let preToolUse = try #require(hooks["PreToolUse"] as? [[String: Any]])

        let commands = preToolUse
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }

        #expect(commands.contains("/other/tool"), "clobbered someone else's hook")
        #expect(commands.contains("/x/h"))
    }

    @Test func isIdempotent() throws {
        let once = HookInstaller.merged(into: [:], hookPath: "/x/h", timeoutSeconds: 5)
        let twice = HookInstaller.merged(into: once, hookPath: "/x/h", timeoutSeconds: 5)

        let hooks = try #require(twice["hooks"] as? [String: Any])
        let preToolUse = try #require(hooks["PreToolUse"] as? [[String: Any]])
        let installs = preToolUse
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }
            .filter { $0 == "/x/h" }

        #expect(installs.count == 1, "installed twice")
    }

    @Test func upgradingTheTimeoutDoesNotDuplicate() throws {
        let once = HookInstaller.merged(into: [:], hookPath: "/x/h", timeoutSeconds: 5)
        let twice = HookInstaller.merged(into: once, hookPath: "/x/h", timeoutSeconds: 9)

        let hooks = try #require(twice["hooks"] as? [String: Any])
        let preToolUse = try #require(hooks["PreToolUse"] as? [[String: Any]])
        let entries = preToolUse
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .filter { $0["command"] as? String == "/x/h" }

        #expect(entries.count == 1)
        #expect(entries.first?["timeout"] as? Int == 9)
    }

    @Test func producesValidJSON() throws {
        let merged = HookInstaller.merged(into: [:], hookPath: "/x/h", timeoutSeconds: 5)
        #expect(JSONSerialization.isValidJSONObject(merged))
        let data = try JSONSerialization.data(withJSONObject: merged)
        #expect(!data.isEmpty)
    }
}

@Suite struct HookUninstalling {
    @Test func removesOnlyNavigatorEntries() throws {
        let installed = HookInstaller.merged(
            into: ["hooks": ["PreToolUse": [
                ["hooks": [["type": "command", "command": "/other/tool"]]]
            ]]],
            hookPath: "/Users/t/.claude/bin/navigator-hook", timeoutSeconds: 5)

        let result = HookInstaller.removed(from: installed, matching: "navigator-hook")
        let hooks = try #require(result.settings["hooks"] as? [String: Any])
        let preToolUse = try #require(hooks["PreToolUse"] as? [[String: Any]])
        let commands = preToolUse
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }

        #expect(commands == ["/other/tool"])
        #expect(result.count == HookInstaller.observedEvents.count)
    }

    @Test func preservesUnrelatedSettings() throws {
        let installed = HookInstaller.merged(
            into: ["theme": "dark-ansi"],
            hookPath: "/x/navigator-hook", timeoutSeconds: 5)

        let result = HookInstaller.removed(from: installed, matching: "navigator-hook")
        #expect(result.settings["theme"] as? String == "dark-ansi")
        // Nothing else used hooks, so the empty key is dropped rather than left
        // as a confusing husk.
        #expect(result.settings["hooks"] == nil)
    }

    @Test func isSafeOnSettingsWithNoHooks() {
        let result = HookInstaller.removed(from: ["theme": "x"], matching: "navigator-hook")
        #expect(result.count == 0)
        #expect(result.settings["theme"] as? String == "x")
    }

    @Test func roundTripsBackToTheOriginal() throws {
        let original: [String: Any] = ["theme": "dark-ansi", "effortLevel": "high"]
        let installed = HookInstaller.merged(
            into: original, hookPath: "/x/navigator-hook", timeoutSeconds: 5)
        let result = HookInstaller.removed(from: installed, matching: "navigator-hook")

        #expect(result.settings.keys.sorted() == original.keys.sorted())
    }
}
