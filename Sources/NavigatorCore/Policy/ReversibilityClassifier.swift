import Foundation

public struct ReversibilityClassifier: Sendable {
    private let irreversibleCommands: [BashRule]
    private let irreversibleContent: [(pattern: String, reason: String)]
    private let safeCommands: [BashRule]

    /// Tools that only read, or whose writes are ordinary local file edits.
    private static let reversibleTools: Set<String> = [
        "Read", "Glob", "Grep", "NotebookRead", "TodoWrite",
        "Edit", "Write", "NotebookEdit", "WebSearch",
    ]

    public init(
        irreversibleCommands: [BashRule] = BashRules.irreversibleCommands,
        irreversibleContent: [(pattern: String, reason: String)] = BashRules.irreversibleContent,
        safeCommands: [BashRule] = BashRules.safeCommands
    ) {
        self.irreversibleCommands = irreversibleCommands
        self.irreversibleContent = irreversibleContent
        self.safeCommands = safeCommands
    }

    public func classify(toolName: String?, toolInput: [String: JSONValue]?) -> Reversibility {
        guard let toolName else { return .unknown(reason: "no tool name") }

        if Self.reversibleTools.contains(toolName) { return .reversible }

        if toolName == "Bash" {
            guard let command = toolInput?["command"]?.stringValue else {
                return .unknown(reason: "Bash call with no command")
            }
            return classifyCommand(command)
        }

        // WebFetch reaches the network, and host familiarity is not modelled in
        // v1. MCP tools are opaque by construction. Both defer.
        return .unknown(reason: "unrecognised tool \(toolName)")
    }

    private func classifyCommand(_ command: String) -> Reversibility {
        var sawUnknown: String?

        for segment in Self.segments(of: command) {
            switch classifySegment(segment) {
            case .irreversible(let reason):
                return .irreversible(reason: reason)  // most dangerous segment wins
            case .unknown(let reason):
                sawUnknown = reason
            case .reversible:
                continue
            }
        }

        if let sawUnknown { return .unknown(reason: sawUnknown) }
        return .reversible
    }

    private func classifySegment(_ segment: String) -> Reversibility {
        let lowered = segment.lowercased()
        for entry in irreversibleContent where lowered.contains(entry.pattern) {
            return .irreversible(reason: entry.reason)
        }

        let tokens = Self.tokenize(segment)
        guard !tokens.isEmpty else { return .reversible }

        for rule in irreversibleCommands where rule.matches(tokens: tokens) {
            return .irreversible(reason: rule.reason)
        }
        for rule in safeCommands where rule.matches(tokens: tokens) {
            return .reversible
        }
        return .unknown(reason: "unrecognised command \(tokens[0])")
    }

    /// Splits on shell separators. Crude on purpose: quoting is not honoured,
    /// which can only ever over-segment and so can only make the classifier
    /// more cautious, never less.
    static func segments(of command: String) -> [String] {
        command
            .replacingOccurrences(of: "&&", with: "\n")
            .replacingOccurrences(of: "||", with: "\n")
            .replacingOccurrences(of: ";", with: "\n")
            .replacingOccurrences(of: "|", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func tokenize(_ segment: String) -> [String] {
        segment.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
