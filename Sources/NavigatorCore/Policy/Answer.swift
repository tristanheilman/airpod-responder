import Foundation

/// What a person said to a parked question.
///
/// Lives in Core rather than IO because the decision log records it: later
/// the log has to say how often a nod was the answer, and how often nobody was.
public enum Answer: String, Sendable, Equatable, Codable {
    case approve
    case deny
    /// Hand it back to the on-screen prompt.
    case escalate
}

/// Where an answer came from. The terminal is the first; gestures and voice
/// plug in beside it without the question caring which.
public enum AnswerSource: String, Sendable, Equatable, Codable, CaseIterable {
    case terminal
    case gesture
    case voice
}
