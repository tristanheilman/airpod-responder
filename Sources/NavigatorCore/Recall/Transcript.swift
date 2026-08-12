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

    /// Spoken summary of what every live session is doing.
    ///
    /// Grouped by project, because sessions are named after their directory and
    /// two windows on one repo is normal. Ungrouped it said "2 sessions:
    /// airpod-responder, working. airpod-responder, working." — the same name
    /// twice, telling you nothing.
    public func statusDigest(sessions: [Session], at now: Date) -> String {
        guard !sessions.isEmpty else { return "No active sessions." }

        var order: [String] = []
        var groups: [String: [SessionState]] = [:]

        for session in sessions {
            let name = Self.name(of: session)
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(Self.state(of: session, at: now))
        }

        let parts = order.map { name -> String in
            let states = groups[name] ?? []

            // One session: a full sentence reads best — "app is working".
            if states.count == 1 { return "\(name) \(states[0].sentence)" }

            // Several in the same state: the bare form composes after a
            // quantifier, where the sentence form would give "all is working".
            if Set(states).count == 1 {
                let quantity = states.count == 2 ? "both" : "all"
                return "\(states.count) sessions in \(name), \(quantity) \(states[0].bare)"
            }

            return "\(name) has \(states.count) sessions: "
                + states.map(\.bare).joined(separator: ", ")
        }

        return parts.joined(separator: ". ") + "."
    }

    private enum SessionState: Equatable, Hashable {
        case working
        case quiet(minutes: Int)

        /// After a quantifier: "both working", "all quiet for 3 minutes".
        var bare: String {
            switch self {
            case .working: "working"
            case .quiet(let minutes): "quiet for \(minutes) minute\(minutes == 1 ? "" : "s")"
            }
        }

        /// On its own: "app is working", "app has been quiet for 3 minutes".
        var sentence: String {
            switch self {
            case .working: "is working"
            case .quiet(let minutes):
                "has been quiet for \(minutes) minute\(minutes == 1 ? "" : "s")"
            }
        }
    }

    /// 90 seconds, not 120: at a two-minute threshold integer division can never
    /// yield "1 minute", so the singular was unreachable and the shortest thing
    /// it could ever report was "quiet for 2 minutes".
    private static let quietAfter: TimeInterval = 90

    private static func state(of session: Session, at now: Date) -> SessionState {
        let idle = now.timeIntervalSince(session.lastEventAt)
        guard idle >= quietAfter else { return .working }
        return .quiet(minutes: Int(idle) / 60)
    }

    public static func name(of session: Session) -> String {
        PathNormalizer.normalize(session.cwd)
            .split(separator: "/").last.map(String.init) ?? "a session"
    }
}
