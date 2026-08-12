import Foundation
import Testing
@testable import NavigatorCore

/// Shapes taken from the decision log after an hour of real sessions.
///
/// The original suite had 33 Bash cases and passed all of them, because every
/// one was a clean single command. Three of the first four *real* commands
/// classified as unknown — on fragments like `)"` and `fi`, which are not
/// commands at all. These are the shapes that actually occur.
@Suite struct RealCommandClassification {
    let subject = ReversibilityClassifier()

    private func bash(_ command: String) -> Reversibility {
        subject.classify(toolName: "Bash", toolInput: ["command": .string(command)])
    }

    // MARK: - The fragments that started this

    @Test func shellKeywordsAreNotCommands() {
        // `if [ -f x ]; then y; fi` used to split into three "commands",
        // two of which were `then` and `fi`.
        #expect(bash("if [ -f Package.swift ]; then echo yes; fi") == .reversible)
        #expect(bash("for f in *.swift; do echo $f; done") == .reversible)
        #expect(bash("while read line; do echo $line; done") == .reversible)
    }

    @Test func separatorsInsideQuotesDoNotSplit() {
        // A `;` inside a string used to tear the command in half and leave
        // `)"` behind as the supposed program name.
        guard case .unknown(let reason) = bash(#"python3 -c "import json; print(1)""#) else {
            Issue.record("expected unknown")
            return
        }
        #expect(reason.contains("python3"), "misidentified the command: \(reason)")
    }

    @Test func commandSubstitutionDoesNotSplit() {
        #expect(bash(#"echo "$(git rev-parse HEAD)""#) == .reversible)
        #expect(bash("echo $(date) >> log.txt") == .reversible)
    }

    @Test func pipedHeredocStyleQuotingSurvives() {
        #expect(bash(#"grep -c '"theme"' /tmp/out.txt"#) == .reversible)
    }

    // MARK: - Ordinary things that were being deferred

    @Test(arguments: [
        "gh pr list",
        "gh pr view 12 --json title",
        "printf '%s\\n' hello",
        "basename /a/b/c",
        "dirname /a/b/c",
        "uname -a",
        "date -u +%Y-%m-%d",
        "shasum Package.swift",
        "stat -f %z Package.swift",
        "realpath .",
        "env",
        "seq 1 10",
        "tr a b",
        "cut -d, -f1",
        "du -sh .",
        "df -h",
        "ps aux",
        "file Package.swift",
        "test -f Package.swift",
    ])
    func ordinaryToolsAreRecognised(_ command: String) {
        #expect(bash(command) == .reversible, "still unknown: \(command)")
    }

    @Test func leadingEnvironmentAssignmentsAreSkipped() {
        #expect(bash("NAVIGATOR_SOCKET=/tmp/x.sock swift build") == .reversible)
        #expect(bash("FOO=bar BAZ=qux git status") == .reversible)
    }

    @Test func multilineScriptsClassifyByTheirParts() {
        let script = """
        swift build
        swift test --filter Foo
        echo done
        """
        #expect(bash(script) == .reversible)
    }

    // MARK: - Nothing dangerous may slip through

    @Test func dangerousCommandsInsideStructureAreStillCaught() {
        guard case .irreversible = bash("if [ -d build ]; then rm -rf build; fi") else {
            Issue.record("missed rm inside an if block")
            return
        }
        guard case .irreversible = bash("for f in *; do rm $f; done") else {
            Issue.record("missed rm inside a for loop")
            return
        }
    }

    @Test func dangerousCommandsAfterSeparatorsAreStillCaught() {
        guard case .irreversible = bash("swift build && git push --force") else {
            Issue.record("missed force push after &&")
            return
        }
        guard case .irreversible = bash("echo a ; rm -rf b") else {
            Issue.record("missed rm after ;")
            return
        }
    }

