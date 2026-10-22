import Foundation
import Testing
@testable import NavigatorCore

@Suite struct ReversibilityClassification {
    let subject = ReversibilityClassifier()

    private func bash(_ command: String) -> Reversibility {
        subject.classify(toolName: "Bash", toolInput: ["command": .string(command)])
    }

    @Test(arguments: [
        "git status",
        "git log --oneline -10",
        "git diff HEAD",
        "git add .",
        "git commit -m \"feat: thing\"",
        "swift build",
        "swift test --filter Foo",
        "cargo test",
        "npm test",
        "ls -la",
        "rg pattern src/",
        "cat README.md",
        "mkdir -p build",
    ])
    func recognisesReversibleCommands(_ command: String) {
        #expect(bash(command) == .reversible, "expected reversible: \(command)")
    }

    @Test(arguments: [
        "git push --force origin main",
        "git push -f",
        "git push --force-with-lease",
        "git reset --hard HEAD~3",
        "git rebase -i main",
        "git filter-branch --tree-filter true",
        "git commit --amend -m \"oops\"",
        "git clean -fd",
        "rm -rf build",
        "rm somefile.txt",
        "npm publish",
        "cargo publish",
        "npm install lodash",
        "pip install requests",
        "brew install jq",
        "ssh homelab.local uptime",
        "scp file tristan@homelab.local:/tmp",
        "kubectl delete pod foo",
        "terraform apply",
        "npx prisma migrate reset",
    ])
    func recognisesIrreversibleCommands(_ command: String) {
        guard case .irreversible = bash(command) else {
            Issue.record("expected irreversible: \(command)")
            return
        }
    }

    @Test(arguments: [
        "psql -c \"DROP TABLE users\"",
        "psql -c \"drop database app\"",
        "mysql -e \"TRUNCATE TABLE sessions\"",
    ])
    func recognisesIrreversibleSQLByContent(_ command: String) {
        guard case .irreversible = bash(command) else {
            Issue.record("expected irreversible: \(command)")
            return
        }
    }

    @Test(arguments: [
        "navigator approve", "navigator deny", "navigator gate --open",
        "~/.claude/bin/navigator approve",
    ])
    func answeringOnTheDaemonsBehalfIsNeverSilent(_ command: String) {
        // An agent with Bash can run this tool's own commands. It cannot
        // answer the question it is parked behind, but a background process
        // or a second session could, and could open the gate for itself.
        // The classifier cannot stop that; it can make sure it is never
        // quiet. Paths are matched too, because the installed binary is
        // called by path.
        guard case .irreversible(let why) = bash(command) else {
            Issue.record("silent on: \(command)"); return
        }
        #expect(why.contains("navigator"))
    }

    @Test func unrecognisedCommandIsUnknown() {
        guard case .unknown = bash("frobnicate --widget 3") else {
            Issue.record("expected unknown")
            return
        }
    }

    @Test func compoundCommandTakesTheMostDangerousSegment() {
        guard case .irreversible = bash("swift build && rm -rf .build") else {
            Issue.record("expected irreversible")
            return
        }
        guard case .irreversible = bash("git add . ; git push --force") else {
            Issue.record("expected irreversible")
            return
        }
    }

    @Test func compoundCommandWithOneUnknownSegmentIsUnknown() {
        guard case .unknown = bash("swift build && frobnicate") else {
            Issue.record("expected unknown")
            return
        }
    }

    @Test func irreversibleBeatsUnknownInCompound() {
        guard case .irreversible = bash("frobnicate && rm -rf /tmp/x") else {
            Issue.record("expected irreversible")
            return
        }
    }

    @Test(arguments: ["Read", "Glob", "Grep", "Edit", "Write", "NotebookEdit", "TodoWrite"])
    func fileToolsAreReversible(_ tool: String) {
        #expect(subject.classify(toolName: tool, toolInput: nil) == .reversible)
    }

    @Test func webFetchIsUnknownBecauseHostFamiliarityIsNotModelled() {
        guard case .unknown = subject.classify(
            toolName: "WebFetch", toolInput: ["url": .string("https://example.com")]
        ) else {
            Issue.record("expected unknown")
            return
        }
    }

    @Test func unknownToolIsUnknown() {
        guard case .unknown = subject.classify(toolName: "SomeMCPTool", toolInput: nil) else {
            Issue.record("expected unknown")
            return
        }
    }

    @Test func nilToolIsUnknown() {
        guard case .unknown = subject.classify(toolName: nil, toolInput: nil) else {
            Issue.record("expected unknown")
            return
        }
    }

    @Test func bashWithoutCommandIsUnknown() {
        guard case .unknown = subject.classify(toolName: "Bash", toolInput: [:]) else {
            Issue.record("expected unknown")
            return
        }
    }
}
