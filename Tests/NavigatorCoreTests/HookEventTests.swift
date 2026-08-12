import Foundation
import Testing
@testable import NavigatorCore

@Suite struct HookEventDecoding {
    @Test func decodesPreToolUseBashEvent() throws {
        let json = """
        {
          "hook_event_name": "PreToolUse",
          "session_id": "abc123",
          "cwd": "/Users/t/Projects/app",
          "tool_name": "Bash",
          "tool_input": { "command": "git status", "timeout": 5000 }
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(HookEvent.self, from: json)

        #expect(event.kind == .preToolUse)
        #expect(event.sessionID == "abc123")
        #expect(event.cwd == "/Users/t/Projects/app")
        #expect(event.toolName == "Bash")
        #expect(event.command == "git status")
    }

    @Test func decodesEventWithoutToolFields() throws {
        let json = """
        { "hook_event_name": "Stop", "session_id": "abc123", "cwd": "/tmp" }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(HookEvent.self, from: json)

        #expect(event.kind == .stop)
        #expect(event.toolName == nil)
        #expect(event.command == nil)
    }

    @Test func preservesEmbeddedQuotesAndNewlinesInCommands() throws {
        let json = """
        {
          "hook_event_name": "PreToolUse",
          "session_id": "s",
          "cwd": "/tmp",
          "tool_name": "Bash",
          "tool_input": { "command": "git commit -m \\"fix: the \\\\\\"thing\\\\\\"\\n\\nbody\\"" }
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(HookEvent.self, from: json)

        #expect(event.command == "git commit -m \"fix: the \\\"thing\\\"\n\nbody\"")
    }

    @Test func decodesNotificationTypeSeparatelyFromMessage() throws {
        // notification_type is its own enumerated field. Matching markers
        // against `message` would silently never fire.
        let json = """
        {
          "hook_event_name": "Notification",
          "session_id": "s",
          "cwd": "/tmp",
          "notification_type": "agent_needs_input",
          "message": "which parser strategy?"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(HookEvent.self, from: json)

        #expect(event.notificationType == "agent_needs_input")
        #expect(event.message == "which parser strategy?")
    }

    @Test func decodesFailureErrorFields() throws {
        // PostToolUseFailure carries `error`/`error_type`, never `message`.
        let json = """
        {
          "hook_event_name": "PostToolUseFailure",
          "session_id": "s",
          "cwd": "/tmp",
          "tool_name": "Bash",
          "error": "cannot find 'Token' in scope at line 12",
          "error_type": "compile_error"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(HookEvent.self, from: json)

        #expect(event.error == "cannot find 'Token' in scope at line 12")
        #expect(event.errorType == "compile_error")
        #expect(event.message == nil)
    }

    @Test func decodesCommonEnvelopeFields() throws {
        let json = """
        {
          "hook_event_name": "PreToolUse",
          "session_id": "s",
          "cwd": "/tmp",
          "permission_mode": "bypassPermissions",
          "agent_id": "a1",
          "agent_type": "Explore",
          "tool_use_id": "toolu_01ABC"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(HookEvent.self, from: json)

        #expect(event.permissionMode == "bypassPermissions")
        #expect(event.agentID == "a1")
        #expect(event.agentType == "Explore")
        #expect(event.toolUseID == "toolu_01ABC")
    }

    @Test func decodesFileChangedFields() throws {
        let json = """
        {
          "hook_event_name": "FileChanged",
          "session_id": "s",
          "cwd": "/tmp",
          "file_path": "/tmp/.env",
          "change_type": "modified"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(HookEvent.self, from: json)

        // file_path is top-level here, not inside tool_input.
        #expect(event.changedPath == "/tmp/.env")
        #expect(event.changeType == "modified")
    }

    @Test func decodesNestedToolInput() throws {
        let json = """
        {
          "hook_event_name": "PreToolUse",
          "session_id": "s",
          "cwd": "/tmp",
          "tool_name": "Edit",
          "tool_input": { "file_path": "/tmp/a.swift", "edits": [ { "old": "a", "new": "b" } ] }
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(HookEvent.self, from: json)

        #expect(event.filePath == "/tmp/a.swift")
        if case .array(let edits)? = event.toolInput?["edits"] {
            #expect(edits.count == 1)
        } else {
            Issue.record("expected edits array")
        }
    }
}
