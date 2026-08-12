import Foundation

/// Turns the decision log into a review queue of commands the classifier did
/// not recognise.
///
/// The observer build's log is otherwise a file you read once. This makes it the
/// input to a loop: work normally, see what came back unknown, say which of
/// those are fine, and the classifier gets quieter about your actual tooling.
public enum LearnReport {
    public struct Unknown: Sendable, Equatable {
        public let command: String
        public let count: Int
        public let lastSeen: Date
    }

    private static let prefix = "unknown: unrecognised command "

    public static func unknownCommands(
        in records: [DecisionRecord], since cutoff: Date? = nil
    ) -> [Unknown] {
        var counts: [String: (count: Int, lastSeen: Date)] = [:]

        for record in records {
            if let cutoff, record.at <= cutoff { continue }
            guard record.reversibility.hasPrefix(prefix) else { continue }

            let command = String(record.reversibility.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            guard isNameable(command) else { continue }

            let existing = counts[command]
            counts[command] = (
                count: (existing?.count ?? 0) + 1,
                lastSeen: max(existing?.lastSeen ?? record.at, record.at))
        }

        return counts
            .map { Unknown(command: $0.key, count: $0.value.count, lastSeen: $0.value.lastSeen) }
            // Most frequent first — that is the order in which resolving them
            // buys the most quiet. Ties broken by name so runs are stable.
            .sorted { ($0.count, $1.command) > ($1.count, $0.command) }
    }

    /// A command worth offering to mark safe.
    ///
    /// Anything named by a path is excluded: marking `./scripts/deploy.sh` safe
    /// vouches for whatever that file contains next week, which is not a promise
    /// a name can make.
    private static func isNameable(_ command: String) -> Bool {
        guard !command.isEmpty else { return false }
        guard !command.contains("/") else { return false }
        // Leftover punctuation from a segment that still parsed badly is a bug
        // to fix in the classifier, not something to add to a safe list.
        return command.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }
}
