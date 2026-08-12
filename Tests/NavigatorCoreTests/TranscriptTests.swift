import Foundation
import Testing
@testable import NavigatorCore

@Suite struct TranscriptBehavior {
    let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    private func utterance(
        _ text: String, spoken: Bool = true, tier: Tier = .speak, plus: TimeInterval = 0
    ) -> Utterance {
        Utterance(at: t0.addingTimeInterval(plus), sessionName: "app",
                  text: text, tier: tier, wasSpoken: spoken)
    }

    @Test func lastSpokenIgnoresSuppressedOnes() {
        // "Repeat" must replay what you actually heard, not what was suppressed
        // — otherwise it invents a memory you never had.
        var transcript = Transcript()
        transcript.record(utterance("first"))
        transcript.record(utterance("suppressed", spoken: false, plus: 10))

        #expect(transcript.lastSpoken?.text == "first")
    }

    @Test func lastSpokenIsNilOnAnEmptyTranscript() {
        let transcript = Transcript()
        #expect(transcript.lastSpoken == nil)
    }

    @Test func digestSummarisesEverythingSinceAMoment() {
        var transcript = Transcript()
        transcript.record(utterance("one", plus: 0))
        transcript.record(utterance("two", plus: 100))
        transcript.record(utterance("three", plus: 200))

        let digest = transcript.digest(since: t0.addingTimeInterval(50))

        #expect(digest.contains("two"))
        #expect(digest.contains("three"))
        #expect(!digest.contains("one"))
    }

    @Test func digestIncludesSuppressedItems() {
        // Catch-up is precisely for what you did *not* hear.
        var transcript = Transcript()
        transcript.record(utterance("spoken", plus: 0))
        transcript.record(utterance("quiet", spoken: false, plus: 10))

        let digest = transcript.digest(since: nil)
        #expect(digest.contains("quiet"))
    }

    @Test func digestOfNothingSaysSo() {
        let transcript = Transcript()
        let digest = transcript.digest(since: nil)
        #expect(digest.lowercased().contains("nothing"))
    }

    @Test func ringBufferDropsOldestBeyondCapacity() {
        var transcript = Transcript(capacity: 3)
        for i in 0..<10 {
            transcript.record(utterance("item\(i)", plus: Double(i)))
        }
        #expect(transcript.count == 3)

        let digest = transcript.digest(since: nil)
        #expect(digest.contains("item9"))
        #expect(!digest.contains("item0"))
    }

    @Test func statusDigestNamesEachActiveSession() {
        let transcript = Transcript()
        let sessions = [
            Session(id: "a", cwd: "/Users/t/Projects/app",
                    startedAt: t0, lastEventAt: t0.addingTimeInterval(60)),
            Session(id: "b", cwd: "/Users/t/Projects/homelab",
                    startedAt: t0, lastEventAt: t0.addingTimeInterval(30)),
        ]

        let status = transcript.statusDigest(
            sessions: sessions, at: t0.addingTimeInterval(120))

        #expect(status.contains("app"))
        #expect(status.contains("homelab"))
    }

    @Test func statusDigestOfNoSessionsSaysSo() {
        let transcript = Transcript()
        let status = transcript.statusDigest(sessions: [], at: t0)
        #expect(status.lowercased().contains("no"))
    }

    @Test func statusDigestCallsOutAQuietSession() {
        let transcript = Transcript()
        let sessions = [
            Session(id: "a", cwd: "/Users/t/Projects/app",
                    startedAt: t0, lastEventAt: t0),
        ]
        // Ten minutes since the last event is the thing worth knowing.
        let status = transcript.statusDigest(
            sessions: sessions, at: t0.addingTimeInterval(600))

        #expect(status.contains("10 minutes"))
    }
}