    @Test func quotedDangerIsNeverAllowed() {
        // Not splitting inside quotes means a dangerous string is no longer seen
        // as its own segment. That must degrade to unknown — which defers — and
        // never to reversible, which would auto-allow.
        let verdict = bash(#"python3 -c "import os; os.system('rm -rf /tmp/x')""#)
        #expect(verdict != .reversible, "quoted danger was classified as safe")
    }

    @Test func sudoIsNeverRoutine() {
        guard case .irreversible = bash("sudo rm -rf /var/tmp/x") else {
            Issue.record("sudo not flagged")
            return
        }
        guard case .irreversible = bash("sudo systemsetup -setremotelogin on") else {
            Issue.record("sudo not flagged")
            return
        }
    }

    @Test func contentPatternsStillFireInsideQuotes() {
        // These are the one case where looking inside a string is the point.
        guard case .irreversible = bash(#"psql -c "DROP TABLE users""#) else {
            Issue.record("missed DROP TABLE")
            return
        }
    }
}

extension RealCommandClassification {
    // What is inside `$( )` executes, so it is classified rather than ignored.
    // The outer command tells you nothing about it: `echo $(rm -rf x)` is not
    // an echo.

    @Test func aSafeSubstitutionIsSafe() {
        #expect(bash("for f in $(ls /tmp); do echo $f; done") == .reversible)
        #expect(bash(#"echo "$(git rev-parse HEAD)""#) == .reversible)
    }

    @Test func aDangerousSubstitutionIsCaughtThroughASafeOuterCommand() {
        guard case .irreversible = bash("echo $(rm -rf /tmp/x)") else {
            Issue.record("a safe outer command vouched for a dangerous inner one")
            return
        }
        guard case .irreversible = bash("for f in $(rm -rf /tmp/x); do echo $f; done") else {
            Issue.record("missed rm inside a loop header substitution")
            return
        }
    }

    @Test func anUnknownSubstitutionIsNotVouchedFor() {
        guard case .unknown = bash("echo $(frobnicate --widget)") else {
            Issue.record("echo vouched for an unrecognised inner command")
            return
        }
    }

    @Test func redirectionIsNotASeparator() {
        // `2>&1` was being split on the `&`, leaving `1` as the program name —
        // the single most common false unknown in real traffic.
        #expect(bash("swift test 2>&1 | grep -E pattern") == .reversible)
        #expect(bash("swift build > /tmp/out.txt 2>&1") == .reversible)
    }

    @Test func substitutionsDoNotLeakIntoTheOuterCommand() {
        // `LOG=…$(date -u +%F).jsonl` used to report `-u` as the command.
        #expect(bash("LOG=/tmp/decisions-$(date -u +%Y-%m-%d).jsonl") == .reversible)
    }
}

extension RealCommandClassification {
    // Heredoc bodies are data, not commands. Treating them as commands reported
    // the terminator — `EOF`, `PY` — as an unrecognised program, and would
    // classify prose in a commit message as though someone had typed it.

    @Test func heredocBodiesAreNotCommands() {
        #expect(bash("cat >> file.swift <<'EOF'\nfunc thing() {}\nEOF") == .reversible)
        #expect(bash("python3 - <<'PY'\nimport json\nPY") == .unknown(
            reason: "unrecognised command python3"))
        #expect(bash("cat <<EOF > /tmp/x\nhello\nEOF") == .reversible)
        #expect(bash("cat <<-EOF\n\tindented\nEOF") == .reversible)
    }

    @Test func commandsAfterAHeredocStillCount() {
        // The body ends at the terminator; what follows is real again.
        guard case .irreversible = bash("cat <<'EOF' > x\nbody\nEOF\nrm -rf build") else {
            Issue.record("lost the command after the heredoc terminator")
            return
        }
    }

    @Test func aHeredocFeedingAShellIsStillCode() {
        // `bash <<EOF` really does execute its body. Stripping it would hide
        // whatever is in there, which is the one direction that is not safe.
        guard case .irreversible = bash("bash <<'EOF'\nrm -rf /tmp/x\nEOF") else {
            Issue.record("stripped a body that actually executes")
            return
        }
        guard case .irreversible = bash("sh <<EOF\ngit push --force\nEOF") else {
            Issue.record("stripped a body that actually executes")
            return
        }
    }

    @Test func quotedAngleBracketsAreNotAHeredoc() {
        // `echo "a << b"` must not swallow the following lines, which would
        // silently drop real commands from classification.
        guard case .irreversible = bash("echo \"a << b\"\nrm -rf build") else {
            Issue.record("a quoted << swallowed the next line")
            return
        }
    }

    @Test func hereStringsAreNotHeredocs() {
        #expect(bash("grep pattern <<< \"$VAR\"") == .reversible)
    }
}
