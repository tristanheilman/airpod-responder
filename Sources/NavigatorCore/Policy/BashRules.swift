import Foundation

/// Matches a shell command segment by its leading tokens.
///
/// Deliberately not a regex. The classifier decides whether to interrupt you,
/// and a rule you cannot read at a glance is a rule you will not trust.
public struct BashRule: Sendable, Equatable {
    public let command: String
    public let subcommand: String?
    /// Any one of these flags must be present. Empty means the rule always
    /// matches once command and subcommand line up.
    public let anyFlag: [String]
    public let reason: String

    public init(_ command: String, _ subcommand: String? = nil,
                anyFlag: [String] = [], reason: String) {
        self.command = command
        self.subcommand = subcommand
        self.anyFlag = anyFlag
        self.reason = reason
    }

    public func matches(tokens: [String]) -> Bool {
        guard let first = tokens.first, first == command else { return false }
        if let subcommand {
            guard tokens.count > 1, tokens[1] == subcommand else { return false }
        }
        guard !anyFlag.isEmpty else { return true }
        return tokens.contains { anyFlag.contains($0) }
    }
}

public enum BashRules {
    public static let irreversibleCommands: [BashRule] = [
        BashRule("rm", reason: "deletes files"),
        BashRule("git", "push", anyFlag: ["--force", "-f", "--force-with-lease"],
                 reason: "force push rewrites remote history"),
        BashRule("git", "reset", anyFlag: ["--hard"], reason: "discards the working tree"),
        BashRule("git", "rebase", reason: "rewrites history"),
        BashRule("git", "filter-branch", reason: "rewrites history"),
        BashRule("git", "commit", anyFlag: ["--amend"], reason: "rewrites the last commit"),
        BashRule("git", "clean", reason: "deletes untracked files"),
        BashRule("npm", "publish", reason: "publishes a package"),
        BashRule("pnpm", "publish", reason: "publishes a package"),
        BashRule("yarn", "publish", reason: "publishes a package"),
        BashRule("cargo", "publish", reason: "publishes a crate"),
        BashRule("gem", "push", reason: "publishes a gem"),
        BashRule("twine", "upload", reason: "publishes to PyPI"),
        BashRule("npm", "install", reason: "installs dependencies"),
        BashRule("npm", "i", reason: "installs dependencies"),
        BashRule("pnpm", "install", reason: "installs dependencies"),
        BashRule("pnpm", "add", reason: "installs dependencies"),
        BashRule("yarn", "add", reason: "installs dependencies"),
        BashRule("pip", "install", reason: "installs dependencies"),
        BashRule("pip3", "install", reason: "installs dependencies"),
        BashRule("uv", "add", reason: "installs dependencies"),
        BashRule("cargo", "add", reason: "installs dependencies"),
        BashRule("brew", "install", reason: "installs software"),
        BashRule("ssh", reason: "acts on a remote host"),
        BashRule("scp", reason: "copies to or from a remote host"),
        BashRule("rsync", reason: "syncs with a remote host"),
        BashRule("kubectl", "delete", reason: "deletes cluster resources"),
        BashRule("kubectl", "apply", reason: "mutates a cluster"),
        BashRule("terraform", "apply", reason: "mutates infrastructure"),
        BashRule("terraform", "destroy", reason: "destroys infrastructure"),
        BashRule("docker", "push", reason: "publishes an image"),
        BashRule("docker", "rm", reason: "deletes a container"),
        BashRule("docker", "prune", reason: "deletes unused resources"),
        BashRule("aws", reason: "acts on cloud infrastructure"),
        BashRule("gcloud", reason: "acts on cloud infrastructure"),
    ]

    /// Case-insensitive substrings checked against the whole segment. These
    /// catch destructive payloads passed as arguments, where the command name
    /// alone is harmless.
    public static let irreversibleContent: [(pattern: String, reason: String)] = [
        ("drop table", "drops a database table"),
        ("drop database", "drops a database"),
        ("truncate table", "truncates a database table"),
        ("migrate reset", "resets the database"),
        ("db:reset", "resets the database"),
        ("--no-preserve-root", "deletes from the filesystem root"),
    ]

    public static let safeCommands: [BashRule] = [
        BashRule("ls", reason: ""), BashRule("cat", reason: ""),
        BashRule("echo", reason: ""), BashRule("pwd", reason: ""),
        BashRule("which", reason: ""), BashRule("grep", reason: ""),
        BashRule("rg", reason: ""), BashRule("find", reason: ""),
        BashRule("head", reason: ""), BashRule("tail", reason: ""),
        BashRule("wc", reason: ""), BashRule("sort", reason: ""),
        BashRule("uniq", reason: ""), BashRule("diff", reason: ""),
        BashRule("jq", reason: ""), BashRule("sed", reason: ""),
        BashRule("awk", reason: ""), BashRule("true", reason: ""),
        BashRule("mkdir", reason: ""), BashRule("touch", reason: ""),
        BashRule("cp", reason: ""), BashRule("mv", reason: ""),
        BashRule("git", "status", reason: ""), BashRule("git", "log", reason: ""),
        BashRule("git", "diff", reason: ""), BashRule("git", "show", reason: ""),
        BashRule("git", "branch", reason: ""), BashRule("git", "add", reason: ""),
        BashRule("git", "commit", reason: ""), BashRule("git", "checkout", reason: ""),
        BashRule("git", "switch", reason: ""), BashRule("git", "stash", reason: ""),
        BashRule("git", "fetch", reason: ""), BashRule("git", "pull", reason: ""),
        BashRule("git", "push", reason: ""), BashRule("git", "worktree", reason: ""),
        BashRule("git", "init", reason: ""), BashRule("git", "remote", reason: ""),
        BashRule("swift", reason: ""), BashRule("cargo", reason: ""),
        BashRule("make", reason: ""), BashRule("pytest", reason: ""),
        BashRule("go", reason: ""), BashRule("npm", "test", reason: ""),
        BashRule("npm", "run", reason: ""), BashRule("pnpm", "test", reason: ""),
        BashRule("pnpm", "run", reason: ""), BashRule("npx", reason: ""),
        BashRule("xcodebuild", reason: ""), BashRule("open", reason: ""),
    ]
}
