import Foundation
import Testing
@testable import NavigatorCore
@testable import NavigatorIO

@Suite struct ParkedQuestions {
    @Test func anAnswerReleasesTheWaiter() {
        let question = PendingQuestion(sessionName: "app", text: "force push?")
        let done = DispatchSemaphore(value: 0)
        let got = Box<Answer?>(nil)

        DispatchQueue.global().async {
            got.value = question.wait(timeout: 5)
            done.signal()
        }

        Thread.sleep(forTimeInterval: 0.1)
        #expect(question.answer(.approve))
        #expect(done.wait(timeout: .now() + 3) == .success)
        #expect(got.value == .approve)
    }

    @Test func anUnansweredQuestionTimesOut() {
        // The single most important property here: a question nobody answers
        // must release the agent, not hold it forever.
        let question = PendingQuestion(sessionName: "app", text: "?")
        let start = Date()
        let answer = question.wait(timeout: 0.3)

        #expect(answer == nil)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func answeringTwiceIsIgnoredTheSecondTime() {
        let question = PendingQuestion(sessionName: "app", text: "?")
        DispatchQueue.global().async { _ = question.wait(timeout: 2) }
        Thread.sleep(forTimeInterval: 0.1)

        #expect(question.answer(.approve))
        #expect(!question.answer(.deny), "a second answer must not overwrite the first")
    }

    @Test func theDeskHoldsOnlyOneAtATime() {
        let desk = QuestionDesk()
        let first = PendingQuestion(sessionName: "a", text: "1")
        let second = PendingQuestion(sessionName: "b", text: "2")

        #expect(desk.park(first))
        #expect(!desk.park(second), "a second question must be refused, not queued")
        #expect(desk.current?.text == "1")
    }

    @Test func answeringClearsTheDesk() {
        let desk = QuestionDesk()
        let question = PendingQuestion(sessionName: "a", text: "1")
        DispatchQueue.global().async { _ = question.wait(timeout: 2) }
        _ = desk.park(question)

        #expect(desk.answerCurrent(.approve) == "1")
        desk.clear()
        #expect(desk.current == nil)
        #expect(desk.park(PendingQuestion(sessionName: "b", text: "2")))
    }

    @Test func answeringAnEmptyDeskSaysSo() {
        let desk = QuestionDesk()
        #expect(desk.answerCurrent(.approve) == nil)
    }

    @Test func aLateAnswerIsRefusedOnceTheWaitHasReturned() {
        // The hook has already been told "escalate". An approve landing now
        // would be reported as accepted while the prompt is on screen — or
        // worse, be held for the next question that parks.
        let question = PendingQuestion(sessionName: "app", text: "?")
        #expect(question.wait(timeout: 0.1) == nil)
        #expect(!question.answer(.approve), "answered a question nobody is waiting on")
    }
}
