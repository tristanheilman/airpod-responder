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
        BashRule("rm", reason: "delete files"),
        BashRule("git", "push", anyFlag: ["--force", "-f", "--force-with-lease"],
                 reason: "force push, which rewrites remote history"),
        BashRule("git", "reset", anyFlag: ["--hard"], reason: "discard the working tree"),
        BashRule("git", "rebase", reason: "rewrite history"),
        BashRule("git", "filter-branch", reason: "rewrite history"),
        BashRule("git", "commit", anyFlag: ["--amend"], reason: "rewrite the last commit"),
        BashRule("git", "clean", reason: "delete untracked files"),
        BashRule("npm", "publish", reason: "publish a package"),
        BashRule("pnpm", "publish", reason: "publish a package"),
        BashRule("yarn", "publish", reason: "publish a package"),
        BashRule("cargo", "publish", reason: "publish a crate"),
        BashRule("gem", "push", reason: "publish a gem"),
        BashRule("twine", "upload", reason: "publish to PyPI"),
        BashRule("npm", "install", reason: "install dependencies"),
        BashRule("npm", "i", reason: "install dependencies"),
        BashRule("pnpm", "install", reason: "install dependencies"),
        BashRule("pnpm", "add", reason: "install dependencies"),
        BashRule("yarn", "add", reason: "install dependencies"),
        BashRule("pip", "install", reason: "install dependencies"),
        BashRule("pip3", "install", reason: "install dependencies"),
        BashRule("uv", "add", reason: "install dependencies"),
        BashRule("cargo", "add", reason: "install dependencies"),
        BashRule("brew", "install", reason: "install software"),
        BashRule("ssh", reason: "act on a remote host"),
        BashRule("scp", reason: "copy to or from a remote host"),
        BashRule("rsync", reason: "sync with a remote host"),
        BashRule("kubectl", "delete", reason: "delete cluster resources"),
        BashRule("kubectl", "apply", reason: "change a cluster"),
        BashRule("terraform", "apply", reason: "change infrastructure"),
        BashRule("terraform", "destroy", reason: "destroy infrastructure"),
        BashRule("docker", "push", reason: "publish an image"),
        BashRule("docker", "rm", reason: "delete a container"),
        BashRule("docker", "prune", reason: "delete unused resources"),
        BashRule("aws", reason: "act on cloud infrastructure"),
        BashRule("gcloud", reason: "act on cloud infrastructure"),
    ]

    /// Case-insensitive substrings checked against the whole segment. These
    /// catch destructive payloads passed as arguments, where the command name
    /// alone is harmless.
    public static let irreversibleContent: [(pattern: String, reason: String)] = [
        ("drop table", "drop a database table"),
        ("drop database", "drop a database"),
        ("truncate table", "truncate a database table"),
        ("migrate reset", "reset the database"),
        ("db:reset", "reset the database"),
        ("--no-preserve-root", "delete from the filesystem root"),
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
