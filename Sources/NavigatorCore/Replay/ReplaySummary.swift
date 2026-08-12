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

    /// Re-runs delivery over an existing decision log at a different budget.
    ///
    /// This is what makes the log worth keeping. The event-based `run` needs the
    /// original hook payloads, which the daemon does not store — but the budget
    /// question only needs the tier the classifier asked for and when, and the
    /// log has both. So a setting can be tried against a real recorded day
    /// before it is lived with.
    ///
    /// Classification is *not* re-derived: these are the tiers already assigned,
    /// replayed through a different budget.
    public static func rerun(
        records: [DecisionRecord], config: PolicyConfig = .default
    ) -> ReplaySummary {
        // Logs are read per-day and concatenated, so order is not guaranteed —
        // and a token bucket fed out-of-order timestamps silently misbehaves.
        let ordered = records.sorted { $0.at < $1.at }
        guard let first = ordered.first, let last = ordered.last else {
            return ReplaySummary(
                totalEvents: 0, spoken: 0, earcons: 0, queued: 0,
                silent: 0, suppressed: 0, blocking: 0, utterancesPerHour: 0)
        }

        var budget = SpeechBudget(
            capacity: config.speechCapacity,
            interval: config.speechInterval,
            startingAt: first.at)
        var coalescer = FailureCoalescer(window: config.failureWindow)

        var counts: [Tier: Int] = [:]
        var suppressed = 0

        for record in ordered {
            let wanted = record.tierAssigned
            var delivered = wanted

            if wanted == .earcon,
               record.kind == .postToolUseFailure || record.kind == .stopFailure {
                if !coalescer.admit(sessionID: record.sessionID, at: record.at) {
                    delivered = .silent
                }
            } else {
                delivered = budget.admit(wanted, at: record.at)
            }

            if delivered != wanted { suppressed += 1 }
            counts[delivered, default: 0] += 1
        }

        let spoken = Tier.allCases.filter(\.isSpeech)
            .reduce(0) { $0 + (counts[$1] ?? 0) }
        let span = last.at.timeIntervalSince(first.at)
        let hours = span > 0 ? span / 3600 : 1.0 / 3600

        return ReplaySummary(
            totalEvents: ordered.count,
            spoken: spoken,
            earcons: counts[.earcon] ?? 0,
            queued: counts[.silentQueue] ?? 0,
            silent: counts[.silent] ?? 0,
            suppressed: suppressed,
            blocking: counts[.decisionPoint] ?? 0,
            utterancesPerHour: Double(spoken) / hours)
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
