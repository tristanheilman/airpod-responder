import Foundation
import Testing
@testable import NavigatorCore

@Suite struct UserRulesParsing {
    @Test func parsesBareCommandNames() throws {
        let rules = try UserRules.decode(#"{"safe": ["tailscale", "bun"]}"#)
        #expect(rules.safe.map(\.command).sorted() == ["bun", "tailscale"])
        #expect(rules.safe.allSatisfy { $0.subcommand == nil })
    }

    @Test func parsesCommandAndSubcommandPairs() throws {
        let rules = try UserRules.decode(#"{"safe": ["pnpm dlx"]}"#)
        #expect(rules.safe.first?.command == "pnpm")
        #expect(rules.safe.first?.subcommand == "dlx")
    }

    @Test func parsesIrreversibleEntriesWithReasons() throws {
        let rules = try UserRules.decode(
            #"{"irreversible": {"flyctl deploy": "deploy to production"}}"#)
        #expect(rules.irreversible.first?.command == "flyctl")
        #expect(rules.irreversible.first?.subcommand == "deploy")
        #expect(rules.irreversible.first?.reason == "deploy to production")
    }

    @Test func missingKeysAreEmptyNotAnError() throws {
        let rules = try UserRules.decode("{}")
        #expect(rules.safe.isEmpty)
        #expect(rules.irreversible.isEmpty)
    }

    @Test func malformedJSONThrowsRatherThanSilentlyEmptying() {
        // A typo in a hand-edited file must be reported. Silently reverting to
        // built-ins would look identical to the file being ignored.
        #expect(throws: (any Error).self) {
            try UserRules.decode("{ not json")
        }
    }

    @Test func roundTripsThroughAddingACommand() throws {
        var rules = UserRules()
        rules.addSafe("tailscale")
        rules.addSafe("pnpm dlx")

        let back = try UserRules.decode(try rules.encoded())
        #expect(back.safe.count == 2)
        #expect(back.safe.contains { $0.command == "pnpm" && $0.subcommand == "dlx" })
    }

    @Test func addingTheSameCommandTwiceIsIdempotent() throws {
        var rules = UserRules()
        rules.addSafe("tailscale")
        rules.addSafe("tailscale")
        #expect(rules.safe.count == 1)
    }

    @Test func encodedFormIsHandEditable() throws {
        var rules = UserRules()
        rules.addSafe("tailscale")
        let text = try rules.encoded()
        // Pretty-printed and sorted: the point of this file is that a human
        // opens it and changes a line.
        #expect(text.contains("\n"))
        #expect(text.contains("tailscale"))
    }
}

@Suite struct UserRulesLayering {
    private func classifier(_ json: String) throws -> ReversibilityClassifier {
        ReversibilityClassifier(userRules: try UserRules.decode(json))
    }

    private func bash(_ subject: ReversibilityClassifier, _ command: String) -> Reversibility {
        subject.classify(toolName: "Bash", toolInput: ["command": .string(command)])
    }

    @Test func aUserSafeRuleResolvesAnUnknownCommand() throws {
        let subject = try classifier(#"{"safe": ["tailscale"]}"#)
        #expect(bash(subject, "tailscale status") == .reversible)
    }

    @Test func aUserIrreversibleRuleFlagsAnUnknownCommand() throws {
        let subject = try classifier(
            #"{"irreversible": {"flyctl deploy": "deploy to production"}}"#)
        guard case .irreversible(let reason) = bash(subject, "flyctl deploy --now") else {
            Issue.record("expected irreversible")
            return
        }
        #expect(reason == "deploy to production")
    }

    @Test func aUserIrreversibleRuleOverridesABuiltInSafeOne() throws {
        // `git push` is built-in safe. Someone who wants to hear about every
        // push should be able to say so.
        let subject = try classifier(#"{"irreversible": {"git push": "push to a remote"}}"#)
        guard case .irreversible = bash(subject, "git push origin main") else {
            Issue.record("user rule did not take precedence")
            return
        }
    }

    @Test func aUserSafeRuleCannotUnflagABuiltInDanger() throws {
        // Deliberate asymmetry. Adding to the safe list is routine housekeeping
        // done from a log; letting it silently disarm `rm` or a force push would
        // turn a convenience into the one thing this must never do.
        let subject = try classifier(#"{"safe": ["rm", "git push --force"]}"#)
        guard case .irreversible = bash(subject, "rm -rf build") else {
            Issue.record("a user safe rule disarmed a built-in danger")
            return
        }
    }

    @Test func noUserRulesBehavesExactlyAsBefore() throws {
        let subject = try classifier("{}")
        #expect(bash(subject, "swift build") == .reversible)
        guard case .unknown = bash(subject, "tailscale status") else {
            Issue.record("expected unknown")
            return
        }
    }
}
