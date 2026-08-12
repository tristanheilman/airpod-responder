import Foundation

/// Command rules the user adds, layered over the built-in table.
///
/// Exists because the built-in list is compiled in, and your command vocabulary
/// is not something to file a change request about. `navigator learn` writes
/// here; the file is meant to be opened and edited by hand, which is why it is
/// a flat list of strings rather than a faithful serialisation of `BashRule`.
///
/// ```json
/// {
///   "safe": ["tailscale", "pnpm dlx"],
///   "irreversible": { "flyctl deploy": "deploy to production" }
/// }
/// ```
public struct UserRules: Sendable, Equatable {
    public private(set) var safe: [BashRule]
    public private(set) var irreversible: [BashRule]

    public init(safe: [BashRule] = [], irreversible: [BashRule] = []) {
        self.safe = safe
        self.irreversible = irreversible
    }

    public var isEmpty: Bool { safe.isEmpty && irreversible.isEmpty }

    public mutating func addSafe(_ specifier: String) {
        let rule = Self.rule(from: specifier, reason: "")
        guard !safe.contains(where: {
            $0.command == rule.command && $0.subcommand == rule.subcommand
        }) else { return }
        safe.append(rule)
    }

    public mutating func addIrreversible(_ specifier: String, reason: String) {
        let rule = Self.rule(from: specifier, reason: reason)
        irreversible.removeAll {
            $0.command == rule.command && $0.subcommand == rule.subcommand
        }
        irreversible.append(rule)
    }

    // MARK: - Coding

    private struct Wire: Codable {
        var safe: [String]?
        var irreversible: [String: String]?
    }

    public static func decode(_ json: String) throws -> UserRules {
        let wire = try JSONDecoder().decode(Wire.self, from: Data(json.utf8))

        return UserRules(
            safe: (wire.safe ?? []).map { rule(from: $0, reason: "") },
            // Sorted so the order does not shuffle on every rewrite, which
            // would make the file's history unreadable.
            irreversible: (wire.irreversible ?? [:]).sorted { $0.key < $1.key }
                .map { rule(from: $0.key, reason: $0.value) })
    }

    public func encoded() throws -> String {
        let wire = Wire(
            safe: safe.isEmpty ? nil : safe.map(Self.specifier(of:)).sorted(),
            irreversible: irreversible.isEmpty ? nil : Dictionary(
                uniqueKeysWithValues: irreversible.map {
                    (Self.specifier(of: $0), $0.reason)
                }))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(wire), as: UTF8.self)
    }

    /// `"pnpm dlx"` becomes command `pnpm`, subcommand `dlx`. Anything past the
    /// second word is ignored — flags belong to the built-in table's `anyFlag`,
    /// which is deliberately not exposed here.
    static func rule(from specifier: String, reason: String) -> BashRule {
        let words = specifier.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let command = words.first else { return BashRule("", reason: reason) }
        return BashRule(
            command, words.count > 1 ? words[1] : nil, reason: reason)
    }

    static func specifier(of rule: BashRule) -> String {
        rule.subcommand.map { "\(rule.command) \($0)" } ?? rule.command
    }
}
