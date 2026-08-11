import Foundation

public struct Session: Sendable, Equatable {
    public let id: String
    public var cwd: String
    /// Additional directories the session is permitted to write to, beyond `cwd`.
    /// Populated by the daemon from Claude Code's configuration; empty in v1.
    public var declaredDirs: [String]
    /// The session's first user prompt, used as its stated destination.
    public var route: String?
    public var startedAt: Date
    public var lastEventAt: Date
    public var isActive: Bool

    public init(
        id: String,
        cwd: String,
        declaredDirs: [String] = [],
        route: String? = nil,
        startedAt: Date,
        lastEventAt: Date,
        isActive: Bool = true
    ) {
        self.id = id
        self.cwd = cwd
        self.declaredDirs = declaredDirs
        self.route = route
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
        self.isActive = isActive
    }
}
