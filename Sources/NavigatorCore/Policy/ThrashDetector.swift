import Foundation

/// Detects an agent stuck on the same error with no progress between attempts.
///
/// This is the one pattern worth promoting to speech: it is rare, it is
/// expensive to discover forty minutes late, and it is unambiguous.
public struct ThrashDetector: Sendable {
    public enum Verdict: Sendable, Equatable {
        case quiet
        case thrashing(signature: String, elapsed: TimeInterval, count: Int)
    }

    private struct Streak {
        var signature: String
        var count: Int
        var firstSeen: Date
    }

    private let repeatThreshold: Int
    private let minimumDuration: TimeInterval
    private var streaks: [String: Streak] = [:]

    public init(repeatThreshold: Int = 3, minimumDuration: TimeInterval = 180) {
        self.repeatThreshold = repeatThreshold
        self.minimumDuration = minimumDuration
    }

    public mutating func recordFailure(
        sessionID: String, signature: String, at now: Date
    ) -> Verdict {
        var streak = streaks[sessionID]
        if streak?.signature != signature {
            streak = Streak(signature: signature, count: 0, firstSeen: now)
        }
        guard var current = streak else { return .quiet }

        current.count += 1
        streaks[sessionID] = current

        let elapsed = now.timeIntervalSince(current.firstSeen)
        // Both gates matter: the count says it is not a one-off, and the
        // duration says it is not just a fast retry loop.
        guard current.count >= repeatThreshold, elapsed >= minimumDuration else {
            return .quiet
        }
        return .thrashing(signature: signature, elapsed: elapsed, count: current.count)
    }

    /// A file changed, so the next attempt is a genuinely new one.
    public mutating func noteFileChanged(sessionID: String) {
        streaks.removeValue(forKey: sessionID)
    }

    /// A session that has ended cannot still be stuck.
    public mutating func forget(sessionID: String) {
        streaks.removeValue(forKey: sessionID)
    }

    /// Reduces an error message to something stable across attempts.
    ///
    /// Digits are the volatile part — line numbers, addresses, elapsed times —
    /// so they are stripped. Without this, no two runs ever match and the
    /// detector never fires.
    public static func signature(from message: String?) -> String {
        guard let message else { return "<none>" }
        let stripped = message.map { $0.isNumber ? "#" : $0 }
        return String(stripped)
            .split(whereSeparator: \.isWhitespace)
            .prefix(20)
            .joined(separator: " ")
            .lowercased()
    }
}
