import Foundation

/// Lexical path handling only.
///
/// `URL.resolvingSymlinksInPath` would be more accurate but touches the
/// filesystem, and the policy engine does no I/O. Lexical normalization can be
/// fooled by a symlink out of the project; that is a known v1 limitation and is
/// noted in the plan's Known Gaps.
public enum PathNormalizer {
    public static func normalize(_ path: String) -> String {
        var stack: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": _ = stack.popLast()
            default: stack.append(String(component))
            }
        }
        return "/" + stack.joined(separator: "/")
    }

    public static func resolve(_ path: String, relativeTo base: String) -> String {
        path.hasPrefix("/") ? normalize(path) : normalize(base + "/" + path)
    }

    public static func contains(dir: String, path: String) -> Bool {
        let dir = normalize(dir)
        let path = normalize(path)
        if dir == path { return true }
        // The trailing slash is what stops /a/b from swallowing /a/bcd.
        return path.hasPrefix(dir == "/" ? "/" : dir + "/")
    }
}
