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
