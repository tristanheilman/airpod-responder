import Foundation
import Testing
@testable import NavigatorAudio

@Suite struct RecordingSpeakerBehavior {
    @Test func recordsSpeechInOrder() {
        let speaker = RecordingSpeaker()
        speaker.say("first")
        speaker.say("second")
        #expect(speaker.spoken == ["first", "second"])
    }

    @Test func recordsEarcons() {
        let speaker = RecordingSpeaker()
        speaker.play(.offRoute)
        speaker.play(.failure)
        #expect(speaker.played == [.offRoute, .failure])
    }

    @Test func stopIsRecordedWithoutErasingHistory() {
        let speaker = RecordingSpeaker()
        speaker.say("x")
        speaker.stop()
        #expect(speaker.spoken == ["x"])
        #expect(speaker.stopCount == 1)
    }

    @Test func isSafeFromSeveralThreads() {
        // The server speaks from its audio queue while commands arrive on
        // another. A double that corrupts its own buffer under that is useless.
        let speaker = RecordingSpeaker()
        let group = DispatchGroup()
        for i in 0..<50 {
            group.enter()
            DispatchQueue.global().async {
                speaker.say("m\(i)")
                group.leave()
            }
        }
        #expect(group.wait(timeout: .now() + 5) == .success)
        #expect(speaker.spoken.count == 50)
    }

    @Test func silentSpeakerDiscardsEverything() {
        let speaker = SilentSpeaker()
        speaker.say("nobody hears this")
        speaker.play(.failure)
        speaker.stop()
        // Nothing to assert but that it does not trap — which is the point.
    }
}
