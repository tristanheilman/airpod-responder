import Foundation
import Testing
@testable import NavigatorCore
@testable import NavigatorIO

@Suite struct ConfigFileBehavior {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("navcfg-\(UUID().uuidString).json")
    }

    @Test func missingFileYieldsDefaults() {
        #expect(ConfigFile.load(from: tempURL()) == PolicyConfig.default)
    }

    @Test func malformedFileYieldsDefaultsRatherThanCrashing() throws {
        // A daemon that refuses to start because someone fat-fingered a comma is
        // worse than one that runs with defaults.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "{ not json".write(to: url, atomically: true, encoding: .utf8)

        #expect(ConfigFile.load(from: url) == PolicyConfig.default)
    }

    @Test func roundTrips() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var config = PolicyConfig.default
        config.speechInterval = 12
        config.thrashRepeatThreshold = 7
        try ConfigFile.write(config, to: url)

        let back = ConfigFile.load(from: url)
        #expect(back.speechInterval == 12)
        #expect(back.thrashRepeatThreshold == 7)
    }

    @Test func partialFileKeepsDefaultsForOmittedKeys() throws {
        // Hand-editing one value must not reset the others.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"speechInterval": 15}"#.write(to: url, atomically: true, encoding: .utf8)

        let config = ConfigFile.load(from: url)
        #expect(config.speechInterval == 15)
        #expect(config.thrashRepeatThreshold == PolicyConfig.default.thrashRepeatThreshold)
    }

    @Test func aFileCannotOpenTheWireGate() throws {
        // The switch alone is not enough. A config edit meant to change
        // speechInterval must not be able to open the gate by typo or by
        // copying an example.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"emitDecisions": true}"#.write(to: url, atomically: true, encoding: .utf8)

        #expect(ConfigFile.load(from: url).emitDecisions == false)
    }

    @Test func theAcknowledgementAloneDoesNotOpenItEither() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"iUnderstandThisAnswersClaudeCode": true}"#
            .write(to: url, atomically: true, encoding: .utf8)

        #expect(ConfigFile.load(from: url).emitDecisions == false)
    }

    @Test func itOpensOnlyWithBothKeys() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"emitDecisions": true, "iUnderstandThisAnswersClaudeCode": true}"#
            .write(to: url, atomically: true, encoding: .utf8)

        let config = ConfigFile.load(from: url)
        #expect(config.emitDecisions == true)
        // Phrasing follows capability: with the gate open and a terminal to
        // answer from, "Approve?" is a real question again.
        #expect(config.canAcceptAnswers == true)
        // ...but the engine's own verdicts still stay home.
        #expect(config.autoAllow == false)
    }

    @Test func canAcceptAnswersIsDerivedNeverRead() throws {
        // It once drifted from reality by hand. Now it cannot be set at all.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"canAcceptAnswers": true}"#.write(to: url, atomically: true, encoding: .utf8)

        #expect(ConfigFile.load(from: url).canAcceptAnswers == false)
    }

    @Test func autoAllowIsReadableButInertWithTheGateShut() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"autoAllow": true}"#.write(to: url, atomically: true, encoding: .utf8)

        let config = ConfigFile.load(from: url)
        #expect(config.autoAllow == true)
        #expect(config.emitDecisions == false)
    }

    @Test func openingAndClosingTheGateEditsOnlyTheGateKeys() throws {
        // `navigator gate --open` must not disturb a hand-tuned budget.
        let before: [String: Any] = ["speechInterval": 15]

        let opened = ConfigFile.gate(before, open: true)
        #expect(opened["speechInterval"] as? Int == 15)
        #expect(opened["emitDecisions"] as? Bool == true)
        #expect(opened["iUnderstandThisAnswersClaudeCode"] as? Bool == true)

        let closed = ConfigFile.gate(opened, open: false)
        #expect(closed["speechInterval"] as? Int == 15)
        #expect(closed["emitDecisions"] == nil)
        #expect(closed["iUnderstandThisAnswersClaudeCode"] == nil)
    }

    @Test func describeSaysWhichModeItIsIn() {
        // Narrating and acting must never be something you have to infer.
        var open = PolicyConfig.default
        open.emitDecisions = true
        #expect(ConfigFile.describe(.default).contains("CLOSED"))
        #expect(ConfigFile.describe(open).contains("OPEN"))
    }

    @Test func defaultBudgetIsDeliberatelyLoose() {
        // Starts generous: the rate that suits this person is unknown, and an
        // over-tight default reads as a broken tool rather than a quiet one.
        #expect(PolicyConfig.default.speechInterval == 60)
    }

    @Test func describeMentionsTheBudget() {
        #expect(ConfigFile.describe(.default).contains("60"))
    }
}
