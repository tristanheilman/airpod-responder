import Foundation
import Testing
@testable import NavigatorAudio
@testable import NavigatorCore

@Suite struct AnnouncerBehavior {
    let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    private func decision(
        _ tier: Tier, utterance: String? = "something happened"
    ) -> Decision {
        Decision(tier: tier, permission: nil, utterance: utterance,
                 reason: "r", blocking: tier.isBlocking)
    }

    @Test(arguments: [Tier.decisionPoint, .needsInput, .speak])
    func speechTiersSpeak(_ tier: Tier) {
        let speaker = RecordingSpeaker()
        let announcer = Announcer(speaker: speaker)
        _ = announcer.announce(decision(tier), sessionName: "app", at: t0)
        #expect(speaker.spoken.count == 1, "\(tier) did not speak")
    }

    @Test func earconTierPlaysAndDoesNotSpeak() {
        let speaker = RecordingSpeaker()
        let announcer = Announcer(speaker: speaker)
        _ = announcer.announce(decision(.earcon), sessionName: "app", at: t0)

        #expect(speaker.spoken.isEmpty)
        #expect(speaker.played == [.offRoute])
    }

    @Test(arguments: [Tier.silent, .silentQueue])
    func silentTiersMakeNoSound(_ tier: Tier) {
        let speaker = RecordingSpeaker()
        let announcer = Announcer(speaker: speaker)
        _ = announcer.announce(decision(tier), sessionName: "app", at: t0)
        #expect(speaker.spoken.isEmpty)
        #expect(speaker.played.isEmpty)
    }

    @Test func silentQueueStillReturnsAnUtteranceForCatchUp() {
        // Queued items are the entire point of catch-up: unheard, not unrecorded.
        let speaker = RecordingSpeaker()
        let announcer = Announcer(speaker: speaker)
        let recorded = announcer.announce(
            decision(.silentQueue, utterance: nil), sessionName: "app", at: t0)

        #expect(recorded != nil)
        #expect(recorded?.wasSpoken == false)
    }

    @Test func fullySilentDecisionsAreNotRecorded() {
        // Routine allowed tool calls would otherwise flood the transcript and
        // push everything worth recalling out of the ring buffer.
        let speaker = RecordingSpeaker()
        let announcer = Announcer(speaker: speaker)
        let recorded = announcer.announce(
            decision(.silent, utterance: nil), sessionName: "app", at: t0)

        #expect(recorded == nil)
    }

    @Test func recordedUtteranceCarriesTheSpokenText() {
        let speaker = RecordingSpeaker()
        let announcer = Announcer(speaker: speaker)
        let recorded = announcer.announce(
            decision(.speak, utterance: "app is stuck"), sessionName: "app", at: t0)

        #expect(recorded?.text == "app is stuck")
        #expect(recorded?.wasSpoken == true)
        #expect(speaker.spoken == ["app is stuck"])
    }

    @Test func speechTierWithNoTextFallsBackToAnEarcon() {
        // A tier that wants words but has none must not produce silence — that
        // would look identical to the tool being asleep.
        let speaker = RecordingSpeaker()
        let announcer = Announcer(speaker: speaker)
        _ = announcer.announce(decision(.speak, utterance: nil), sessionName: "app", at: t0)

        #expect(speaker.spoken.isEmpty)
        #expect(speaker.played.count == 1)
    }

    @Test func earconEntryStillCarriesReadableTextForCatchUp() {
        // You cannot replay a beep. Catch-up needs words for it either way.
        let speaker = RecordingSpeaker()
        let announcer = Announcer(speaker: speaker)
        let recorded = announcer.announce(
            decision(.earcon, utterance: nil), sessionName: "homelab", at: t0)

        #expect(recorded?.text.contains("homelab") == true)
        #expect(recorded?.wasSpoken == false)
    }
}
