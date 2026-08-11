import Foundation

public struct SessionRegistry: Sendable {
    private var sessions: [String: Session] = [:]

    public init() {}

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
    }
}
