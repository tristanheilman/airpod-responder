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
        // The gate is a code-level decision for this build. Letting a stray
        // config file flip it would undo the guarantee the observer rests on.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"emitDecisions": true}"#.write(to: url, atomically: true, encoding: .utf8)

        #expect(ConfigFile.load(from: url).emitDecisions == false)
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
