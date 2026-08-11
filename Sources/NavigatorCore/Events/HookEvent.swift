import Foundation

public enum HookEventKind: String, Codable, Sendable, CaseIterable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUseFailure = "PostToolUseFailure"
    case notification = "Notification"
    case stop = "Stop"
    case stopFailure = "StopFailure"
    case subagentStop = "SubagentStop"
    case taskCompleted = "TaskCompleted"
    case teammateIdle = "TeammateIdle"
    case fileChanged = "FileChanged"
    case elicitation = "Elicitation"
}

public struct HookEvent: Codable, Sendable, Equatable {
    public let kind: HookEventKind
    public let sessionID: String
    public let cwd: String
    public let toolName: String?
    public let toolInput: [String: JSONValue]?
    public let message: String?
    public let prompt: String?

    enum CodingKeys: String, CodingKey {
        case kind = "hook_event_name"
        case sessionID = "session_id"
        case cwd
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case message
        case prompt
    }

    public init(
        kind: HookEventKind,
        sessionID: String,
        cwd: String,
        toolName: String? = nil,
        toolInput: [String: JSONValue]? = nil,
        message: String? = nil,
        prompt: String? = nil
    ) {
        self.kind = kind
        self.sessionID = sessionID
        self.cwd = cwd
        self.toolName = toolName
        self.toolInput = toolInput
        self.message = message
        self.prompt = prompt
    }
}

extension HookEvent {
    public var command: String? { toolInput?["command"]?.stringValue }
    public var filePath: String? { toolInput?["file_path"]?.stringValue }
    public var url: String? { toolInput?["url"]?.stringValue }
}

/// An event paired with the instant the daemon received it.
///
/// Claude Code does not timestamp hook payloads, and the engine must never read
/// the clock itself, so arrival time is stamped at the edge and passed in.
public struct StampedEvent: Sendable, Equatable {
    public let event: HookEvent
    public let at: Date

    public init(event: HookEvent, at: Date) {
        self.event = event
        self.at = at
    }
}
