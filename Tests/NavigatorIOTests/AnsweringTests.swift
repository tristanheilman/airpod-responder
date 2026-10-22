import Foundation
import Testing
@testable import NavigatorAudio
@testable import NavigatorCore
@testable import NavigatorIO

@Suite(.serialized) struct Answering {
    private func tempPath() -> String {
        "/tmp/navans-\(UInt32.random(in: 0..<UInt32.max)).sock"
    }

    private func makeServer(
        _ path: String, open: Bool, autoAllow: Bool = false,
        onACall: Bool = false, speaker: RecordingSpeaker = RecordingSpeaker()
    ) throws -> NavigatorServer {
        var config = PolicyConfig.default
        config.emitDecisions = open
        config.canAcceptAnswers = open
        config.autoAllow = autoAllow
        config.questionDeadline = 3
        let server = NavigatorServer(
            socketPath: path, log: nil, config: config,
            speaker: speaker, microphoneIsBusy: { onACall },
            startingAt: Date(timeIntervalSince1970: 1_770_000_000))
        try server.start()
        return server
    }

    private func send(_ path: String, _ request: NavigatorRequest) throws -> NavigatorResponse {
        let client = try UnixSocket.connect(to: path, timeout: 10)
        defer { client.close() }
        try client.write(try NavigatorMessage.encodeLine(request))
        return try NavigatorMessage.decode(
            try client.readLine(deadline: 30), as: NavigatorResponse.self)
    }

    private func force(at: Date, kind: HookEventKind = .permissionRequest) -> NavigatorRequest {
        NavigatorRequest(
            event: HookEvent(
                kind: kind, sessionID: "s1", cwd: "/p", toolName: "Bash",
                toolInput: ["command": .string("git push --force")]),
            at: at)
    }

    @Test func anApprovedQuestionReturnsAllow() throws {
        let path = tempPath()
        let speaker = RecordingSpeaker()
        let server = try makeServer(path, open: true, speaker: speaker)
        defer { server.stop() }

        let reply = Box<NavigatorResponse?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            reply.value = try? self.send(path, self.force(at: Date()))
            done.signal()
        }

