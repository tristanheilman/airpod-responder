import Foundation

/// Every number here is a guess pending real use. They are gathered in one
/// place so the harness can sweep them and the config file can override them.
public struct PolicyConfig: Sendable, Equatable, Codable {
    public var speechCapacity: Double

    /// Seconds between non-blocking utterances.
    ///
    /// 60 rather than 300: the right value depends on how much interruption
    /// this particular person tolerates, which cannot be learned from a log of a
    /// silent day. Starting loose and tightening by feel is the only way to find
    /// it, and a too-quiet tool reads as broken rather than as restrained.
    public var speechInterval: TimeInterval

    public var failureWindow: TimeInterval
    public var thrashRepeatThreshold: Int
    public var thrashMinimumDuration: TimeInterval

    /// Whether an answer can actually reach the tool.
    ///
    /// False until both a voice or stem channel exists *and* the wire gate is
    /// open. It governs phrasing only, and it matters: saying "Approve?" with no
    /// microphone and a closed gate invites someone to answer out loud and get
    /// nothing, which is worse than saying less.
    public var canAcceptAnswers: Bool

    /// How many recent decisions the engine keeps in memory.
    ///
    /// The daemon only ever reads the most recent one; the durable record is the
    /// log on disk. This existed unbounded while the process lived for seconds
    /// at a time in tests, and became a slow leak the moment launchd started
    /// keeping it alive for weeks.
    public var recentLogCapacity: Int

    /// How long an unanswered question keeps blocking later ones.
    ///
    /// Only one question is ever in flight, but "in flight" has to expire. With
    /// no answer channel yet nothing ever resolves one, so without a deadline
    /// the very first decision point latches the gate and silently swallows
    /// every one after it — which is exactly what a real log showed.
    public var questionDeadline: TimeInterval

    /// Whether decisions may reach Claude Code at all.
    ///
    /// Off for the observer build. The engine still computes and logs the real
    /// verdict, so the log shows exactly what would have happened — which is how
    /// this gets turned on with evidence rather than optimism.
    public var emitDecisions: Bool

    /// Whether verdicts nobody answered may reach Claude Code.
    ///
    /// Opening the gate means *your answers* get through. Letting the engine
    /// wave reversible, on-route calls past the prompt on its own is a second
    /// decision, and it waits for a log that justifies it. Off, a day with the
    /// gate open changes nothing you did not personally answer.
    public var autoAllow: Bool

    public init(
        speechCapacity: Double = 1,
        speechInterval: TimeInterval = 60,
        failureWindow: TimeInterval = 60,
        thrashRepeatThreshold: Int = 3,
        thrashMinimumDuration: TimeInterval = 180,
        questionDeadline: TimeInterval = 20,
        recentLogCapacity: Int = 500,
        canAcceptAnswers: Bool = false,
        emitDecisions: Bool = false,
        autoAllow: Bool = false
    ) {
        self.autoAllow = autoAllow
        self.speechCapacity = speechCapacity
        self.speechInterval = speechInterval
        self.failureWindow = failureWindow
        self.thrashRepeatThreshold = thrashRepeatThreshold
        self.thrashMinimumDuration = thrashMinimumDuration
        self.questionDeadline = questionDeadline
        self.recentLogCapacity = recentLogCapacity
        self.canAcceptAnswers = canAcceptAnswers
        self.emitDecisions = emitDecisions
    }

    public static let `default` = PolicyConfig()
}
