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

    /// Precedence, and the asymmetry in it, matters:
    ///
    /// 1. user irreversible — you can always ask to hear about more
    /// 2. built-in irreversible
    /// 3. user safe
    /// 4. built-in safe
    ///
    /// A user safe rule deliberately cannot un-flag a built-in danger. Adding to
    /// the safe list is routine housekeeping done from a log of unknowns;
    /// letting that silently disarm `rm` or a force push would turn a
    /// convenience into the one thing this must never do.
    public init(
        irreversibleCommands: [BashRule] = BashRules.irreversibleCommands,
        irreversibleContent: [(pattern: String, reason: String)] = BashRules.irreversibleContent,
        safeCommands: [BashRule] = BashRules.safeCommands,
        userRules: UserRules = UserRules()
    ) {
        self.irreversibleCommands = userRules.irreversible + irreversibleCommands
        self.irreversibleContent = irreversibleContent
        self.safeCommands = userRules.safe + safeCommands
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

        let (tokens, wrapper) = Self.effectiveTokens(rawTokens)
        // Nothing left means the segment was pure shell structure — a bare
        // `fi`, or `FOO=bar` on its own. Structure does nothing by itself.
        // A bare `env` prints the environment and a bare `nice` does nothing;
        // a bare `xargs` runs whatever stdin says.
        guard !tokens.isEmpty else {
            if wrapper == "xargs" { return .unknown(reason: "bare xargs") }
            return innerUnknown.map { .unknown(reason: $0) } ?? .reversible
        }

        for rule in irreversibleCommands where rule.matches(tokens: tokens) {
            return .irreversible(reason: rule.reason)
        }
        // A wrapper's option grammar is only half modelled, and xargs takes
        // its argv from stdin, which cannot be seen at all. So a wrapped
        // segment may escalate — the program it exposes is what it is — but
        // never vouch: `xargs -I echo rm -rf x` must not resolve to `echo`.
        if let wrapper { return .unknown(reason: "wrapped by \(wrapper)") }
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
    /// Shells whose heredoc body really is executed, so it must still be read.
    private static let shellInterpreters: Set<String> = ["bash", "sh", "zsh", "dash", "ksh"]

    /// Removes heredoc bodies, which are data rather than commands.
    ///
    /// `cat <<'EOF' … EOF` was reporting `EOF` as an unrecognised program, and
    /// would have classified the prose of a commit message as though someone had
    /// typed it at a prompt.
    ///
    /// The exception matters: `bash <<EOF` genuinely executes its body, so that
    /// one is left alone. Stripping it would hide whatever is inside, and hiding
    /// is the one direction that is not safe.
    static func removingHeredocBodies(_ command: String) -> String {
        let lines = command.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var kept: [String] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            kept.append(line)
            index += 1

            guard let delimiter = heredocDelimiter(in: line) else { continue }

            let firstWord = effectiveTokens(tokenize(line)).tokens.first ?? ""
            if shellInterpreters.contains(firstWord) { continue }

            while index < lines.count,
                  lines[index].trimmingCharacters(in: .whitespaces) != delimiter {
                index += 1
            }
            // Step past the terminator itself; anything after it is real again.
            if index < lines.count { index += 1 }
        }

        return kept.joined(separator: "\n")
    }

    /// Finds a heredoc delimiter, ignoring `<<` that appears inside quotes.
    ///
    /// Without the quote check, `echo "a << b"` would swallow every following
    /// line — silently dropping real commands from classification.
    static func heredocDelimiter(in line: String) -> String? {
        let characters = Array(line)
        var quote: Character?
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if let open = quote {
                if character == open { quote = nil }
                index += 1
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                index += 1
                continue
            }
            guard character == "<", index + 1 < characters.count,
                  characters[index + 1] == "<"
            else {
                index += 1
                continue
            }

            var scan = index + 2
            // `<<<` is a here-string: one line of data, no terminator to find.
            if scan < characters.count, characters[scan] == "<" { return nil }
            if scan < characters.count, characters[scan] == "-" { scan += 1 }
            while scan < characters.count, characters[scan] == " " { scan += 1 }
            if scan < characters.count,
               characters[scan] == "'" || characters[scan] == "\"" { scan += 1 }

            var word = ""
            while scan < characters.count,
                  characters[scan].isLetter || characters[scan].isNumber
                    || characters[scan] == "_" {
                word.append(characters[scan])
                scan += 1
            }
            return word.isEmpty ? nil : word
        }

        return nil
    }

    static func segments(of command: String) -> [String] {
        let command = removingHeredocBodies(command)
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
    /// Programs that run whatever follows them. `env rm -rf` is `rm -rf`,
    /// and with `env` once on the safe list it classified as safe and went
    /// silent — a hole in front of every rule in the table, not just one.
    private static let wrappers: Set<String> = ["env", "nohup", "nice", "command", "xargs"]

    /// The tokens with shell structure and wrappers stripped, and the first
    /// wrapper stripped if any — the caller must not treat a wrapped
    /// program's safe verdict as its own.
    static func effectiveTokens(_ tokens: [String]) -> (tokens: [String], wrapper: String?) {
        var remaining = tokens
        var wrapper: String?

        while let first = remaining.first {
            if shellKeywords.contains(first) || isEnvironmentAssignment(first) {
                remaining.removeFirst()
                continue
            }
            if wrappers.contains(first) {
                wrapper = wrapper ?? first
                remaining.removeFirst()
                // A wrapper's own options (`nice -n 5`, `env -i`) are not the
                // program either. A flag's argument is skipped with it.
                while let option = remaining.first, option.hasPrefix("-") {
                    remaining.removeFirst()
                    if (option == "-n" || option == "-u"), !remaining.isEmpty { remaining.removeFirst() }
                }
                continue
            }
            break
        }

        return (remaining, wrapper)
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
