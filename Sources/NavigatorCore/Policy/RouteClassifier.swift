import Foundation

public enum RouteStatus: Sendable, Equatable {
    case onRoute
    case offRoute(reason: String)
}

public struct RouteClassifier: Sendable {
    /// Tools that write to a path. Only these can be off-route by location.
    private static let writingTools: Set<String> = ["Edit", "Write", "NotebookEdit"]

    public init() {}

    public func classify(
        toolName: String?,
        toolInput: [String: JSONValue]?,
        session: Session
    ) -> RouteStatus {
        guard let toolName, Self.writingTools.contains(toolName) else { return .onRoute }
        guard let rawPath = toolInput?["file_path"]?.stringValue else { return .onRoute }

        let path = PathNormalizer.resolve(rawPath, relativeTo: session.cwd)
        let permitted = [session.cwd] + session.declaredDirs

        for dir in permitted where PathNormalizer.contains(dir: dir, path: path) {
            return .onRoute
        }
        // Base-form verb phrase, like the reversibility reasons: these get read
        // aloud after "wants to", and "wants to writes to" is what you would
        // actually hear otherwise.
        return .offRoute(reason: "write to \(path), outside \(session.cwd)")
    }
}