        // Give it a moment to park, then answer from another connection.
        Thread.sleep(forTimeInterval: 0.4)
        _ = try send(path, .control(.approve, at: Date()))

        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(reply.value?.output?.contains("allow") == true)
        // It asked before it waited — a question you never heard is a stall.
        // And it asked once: hearing "Approve?" again after approving invites
        // a second approve, which could land on the next question.
        #expect(speaker.spoken.filter { $0.contains("Approve?") }.count == 1)
    }

    @Test func theRealEventOrderParksOnPermissionRequest() throws {
        // Claude Code fires PreToolUse and then PermissionRequest for the same
        // call, milliseconds apart. Every other test here sends the second
        // alone; this is the order a real session produces, and the first
        // version of this branch never parked in it — PreToolUse took the
        // in-flight slot and the real question was suppressed as a duplicate.
        let path = tempPath()
        let speaker = RecordingSpeaker()
        let server = try makeServer(path, open: true, speaker: speaker)
        defer { server.stop() }

        let first = try send(path, force(at: Date(), kind: .preToolUse))
        #expect(first.output == nil)

        let reply = Box<NavigatorResponse?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            reply.value = try? self.send(path, self.force(at: Date()))
            done.signal()
        }
        Thread.sleep(forTimeInterval: 0.6)
        _ = try send(path, .control(.approve, at: Date()))

        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(reply.value?.output?.contains("allow") == true, "the real order did not park")

        // One sentence, the question. Not a heads-up and then a question.
        Thread.sleep(forTimeInterval: 0.2)
        let aboutIt = speaker.spoken.filter { $0.contains("force push") }
        #expect(aboutIt.count == 1, "spoken: \(speaker.spoken)")
        #expect(aboutIt.first?.contains("Approve?") == true)
    }

    @Test func aHeadsUpStillSpeaksWhenNoQuestionFollows() throws {
        // In auto mode nothing needs permission, so PermissionRequest never
        // fires. The PreToolUse heads-up is then the only warning you get
        // about a force push, and it must not be lost to the de-duplication.
        let path = tempPath()
        let speaker = RecordingSpeaker()
        let server = try makeServer(path, open: true, speaker: speaker)
        defer { server.stop() }

        _ = try send(path, force(at: Date(), kind: .preToolUse))
        Thread.sleep(forTimeInterval: 1.0)

        #expect(speaker.spoken.contains { $0.contains("about to force push") },
                "spoken: \(speaker.spoken)")
    }

    @Test func anUnansweredQuestionReleasesTheAgent() throws {
        // The property that matters most: nobody answers, the agent still moves.
        let path = tempPath()
        let server = try makeServer(path, open: true)
        defer { server.stop() }

        let start = Date()
        let response = try send(path, force(at: Date()))
        let waited = Date().timeIntervalSince(start)

        #expect(waited >= 2.5, "did not actually wait: \(waited)s")
        #expect(waited < 8, "waited too long: \(waited)s")
        #expect(response.output?.contains("allow") != true, "an unanswered question allowed it")
        // Silence is the escalation: nothing printed, the prompt appears.
        #expect(response.output == nil)
    }

    @Test func aDenialIsAnAnswerNotAnAutoDeny() throws {
        let path = tempPath()
        let server = try makeServer(path, open: true)
        defer { server.stop() }

        let reply = Box<NavigatorResponse?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            reply.value = try? self.send(path, self.force(at: Date()))
            done.signal()
        }
        Thread.sleep(forTimeInterval: 0.4)
        _ = try send(path, .control(.deny, at: Date()))

        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(reply.value?.output?.contains("deny") == true)
    }

    @Test func nothingParksWhileTheGateIsShut() throws {
        // With the gate closed the tool cannot act, so holding the agent would
        // be a stall with no possible payoff.
        let path = tempPath()
        let server = try makeServer(path, open: false)
        defer { server.stop() }

        let start = Date()
        let response = try send(path, force(at: Date()))

        #expect(Date().timeIntervalSince(start) < 1, "parked with nothing to gain")
        #expect(response.output == nil)
    }

    @Test func preToolUseNeverParks() throws {
        // PreToolUse fires for the same call just before PermissionRequest.
        // Parking both would ask the same question twice; and a timed-out
        // PreToolUse can only fall silent, where PermissionRequest can say
        // say nothing — same thing. The question lives on PermissionRequest
        // alone because it is the event that fires only when a decision is
        // genuinely needed.
        let path = tempPath()
        let server = try makeServer(path, open: true)
        defer { server.stop() }

        let start = Date()
        let response = try send(path, force(at: Date(), kind: .preToolUse))

        #expect(Date().timeIntervalSince(start) < 1, "PreToolUse parked")
        #expect(response.output == nil)
    }

    @Test func aReversibleCallIsNotAutoAllowedByOpeningTheGate() throws {
        // Opening the gate means "answers reach Claude Code". Auto-allowing
        // the quiet majority is a separate decision with its own switch, so a
        // first day with the gate open changes nothing you did not answer.
        let path = tempPath()
        let server = try makeServer(path, open: true)
        defer { server.stop() }

        let build = NavigatorRequest(
            event: HookEvent(
                kind: .preToolUse, sessionID: "s1", cwd: "/p", toolName: "Bash",
                toolInput: ["command": .string("swift build")]),
            at: Date())
        #expect(try send(path, build).output == nil)
    }

    @Test func autoAllowIsItsOwnSwitch() throws {
        let path = tempPath()
        let server = try makeServer(path, open: true, autoAllow: true)
        defer { server.stop() }

        let build = NavigatorRequest(
            event: HookEvent(
                kind: .preToolUse, sessionID: "s1", cwd: "/p", toolName: "Bash",
                toolInput: ["command": .string("swift build")]),
            at: Date())
        #expect(try send(path, build).output?.contains("allow") == true)
    }

    @Test func aQuestionDuringACallEscalatesImmediately() throws {
        // On a call the question is not spoken. Holding the agent for twenty
        // seconds behind a question you cannot hear is a stall, not a question.
        let path = tempPath()
        let server = try makeServer(path, open: true, onACall: true)
        defer { server.stop() }

        let start = Date()
        let response = try send(path, force(at: Date()))

        #expect(Date().timeIntervalSince(start) < 1, "parked during a call")
        #expect(response.output == nil)
    }

    @Test func aSecondQuestionIsRefusedNotQueued() throws {
        let path = tempPath()
        let server = try makeServer(path, open: true)
        defer { server.stop() }

        DispatchQueue.global().async { _ = try? self.send(path, self.force(at: Date())) }
        Thread.sleep(forTimeInterval: 0.4)

        let start = Date()
        let second = try send(path, force(at: Date()))
        #expect(Date().timeIntervalSince(start) < 1, "the second one queued behind the first")
        #expect(second.output == nil)
    }

    @Test func answeringNothingIsGraceful() throws {
        let path = tempPath()
        let server = try makeServer(path, open: true)
        defer { server.stop() }

        let response = try send(path, .control(.approve, at: Date()))
        #expect(response.message?.isEmpty == false)
        #expect(response.output == nil)
    }

    @Test func stoppingReleasesAParkedQuestion() throws {
        // A daemon shut down mid-question must not leave a hook waiting for a
        // reply that will never come.
        let path = tempPath()
        let server = try makeServer(path, open: true)

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? self.send(path, self.force(at: Date()))
            done.signal()
        }
        Thread.sleep(forTimeInterval: 0.4)
        server.stop()

        #expect(done.wait(timeout: .now() + 8) == .success, "the hook was abandoned")
    }

    @Test func aShutdownReleaseIsLoggedAsNobodyAnswering() throws {
        // The log exists to count how often nobody answered. A release at
        // shutdown is not the terminal answering, and the record of it must
        // reach the log rather than be dropped behind the drain.
        let path = tempPath()
        let server = try makeServer(path, open: true)

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? self.send(path, self.force(at: Date()))
            done.signal()
        }
        Thread.sleep(forTimeInterval: 0.4)
        server.stop()
        #expect(done.wait(timeout: .now() + 8) == .success)

        let record = try #require(server.lastRecord)
        #expect(record.answer == .escalate)
        #expect(record.answerSource == nil)
    }

    @Test func aRefusedQuestionDoesNotPoisonTheNextOne() throws {
        // Mic busy: not parked, answered at once. The engine must not go on
        // believing a question is in flight for the next twenty seconds.
        let path = tempPath()
        let server = try makeServer(path, open: true, onACall: true)
        defer { server.stop() }

        _ = try send(path, force(at: Date()))
        _ = try send(path, force(at: Date()))
        let record = try #require(server.lastRecord)
        #expect(!record.reason.contains("in flight"), "reason: \(record.reason)")
    }

    @Test func theAnswerAndItsSourceAreLogged() throws {
        // The number that matters later is how often a nod answered versus how
        // often nobody did. That only exists if the record says who answered.
        let path = tempPath()
        let server = try makeServer(path, open: true)
        defer { server.stop() }

        DispatchQueue.global().async { _ = try? self.send(path, self.force(at: Date())) }
        Thread.sleep(forTimeInterval: 0.4)
        _ = try send(path, .control(.approve, at: Date()))
        Thread.sleep(forTimeInterval: 0.2)

        let record = try #require(server.lastRecord)
        #expect(record.answer == .approve)
        #expect(record.answerSource == .terminal)
    }
}
