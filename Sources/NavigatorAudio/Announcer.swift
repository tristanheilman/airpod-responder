import Foundation
import NavigatorCore

/// Turns a decision into sound, and reports what should go in the transcript.
public struct Announcer: Sendable {
    private let speaker: any Speaker

    public init(speaker: any Speaker) {
        self.speaker = speaker
    }

    /// Returns the transcript entry, or nil for decisions not worth recalling.
    @discardableResult
    public func announce(
        _ decision: Decision, sessionName: String, at now: Date
    ) -> Utterance? {
        switch decision.tier {
        case .decisionPoint, .needsInput, .speak:
            guard let text = decision.utterance, !text.isEmpty else {
                // Wanted words, has none. An earcon at least says "look at me";
                // silence would be indistinguishable from a dead daemon.
                speaker.play(.failure)
                return Utterance(
                    at: now, sessionName: sessionName, text: decision.reason,
                    tier: decision.tier, wasSpoken: false)
            }
            speaker.say(text)
            return Utterance(
                at: now, sessionName: sessionName, text: text,
                tier: decision.tier, wasSpoken: true)

        case .earcon:
            speaker.play(.offRoute)
            return Utterance(
                at: now, sessionName: sessionName,
                text: decision.utterance ?? "\(sessionName): \(decision.reason)",
                tier: .earcon, wasSpoken: false)

        case .silentQueue:
            return Utterance(
                at: now, sessionName: sessionName,
                text: decision.utterance ?? "\(sessionName): \(decision.reason)",
                tier: .silentQueue, wasSpoken: false)

        case .silent:
            // A delivered `.silent` means two very different things.
            //
            // If silence was also what the classifier wanted, this is a routine
            // allowed call — recording it would flood the ring buffer and evict
            // everything worth recalling.
            //
            // If it wanted to say something and mute, the budget or the
            // concurrency gate stopped it, this is precisely what catch-up
            // exists to report. Dropping it would make "what did I miss?"
            // answer "nothing" for the whole time you were muted.
            guard decision.wasSuppressed else { return nil }

            return Utterance(
                at: now, sessionName: sessionName,
                text: decision.utterance ?? "\(sessionName): \(decision.reason)",
                tier: decision.intendedTier, wasSpoken: false)
        }
    }
}
