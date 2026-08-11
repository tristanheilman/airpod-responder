import Foundation

/// Collapses a burst of failures in one session into a single earcon.
///
/// One failing test is noise. The signal is in the pattern, and that is the
/// thrash detector's job, not this one's.
public struct FailureCoalescer: Sendable {
    private let window: TimeInterval
    private var lastAdmitted: [String: Date] = [:]

    public init(window: TimeInterval = 60) {
        self.window = window
    }

    /// Returns true if this failure should produce a sound.
    public mutating func admit(sessionID: String, at now: Date) -> Bool {
        if let last = lastAdmitted[sessionID], now.timeIntervalSince(last) <= window {
            return false
        }
        lastAdmitted[sessionID] = now
        return true
    }
}
