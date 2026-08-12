import Foundation

/// A bounded rolling record of what the navigator said and nearly said.
///
/// Bounded because the daemon runs for days: the permanent record is the
/// decision log on disk, and this only has to answer "what did I miss?".
public struct Transcript: Sendable {
    private var items: [Utterance] = []
    private let capacity: Int

    public init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { items.count }

    public mutating func record(_ utterance: Utterance) {
        items.append(utterance)
        if items.count > capacity {
            items.removeFirst(items.count - capacity)
        }
    }

    /// The last thing you actually heard.
    ///
    /// Suppressed utterances are skipped: replaying one would tell you about a
    /// moment you have no memory of, which is worse than saying nothing.
    public var lastSpoken: Utterance? {
        items.last { $0.wasSpoken }
    }

    public func digest(since moment: Date?) -> String {
        let relevant = items.filter { item in
            moment.map { item.at > $0 } ?? true
        }
        guard !relevant.isEmpty else { return "Nothing to catch up on." }

        return relevant
            .map { $0.wasSpoken ? $0.text : "\($0.text) (not spoken at the time)" }
            .joined(separator: " ")
    }

    public func statusDigest(sessions: [Session], at now: Date) -> String {
        guard !sessions.isEmpty else { return "No active sessions." }

        let parts = sessions.map { session -> String in
            let name = Self.name(of: session)
            let idle = Int(now.timeIntervalSince(session.lastEventAt))
            return idle > 120
                ? "\(name), quiet for \(idle / 60) minutes"
                : "\(name), working"
        }
        return "\(sessions.count) session\(sessions.count == 1 ? "" : "s"): "
            + parts.joined(separator: ". ") + "."
    }

    public static func name(of session: Session) -> String {
        PathNormalizer.normalize(session.cwd)
            .split(separator: "/").last.map(String.init) ?? "a session"
    }
}
