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

    private func classifyCommand(_ command: String, depth: Int = 0) -> Reversibility {
        // Substitutions can nest. Four deep is far past anything real, and an
        // unbounded recursion here would be reachable from a tool call.
        guard depth < 4 else {
            return .unknown(reason: "deeply nested command substitution")
        }

        var sawUnknown: String?

        for segment in Self.segments(of: command) {
            switch classifySegment(segment, depth: depth) {
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

    private func classifySegment(_ segment: String, depth: Int) -> Reversibility {
        // Content patterns run against the raw segment, quotes and all: a
        // `DROP TABLE` passed as an argument is exactly the case where looking
        // inside a string is the point.
        let lowered = segment.lowercased()
        for entry in irreversibleContent where lowered.contains(entry.pattern) {
            return .irreversible(reason: entry.reason)
        }

        // What is inside `$( )` actually runs, and the outer command says
        // nothing about it — `echo $(rm -rf x)` is not an echo. Classify the
        // insides first and let the most dangerous answer win.
        let split = Self.splittingSubstitutions(segment)
        var innerUnknown: String?

        for inner in split.substitutions {
            switch classifyCommand(inner, depth: depth + 1) {
            case .irreversible(let reason):
                return .irreversible(reason: reason)
            case .unknown(let reason):
                innerUnknown = reason
            case .reversible:
                continue
            }
        }

        // Tokenised with the substitutions removed, so their innards cannot be
        // mistaken for the outer program — `$(date -u …)` was reporting `-u`.
        let rawTokens = Self.tokenize(split.outer)
        if let verdict = Self.loopHeaderVerdict(rawTokens) {
            if case .reversible = verdict, let innerUnknown {
                return .unknown(reason: innerUnknown)
            }
            return verdict
        }

        let tokens = Self.effectiveTokens(rawTokens)
        // Nothing left means the segment was pure shell structure — a bare
        // `fi`, or `FOO=bar` on its own. Structure does nothing by itself.
        guard !tokens.isEmpty else {
            return innerUnknown.map { .unknown(reason: $0) } ?? .reversible
        }

        for rule in irreversibleCommands where rule.matches(tokens: tokens) {
            return .irreversible(reason: rule.reason)
        }
        for rule in safeCommands where rule.matches(tokens: tokens) {
            // A safe outer command does not vouch for an unrecognised inner one.
            return innerUnknown.map { .unknown(reason: $0) } ?? .reversible
        }
        return .unknown(reason: "unrecognised command \(tokens[0])")
    }

    /// Separates a segment into the text outside `$( )` and the commands inside.
    static func splittingSubstitutions(
        _ segment: String
    ) -> (outer: String, substitutions: [String]) {
        var outer = ""
        var found: [String] = []

        let characters = Array(segment)
        var index = 0

        while index < characters.count {
            guard characters[index] == "$",
                  index + 1 < characters.count,
                  characters[index + 1] == "("
            else {
                outer.append(characters[index])
                index += 1
                continue
            }

            var depth = 1
            var inner = ""
            var scan = index + 2

            while scan < characters.count, depth > 0 {
                if characters[scan] == "(" { depth += 1 }
                if characters[scan] == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                inner.append(characters[scan])
                scan += 1
            }

            found.append(inner)
            // Elided entirely rather than replaced with a space: the surrounding
            // whitespace is already correct, and inserting one splits tokens the
            // substitution was embedded in — `LOG=…$(date)…` became two tokens
            // and reported `.jsonl` as the command.
            index = scan + 1
        }

        return (outer, found)
    }

    /// Words that structure a script rather than run anything.
    ///
    /// Without these, `if [ -f x ]; then y; fi` reports three unrecognised
    /// commands — `if`, `then` and `fi` — which is what real traffic showed.
    private static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi",
        "for", "while", "until", "do", "done",
        "case", "esac", "in", "function", "time", "exec", "!",
        "{", "}", "((", "))",
    ]

    /// Splits on shell separators, honouring quotes and command substitution.
    ///
    /// The first version ignored quoting on the grounds that over-splitting can
    /// only make the classifier more cautious. That was true but useless: real
    /// commands contain `;` inside strings, so it produced fragments like `)"`
    /// and classified three quarters of ordinary Bash calls as unknown.
    ///
    /// Under-splitting is still safe, because a segment whose program is not
    /// recognised reports `.unknown`, which defers. It never reports reversible.
    static func segments(of command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var depth = 0

        let characters = Array(command)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if let open = quote {
                current.append(character)
                // A backslash only escapes inside double quotes; in single
                // quotes it is literal, which is why the quote style matters.
                if character == open, open == "'" || characters[index - 1] != "\\" {
                    quote = nil
                }
                index += 1
                continue
            }

            switch character {
            case "\"", "'":
                quote = character
                current.append(character)

            case "$" where index + 1 < characters.count && characters[index + 1] == "(":
                depth += 1
                current.append("$(")
                index += 2
                continue

            case "(" where depth > 0:
                depth += 1
                current.append(character)

            case ")" where depth > 0:
                depth -= 1
                current.append(character)

            case ";", "\n":
                if depth == 0 {
                    segments.append(current)
                    current = ""
                } else {
                    current.append(character)
                }

            case "&":
                // Only `&&` separates. A lone `&` is far more often the middle
                // of `2>&1` than a background job, and splitting there left `1`
                // behind as the supposed program — four times in one session.
                if depth == 0, index + 1 < characters.count, characters[index + 1] == "&" {
                    index += 1
                    segments.append(current)
                    current = ""
                } else {
                    current.append(character)
                }

            case "|":
                if depth == 0 {
                    // Consume the second character of `||`.
                    if index + 1 < characters.count, characters[index + 1] == "|" {
                        index += 1
                    }
                    segments.append(current)
                    current = ""
                } else {
                    current.append(character)
                }

            default:
                current.append(character)
            }

            index += 1
        }

        segments.append(current)
        return segments
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func tokenize(_ segment: String) -> [String] {
        segment.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// `for VAR in words…` runs nothing by itself — the loop body is a separate
    /// segment, and the token after `for` is a variable name, not a program.
    ///
    /// Unless the word list is generated by a substitution, in which case
    /// something does run and we have not seen what.
    static func loopHeaderVerdict(_ tokens: [String]) -> Reversibility? {
        guard tokens.first == "for" else { return nil }

        let list = tokens.drop { $0 != "in" }.dropFirst()
        if list.contains(where: { $0.contains("$(") || $0.contains("`") }) {
            return .unknown(reason: "for loop over a command substitution")
        }
        return .reversible
    }

    /// Strips leading shell structure so the real program is at index 0.
    static func effectiveTokens(_ tokens: [String]) -> [String] {
        var remaining = tokens

        while let first = remaining.first {
            if shellKeywords.contains(first) {
                remaining.removeFirst()
                continue
            }
            if isEnvironmentAssignment(first) {
                remaining.removeFirst()
                continue
            }
            break
        }

        return remaining
    }

    /// `FOO=bar cmd` — the assignment is a prefix, not the command.
    private static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else {
            return false
        }
        return token[token.startIndex..<equals]
            .allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
