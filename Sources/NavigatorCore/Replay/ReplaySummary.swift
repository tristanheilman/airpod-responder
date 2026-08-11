import Foundation

public struct ReplaySummary: Sendable, Equatable {
    public let totalEvents: Int
    public let spoken: Int
    public let earcons: Int
    public let queued: Int
    public let silent: Int
    public let suppressed: Int
    public let blocking: Int
    public let utterancesPerHour: Double
}

public enum Replay {
    struct Line: Decodable {
        let at: Date
        let event: HookEvent
    }

    public static func parse(jsonl: String) throws -> [StampedEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try jsonl
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                let parsed = try decoder.decode(Line.self, from: Data(line.utf8))
                return StampedEvent(event: parsed.event, at: parsed.at)
            }
    }

    public static func run(
        events: [StampedEvent], config: PolicyConfig = .default
    ) -> (ReplaySummary, [DecisionRecord]) {
        guard let first = events.first else {
            return (ReplaySummary(
                totalEvents: 0, spoken: 0, earcons: 0, queued: 0,
                silent: 0, suppressed: 0, blocking: 0, utterancesPerHour: 0), [])
        }

        var engine = PolicyEngine(config: config, startingAt: first.at)
        for event in events {
            let decision = engine.decide(event)
            // The harness answers instantly; a real user does not, but modelling
            // answer latency would make the concurrency gate the dominant effect
            // and drown out the budget, which is what we are here to measure.
            if decision.blocking { engine.resolveQuestion() }
        }

        let records = engine.log
        let spoken = records.count { $0.delivered.isSpeech }
        let span = events.last!.at.timeIntervalSince(first.at)
        let hours = span > 0 ? span / 3600 : 1.0 / 3600

        return (ReplaySummary(
            totalEvents: events.count,
            spoken: spoken,
            earcons: records.count { $0.delivered == .earcon },
            queued: records.count { $0.delivered == .silentQueue },
            silent: records.count { $0.delivered == .silent },
            suppressed: records.count { $0.suppressedBecause != nil },
            blocking: records.count { $0.delivered.isBlocking },
            utterancesPerHour: Double(spoken) / hours), records)
    }
}
