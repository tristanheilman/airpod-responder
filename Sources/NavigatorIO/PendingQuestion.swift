import Foundation
import NavigatorCore

/// A question the daemon has asked and is holding a hook connection open for.
///
/// The waiting happens on the connection's own thread, which is why this is a
/// semaphore rather than anything async: the thread genuinely must stop until
/// an answer arrives on a different connection or the deadline passes.
public final class PendingQuestion: @unchecked Sendable {
    public let id = UUID()
    public let sessionName: String
    public let text: String

    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var given: Answer?
    private var source: AnswerSource?

    public init(sessionName: String, text: String) {
        self.sessionName = sessionName
        self.text = text
    }

    /// Blocks until answered or the deadline passes. Nil means nobody answered.
    public func wait(timeout: TimeInterval) -> Answer? {
        _ = gate.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        return given
    }

    /// Who answered, once `wait` has returned. Nil when nobody did.
    public var answeredBy: AnswerSource? {
        lock.lock(); defer { lock.unlock() }
        return source
    }

    /// Returns false if it was already answered — first answer wins, so a
    /// duplicate cannot turn an approval into a denial after the fact.
    @discardableResult
    public func answer(_ answer: Answer, from source: AnswerSource = .terminal) -> Bool {
        lock.lock()
        guard given == nil else { lock.unlock(); return false }
        given = answer
        self.source = source
        lock.unlock()
        gate.signal()
        return true
    }
}

/// Holds the one question that is currently outstanding.
public final class QuestionDesk: @unchecked Sendable {
    private let lock = NSLock()
    private var parked: PendingQuestion?

    public init() {}

    public var current: PendingQuestion? {
        lock.lock(); defer { lock.unlock() }
        return parked
    }

    /// Refuses rather than queues. Stalling an agent behind another agent's
    /// unanswered question is worse than showing it a prompt.
    public func park(_ question: PendingQuestion) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard parked == nil else { return false }
        parked = question
        return true
    }

    /// Answers whatever is outstanding. Returns its text, or nil if nothing was.
    @discardableResult
    public func answerCurrent(
        _ answer: Answer, from source: AnswerSource = .terminal
    ) -> String? {
        lock.lock()
        let question = parked
        lock.unlock()

        guard let question, question.answer(answer, from: source) else { return nil }
        return question.text
    }

    public func clear() {
        lock.lock(); parked = nil; lock.unlock()
    }
}
