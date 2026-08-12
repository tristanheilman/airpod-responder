import Foundation

/// A short non-verbal sound.
///
/// Three, not more: an earcon vocabulary you have to remember is a vocabulary
/// you will not remember.
public enum Earcon: String, Sendable, Equatable, CaseIterable {
    /// Something happened outside the session's project.
    case offRoute
    /// Something failed.
    case failure
    /// A command was heard and acted on.
    case acknowledged
}

public protocol Speaker: Sendable {
    func say(_ text: String)
    func play(_ earcon: Earcon)
    /// Abandon anything queued — used when you ask it to be quiet.
    func stop()
}

/// The test double. Every test in this package uses it, because a suite that
/// makes noise cannot be run while wearing the thing it tests.
public final class RecordingSpeaker: Speaker, @unchecked Sendable {
    private let lock = NSLock()
    private var _spoken: [String] = []
    private var _played: [Earcon] = []
    private var _stopCount = 0

    public init() {}

    public var spoken: [String] { lock.lock(); defer { lock.unlock() }; return _spoken }
    public var played: [Earcon] { lock.lock(); defer { lock.unlock() }; return _played }
    public var stopCount: Int { lock.lock(); defer { lock.unlock() }; return _stopCount }

    public func say(_ text: String) {
        lock.lock(); _spoken.append(text); lock.unlock()
    }

    public func play(_ earcon: Earcon) {
        lock.lock(); _played.append(earcon); lock.unlock()
    }

    public func stop() {
        lock.lock(); _stopCount += 1; lock.unlock()
    }
}

/// Discards everything. Used when the microphone is busy: the decision still
/// reaches the transcript, so catch-up can tell you what happened during a call.
public struct SilentSpeaker: Speaker {
    public init() {}
    public func say(_ text: String) {}
    public func play(_ earcon: Earcon) {}
    public func stop() {}
}
