import Foundation

public enum HookEventKind: String, Codable, Sendable, CaseIterable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    /// Fires only when a call genuinely needs a decision, between PreToolUse
    /// and the tool running. The one event with an explicit "show the
    /// prompt" answer (`escalate`), which is why questions park here.
    case permissionRequest = "PermissionRequest"
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

/// One hook payload as Claude Code writes it to the hook's stdin.
///
/// Field names follow the hooks reference exactly. Several near-synonyms are
/// deliberately kept apart because they arrive on different events and confusing
/// them fails silently: `message` (Notification) is not `error`
/// (PostToolUseFailure), and `notification_type` is not `message`.
public struct HookEvent: Codable, Sendable, Equatable {
    public let kind: HookEventKind
    public let sessionID: String
    public let cwd: String

    // Common envelope
    public let permissionMode: String?
    public let agentID: String?
    public let agentType: String?

    // PreToolUse / PostToolUseFailure
    public let toolName: String?
    public let toolInput: [String: JSONValue]?
    public let toolUseID: String?

    // PostToolUseFailure / StopFailure
    public let error: String?
    public let errorType: String?

    // Notification
    public let notificationType: String?
    public let message: String?

    // UserPromptSubmit
    public let prompt: String?

    // FileChanged — note this `file_path` is top-level, unlike the one inside a
    // tool_input, so it gets its own property rather than sharing an accessor.
    public let changedPath: String?
    public let changeType: String?

    enum CodingKeys: String, CodingKey {
        case kind = "hook_event_name"
        case sessionID = "session_id"
        case cwd
        case permissionMode = "permission_mode"
        case agentID = "agent_id"
        case agentType = "agent_type"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolUseID = "tool_use_id"
        case error
        case errorType = "error_type"
        case notificationType = "notification_type"
        case message
        case prompt
        case changedPath = "file_path"
        case changeType = "change_type"
    }

    public init(
        kind: HookEventKind,
        sessionID: String,
        cwd: String,
        permissionMode: String? = nil,
        agentID: String? = nil,
        agentType: String? = nil,
        toolName: String? = nil,
        toolInput: [String: JSONValue]? = nil,
        toolUseID: String? = nil,
        error: String? = nil,
        errorType: String? = nil,
        notificationType: String? = nil,
        message: String? = nil,
        prompt: String? = nil,
        changedPath: String? = nil,
        changeType: String? = nil
    ) {
        self.kind = kind
        self.sessionID = sessionID
        self.cwd = cwd
        self.permissionMode = permissionMode
        self.agentID = agentID
        self.agentType = agentType
        self.toolName = toolName
        self.toolInput = toolInput
        self.toolUseID = toolUseID
        self.error = error
        self.errorType = errorType
        self.notificationType = notificationType
        self.message = message
        self.prompt = prompt
        self.changedPath = changedPath
        self.changeType = changeType
    }
}

extension HookEvent {
    public var command: String? { toolInput?["command"]?.stringValue }
    public var filePath: String? { toolInput?["file_path"]?.stringValue }
    public var url: String? { toolInput?["url"]?.stringValue }

    /// The text a failure should be fingerprinted on.
    ///
    /// `error` is where failures actually carry their detail; `message` is the
    /// Notification field and is nil on failure events. Falling back keeps
    /// hand-built test events working without pretending the two are the same.
    public var failureDetail: String? { error ?? message }
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
