import Foundation

public struct SessionRegistry: Sendable {
    private var sessions: [String: Session] = [:]

    /// How many ended sessions to keep after they close.
    ///
    /// Some history is useful — a `status` moments after a session ends should
    /// still know what it was. Keeping all of them forever is not: a machine
    /// that opens a handful of Claude Code windows a day accumulates them for as
    /// long as the daemon lives.
    private let endedRetained: Int

    public init(endedRetained: Int = 50) {
        self.endedRetained = endedRetained
    }

    /// Total sessions held, live and ended. Exposed for the growth tests.
    public var trackedCount: Int { sessions.count }

    public func session(id: String) -> Session? { sessions[id] }

    public var activeSessions: [Session] {
        sessions.values.filter(\.isActive).sorted { $0.startedAt < $1.startedAt }
    }

    public mutating func apply(_ stamped: StampedEvent) {
        let event = stamped.event

        var session = sessions[event.sessionID] ?? Session(
            id: event.sessionID,
            cwd: event.cwd,
            startedAt: stamped.at,
            lastEventAt: stamped.at
        )

        session.lastEventAt = stamped.at
        session.cwd = event.cwd

        switch event.kind {
        case .sessionStart:
            session.isActive = true
        case .sessionEnd:
            session.isActive = false
        case .userPromptSubmit:
            // First prompt only. Later prompts refine the work but the route is
            // the destination declared at the outset; re-reading it every turn
            // would make off-route detection track the agent rather than you.
            if session.route == nil { session.route = event.prompt }
        default:
            break
        }

        sessions[event.sessionID] = session

        if event.kind == .sessionEnd { forgetOldestEnded() }
    }

    /// Drops the least recently active ended sessions past the retention limit.
    private mutating func forgetOldestEnded() {
        let ended = sessions.values.filter { !$0.isActive }
        guard ended.count > endedRetained else { return }

        let doomed = ended
            .sorted { $0.lastEventAt < $1.lastEventAt }
            .prefix(ended.count - endedRetained)

        for session in doomed { sessions.removeValue(forKey: session.id) }
    }
}
