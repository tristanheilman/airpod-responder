import Foundation

/// Copies built binaries somewhere stable.
///
/// Without this, `install` points `~/.claude/settings.json` at a path inside
/// `.build/`, which `swift package clean` deletes and every rebuild replaces.
/// A hook command that no longer exists fails quietly — Claude Code treats it as
/// a non-blocking error — so the tool would simply stop working with no signal.
public enum BinaryInstaller {
    public enum Failure: Error, Equatable {
        case missing(String)
    }

    /// Copies `names` from `sourceDir` into `destDir`, returning where each landed.
    @discardableResult
    public static func stage(
        names: [String], from sourceDir: URL, to destDir: URL
    ) throws -> [String: URL] {
        try FileManager.default.createDirectory(
            at: destDir, withIntermediateDirectories: true)

        var staged: [String: URL] = [:]

        for name in names {
            let source = sourceDir.appendingPathComponent(name)
            let destination = destDir.appendingPathComponent(name)

            guard FileManager.default.isExecutableFile(atPath: source.path) else {
                throw Failure.missing(name)
            }

            // Installing from the destination itself — re-running `install` out
            // of ~/.claude/bin — would otherwise be a copy onto itself.
            if source.standardizedFileURL != destination.standardizedFileURL {
                // Remove first: the destination may be a running binary, whose
                // inode cannot be written to in place.
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: source, to: destination)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: destination.path)
            }

            staged[name] = destination
        }

        return staged
    }
}
