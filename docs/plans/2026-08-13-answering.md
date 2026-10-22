# Answering Implementation Plan


**Goal:** Make an answer mean something — approve a blocked tool call, and hand new instructions to a running agent — proved with typed commands, so voice plugs into a path already known to work.

**Architecture:** A decision point stops replying instantly and instead *parks*: the daemon speaks, holds the hook's connection open, and waits for an answer arriving on a different connection. Answers come from `navigator approve` / `deny` / `tell` today and from a microphone later, on whichever device has the AirPods. Everything that can reach Claude Code sits behind one switch, off by default, so the whole thing can be built and tested without ever changing what your sessions do.

**Tech Stack:** Swift 6, existing `NavigatorCore` / `NavigatorIO` / `NavigatorAudio`, Swift Testing.

## Why this shape

The previous build was an observer: it narrated and could not act. The stated goal is hands-free coding — the tool takes over so the keyboard is optional. That needs three things Claude Code already supports:

- **`PreToolUse`** returns `allow` / `deny`. Fires on every call.
- **`PermissionRequest`** returns `allow` / `deny` / `escalate`, and fires only when a decision is genuinely needed. `escalate` is an explicit "show the dialog" — better than deferring by silence.
- **`Stop`** returns `decision: "block"` with a reason, which feeds text back into a running conversation. This is the mechanism for *giving instructions*, and it is the part that makes "takes over" true rather than aspirational.

Voice is deliberately **not** in this plan. It is device-specific — Mac microphone or iPhone — and building one throws away the other. Everything here is shared by both.

## The inversion

The daemon plan made "respond immediately, never sit on the critical path" a hard rule. That was right for the 95% of events that are silent and stays right for them.

A decision point now deliberately does the opposite: it stalls the agent while you decide. That is what makes the answer worth anything — an approval that arrives after the command ran is not an approval.

Consequences, each of which is a task below:

- The hook's read deadline goes from 250ms to ~25s. This costs the silent majority **nothing**: the deadline is a maximum, and the daemon still answers those in under a millisecond.
- Claude Code's own hook `timeout` must exceed that. The installed config says 5 seconds and would kill the connection mid-question.
- A wedged daemon can now stall a tool call for ~25s instead of 5. Both sides enforce their own deadline so this is bounded rather than open-ended, but it is a real cost and the reason the daemon's deadline is deliberately shorter than the hook's.

## Global Constraints

- **One switch governs everything that can reach Claude Code.** `emitDecisions` currently gates `PreToolUse` output; it now gates permission answers, escalations and `Stop` injection too. Off by default. Every task is built and tested with it off, and the exhaustive "nothing reaches the wire" property is extended to cover the new paths.
- **The hook still cannot block a tool call by failing.** It exits 0 on every path, including a daemon that dies while holding its connection open. Being made to wait must not create a way to exit non-zero.
- **Every parked question must release.** The daemon enforces a deadline, the hook enforces a shorter-than-Claude-Code one, and Claude Code's `timeout` is the third backstop. A question nobody answers resolves to `escalate` — the on-screen prompt — never to `allow`.
- **The blast-radius invariant is unchanged.** Auto-allow only for reversible and on-route; never auto-deny. An *answered* `deny` is a different thing from the engine auto-denying, and only the former is possible.
- **Only one question is parked at a time.** A second decision point while one is live returns `escalate` immediately rather than queueing behind it.
- Tests stay silent: every one runs against `RecordingSpeaker`.
- `#expect`/`#require` cannot contain `mutating` or `throws` calls — hoist into a `let`.

---

### Task 1: One switch for everything outbound

**Files:**
- Modify: `Sources/NavigatorCore/Policy/PolicyConfig.swift`
- Modify: `Sources/NavigatorCore/Events/HookOutput.swift`
- Test: `Tests/NavigatorCoreTests/HookOutputTests.swift`

**Interfaces:**
- Produces: `HookOutput.encode(_:for:emitDecisions:)` extended to `PermissionRequest` and `Stop`; `HookOutput.escalation(for:reason:)`; `HookOutput.instruction(_:)`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/NavigatorCoreTests/HookOutputTests.swift`:

```swift
@Suite struct WireGateCoversEveryOutboundPath {
    /// The gate was checked exhaustively when PreToolUse was the only way out.
    /// Three new ones are being added; the guarantee has to grow with them.
    @Test func closedGateBlocksEscalation() throws {
        #expect(try HookOutput.escalation(
            for: .permissionRequest, reason: "r", emitDecisions: false) == nil)
    }

    @Test func closedGateBlocksInstructions() throws {
        #expect(try HookOutput.instruction(
            "add tests", for: .stop, emitDecisions: false) == nil)
    }

    @Test func openGateEmitsEscalation() throws {
        let out = try #require(try HookOutput.escalation(
            for: .permissionRequest, reason: "force push", emitDecisions: true))
        let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        let specific = try #require(parsed?["hookSpecificOutput"] as? [String: Any])

        #expect(specific["hookEventName"] as? String == "PermissionRequest")
        #expect(specific["decision"] as? String == "escalate")
    }

    @Test func openGateEmitsAnInstruction() throws {
        let out = try #require(try HookOutput.instruction(
            "add tests for the parser", for: .stop, emitDecisions: true))
        let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]

        // Stop uses a top-level decision, not hookSpecificOutput.
        #expect(parsed?["decision"] as? String == "block")
        #expect((parsed?["reason"] as? String)?.contains("add tests") == true)
    }

    @Test func permissionRequestUsesDecisionNotPermissionDecision() throws {
        // PreToolUse spells it `permissionDecision`; PermissionRequest spells it
        // `decision`. Getting this wrong fails silently — the hook returns
        // valid JSON that Claude Code ignores.
        let allow = Decision(tier: .silent, permission: .allow,
                             utterance: nil, reason: "ok", blocking: false)
        let out = try #require(try HookOutput.encode(
            allow, for: .permissionRequest, emitDecisions: true))
        let parsed = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        let specific = try #require(parsed?["hookSpecificOutput"] as? [String: Any])

        #expect(specific["decision"] as? String == "allow")
        #expect(specific["permissionDecision"] == nil)
    }

    @Test func everyNewPathIsShutWithTheGateClosed() throws {
        for kind in HookEventKind.allCases {
            for permission: PermissionDecision? in [nil, .allow, .defer, .deny] {
                let decision = Decision(
                    tier: .decisionPoint, permission: permission,
                    utterance: "x", reason: "r", blocking: true)
                #expect(try HookOutput.encode(
                    decision, for: kind, emitDecisions: false) == nil)
            }
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WireGateCoversEveryOutboundPath`
Expected: FAIL — `type 'HookOutput' has no member 'escalation'`

- [ ] **Step 3: Add the event kind**

In `Sources/NavigatorCore/Events/HookEvent.swift`, add to `HookEventKind`:

```swift
    case permissionRequest = "PermissionRequest"
```

- [ ] **Step 4: Extend the encoder**

In `Sources/NavigatorCore/Events/HookOutput.swift`, add alongside the existing types:

```swift
    private struct PermissionRequestOutput: Encodable {
        let hookEventName = "PermissionRequest"
        let decision: String
        let reason: String
    }

    private struct PermissionEnvelope: Encodable {
        let hookSpecificOutput: PermissionRequestOutput
    }

    /// `Stop` takes a top-level decision rather than a hookSpecificOutput.
    private struct StopBlock: Encodable {
        let decision = "block"
        let reason: String
    }
```

Extend `encode` so `PermissionRequest` renders `decision` rather than
`permissionDecision` — the two events spell it differently, and using the wrong
key produces valid JSON that Claude Code silently ignores. Then add:

```swift
    /// Hand the decision back to the on-screen prompt, explicitly.
    ///
    /// `PermissionRequest` has a real word for this where `PreToolUse` only has
    /// silence. Saying it outright is better than being absent and hoping.
    public static func escalation(
        for kind: HookEventKind, reason: String, emitDecisions: Bool
    ) throws -> String? {
        guard emitDecisions, kind == .permissionRequest else { return nil }
        return try line(PermissionEnvelope(
            hookSpecificOutput: PermissionRequestOutput(
                decision: "escalate", reason: reason)))
    }

    /// Feed spoken direction back into a running conversation.
    ///
    /// This is the mechanism that makes "takes over" true: `Stop` returning
    /// `decision: "block"` puts the reason in front of the agent and keeps it
    /// working, rather than ending the turn.
    public static func instruction(
        _ text: String, for kind: HookEventKind, emitDecisions: Bool
    ) throws -> String? {
        guard emitDecisions, kind == .stop, !text.isEmpty else { return nil }
        return try line(StopBlock(reason: text))
    }

    private static func line<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test`
Expected: PASS — every suite. `TierAssigner` needs a case for `.permissionRequest`; treat it exactly as `.preToolUse`.

- [ ] **Step 6: Commit**

```bash
git add Sources/NavigatorCore Tests/NavigatorCoreTests/HookOutputTests.swift
git commit -m "feat: one gate over every outbound path"
```

---

### Task 2: Parked questions

**Files:**
- Create: `Sources/NavigatorIO/PendingQuestion.swift`
- Test: `Tests/NavigatorIOTests/PendingQuestionTests.swift`

**Interfaces:**
- Produces: `Answer` (`.approve`, `.deny`, `.escalate`); `PendingQuestion` with `init(id:sessionName:text:)`, `func wait(timeout:) -> Answer?`, `func answer(_:) -> Bool`; `QuestionDesk` with `park(_:) -> Bool`, `answerCurrent(_:) -> String?`, `var current: PendingQuestion?`, `func clear()`.

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorIOTests/PendingQuestionTests.swift`:

```swift
import Foundation
import Testing
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ParkedQuestions`
Expected: FAIL — `cannot find 'PendingQuestion' in scope`

- [ ] **Step 3: Write it**

Create `Sources/NavigatorIO/PendingQuestion.swift`:

```swift
import Foundation

public enum Answer: String, Sendable, Equatable {
    case approve
    case deny
    /// Hand it back to the on-screen prompt.
    case escalate
}

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

    /// Returns false if it was already answered — first answer wins, so a
    /// duplicate cannot turn an approval into a denial after the fact.
    @discardableResult
    public func answer(_ answer: Answer) -> Bool {
        lock.lock()
        guard given == nil else { lock.unlock(); return false }
        given = answer
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
    public func answerCurrent(_ answer: Answer) -> String? {
        lock.lock()
        let question = parked
        lock.unlock()

        guard let question, question.answer(answer) else { return nil }
        return question.text
    }

    public func clear() {
        lock.lock(); parked = nil; lock.unlock()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ParkedQuestions`
Expected: PASS — 6 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/NavigatorIO/PendingQuestion.swift Tests/NavigatorIOTests/PendingQuestionTests.swift
git commit -m "feat: park a question and wait for an answer"
```

---

### Task 3: The daemon holds the line

**Files:**
- Modify: `Sources/NavigatorIO/NavigatorServer.swift`
- Test: `Tests/NavigatorIOTests/AnsweringTests.swift`

**Interfaces:**
- Consumes: `QuestionDesk`, `Answer`, `HookOutput`.
- Produces: `NavigatorServer` parks blocking decisions and waits; `NavigatorCommand` gains `.approve`, `.deny`, `.escalate`, `.tell`.

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorIOTests/AnsweringTests.swift`:

```swift
import Foundation
import Testing
@testable import NavigatorAudio
@testable import NavigatorCore
@testable import NavigatorIO

@Suite(.serialized) struct Answering {
    private func tempPath() -> String {
        "/tmp/navans-\(UInt32.random(in: 0..<UInt32.max)).sock"
    }

    private func makeServer(_ path: String, open: Bool) throws -> NavigatorServer {
        var config = PolicyConfig.default
        config.emitDecisions = open
        config.canAcceptAnswers = open
        config.answerDeadline = 3
        let server = NavigatorServer(
            socketPath: path, log: nil, config: config,
            speaker: RecordingSpeaker(), microphoneIsBusy: { false },
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

    private func force(at: Date) -> NavigatorRequest {
        NavigatorRequest(
            event: HookEvent(
                kind: .preToolUse, sessionID: "s1", cwd: "/p", toolName: "Bash",
                toolInput: ["command": .string("git push --force")]),
            at: at)
    }

    @Test func anApprovedQuestionReturnsAllow() throws {
        let path = tempPath()
        let server = try makeServer(path, open: true)
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
        #expect(reply.value??.output?.contains("allow") == true)
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
        #expect(reply.value??.output?.contains("deny") == true)
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

    @Test func aSecondQuestionIsRefusedNotQueued() throws {
        let path = tempPath()
        let server = try makeServer(path, open: true)
        defer { server.stop() }

        DispatchQueue.global().async { _ = try? self.send(path, self.force(at: Date())) }
        Thread.sleep(forTimeInterval: 0.4)

        let start = Date()
        _ = try send(path, force(at: Date()))
        #expect(Date().timeIntervalSince(start) < 1, "the second one queued behind the first")
    }

    @Test func answeringNothingIsGraceful() throws {
        let path = tempPath()
        let server = try makeServer(path, open: true)
        defer { server.stop() }

        let response = try send(path, .control(.approve, at: Date()))
        #expect(response.message?.isEmpty == false)
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter Answering`
Expected: FAIL — `extra argument 'answerDeadline' in call`

- [ ] **Step 3: Add the deadline and the parking path**

Add `answerDeadline: TimeInterval = 20` to `PolicyConfig` with the usual
initialiser plumbing, documented as: *how long a decision point holds the agent
while waiting for you.*

In `NavigatorServer`, add `private let desk = QuestionDesk()` and, in
`handleOnce`, replace the immediate reply for blocking decisions:

```swift
        // A decision point stops the agent on purpose — an approval that
        // arrives after the command ran is not an approval. Everything else
        // still answers in under a millisecond.
        if decision.blocking, config.canAcceptAnswers,
           let utterance = decision.utterance {
            let question = PendingQuestion(sessionName: sessionName, text: utterance)

            guard desk.park(question) else {
                // Refused rather than queued: stalling behind another agent's
                // unanswered question is worse than showing a prompt.
                reply(on: connection, NavigatorResponse(
                    output: try? HookOutput.escalation(
                        for: stamped.event.kind, reason: "another question is live",
                        emitDecisions: config.emitDecisions)))
                return
            }

            audio.async { [self] in speaker.say(utterance) }

            let answer = question.wait(timeout: config.answerDeadline)
            desk.clear()

            lock.lock(); engine.resolveQuestion(); lock.unlock()

            reply(on: connection, NavigatorResponse(
                output: encode(answer, for: stamped.event.kind, decision: decision)))
            return
        }
```

and a helper that turns an answer into wire output, where **nil means nobody
answered** and must never become `allow`:

```swift
    private func encode(
        _ answer: Answer?, for kind: HookEventKind, decision: Decision
    ) -> String? {
        switch answer {
        case .approve:
            return try? HookOutput.encode(
                Decision(tier: decision.tier, permission: .allow,
                         utterance: nil, reason: decision.reason, blocking: false),
                for: kind, emitDecisions: config.emitDecisions)
        case .deny:
            return try? HookOutput.encode(
                Decision(tier: decision.tier, permission: .deny,
                         utterance: nil, reason: decision.reason, blocking: false),
                for: kind, emitDecisions: config.emitDecisions) ?? nil
        case .escalate, nil:
            // Silence on PreToolUse *is* the escalation. On PermissionRequest
            // there is a word for it, so use the word.
            return try? HookOutput.escalation(
                for: kind, reason: decision.reason,
                emitDecisions: config.emitDecisions) ?? nil
        }
    }
```

`stop()` must release anything parked before draining, so a shutdown mid-question
does not abandon a waiting hook:

```swift
        desk.answerCurrent(.escalate)
        desk.clear()
```

Add `.approve`, `.deny`, `.escalate` to `NavigatorCommand` and handle them by
calling `desk.answerCurrent(...)`, reporting what was answered or that nothing
was outstanding.

**Note on `deny`:** `HookOutput.encode` throws on `.deny` — that guard exists
because the *engine* must never auto-deny. An answered denial is a different
thing entirely, so the encoder needs a path that permits it only when it came
from a person. Add `HookOutput.answeredDenial(for:reason:emitDecisions:)` rather
than weakening the existing guard.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter Answering`
Expected: PASS — 7 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/NavigatorIO Sources/NavigatorCore Tests/NavigatorIOTests/AnsweringTests.swift
git commit -m "feat: hold the agent while waiting for an answer"
```

---

### Task 4: Instructions

**Files:**
- Modify: `Sources/NavigatorIO/NavigatorServer.swift`
- Test: `Tests/NavigatorIOTests/InstructionTests.swift`

**Interfaces:**
- Produces: `NavigatorCommand.tell`; a per-session pending-instruction queue delivered on the next `Stop`.

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorIOTests/InstructionTests.swift`:

```swift
import Foundation
import Testing
@testable import NavigatorAudio
@testable import NavigatorCore
@testable import NavigatorIO

@Suite(.serialized) struct Instructions {
    // Same helpers as Answering: tempPath, makeServer, send.

    @Test func somethingToldIsDeliveredOnTheNextStop() throws {
        // The mechanism that makes "takes over" real: Stop returns
        // decision:block with your words, and the agent keeps working on them.
        let path = tempPath()
        let server = try makeServer(path, open: true)
        defer { server.stop() }

        _ = try send(path, .control(.tell, argument: "add tests for the parser", at: Date()))

        let stop = try send(path, NavigatorRequest(
            event: HookEvent(kind: .stop, sessionID: "s1", cwd: "/p"), at: Date()))

        #expect(stop.output?.contains("block") == true)
        #expect(stop.output?.contains("add tests for the parser") == true)
    }

    @Test func anInstructionIsDeliveredOnlyOnce() throws {
        let path = tempPath()
        let server = try makeServer(path, open: true)
        defer { server.stop() }

        _ = try send(path, .control(.tell, argument: "do the thing", at: Date()))
        _ = try send(path, NavigatorRequest(
            event: HookEvent(kind: .stop, sessionID: "s1", cwd: "/p"), at: Date()))

        let second = try send(path, NavigatorRequest(
            event: HookEvent(kind: .stop, sessionID: "s1", cwd: "/p"), at: Date()))
        #expect(second.output == nil, "the same instruction was delivered twice")
    }

    @Test func aStopWithNothingPendingIsUntouched() throws {
        let path = tempPath()
        let server = try makeServer(path, open: true)
        defer { server.stop() }

        let stop = try send(path, NavigatorRequest(
            event: HookEvent(kind: .stop, sessionID: "s1", cwd: "/p"), at: Date()))
        #expect(stop.output == nil)
    }

    @Test func nothingIsDeliveredWhileTheGateIsShut() throws {
        let path = tempPath()
        let server = try makeServer(path, open: false)
        defer { server.stop() }

        _ = try send(path, .control(.tell, argument: "do the thing", at: Date()))
        let stop = try send(path, NavigatorRequest(
            event: HookEvent(kind: .stop, sessionID: "s1", cwd: "/p"), at: Date()))

        #expect(stop.output == nil, "the gate leaked an instruction")
    }

    @Test func tellingWithNoSessionsSaysSo() throws {
        let path = tempPath()
        let server = try makeServer(path, open: true)
        defer { server.stop() }

        let response = try send(path, .control(.tell, argument: "hello", at: Date()))
        #expect(response.message?.isEmpty == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter Instructions`
Expected: FAIL — `.tell` does not exist

- [ ] **Step 3: Implement**

Add `.tell` to `NavigatorCommand`. In `NavigatorServer`, hold
`private var pendingInstruction: String?` under the existing lock. `.tell` sets
it; a `Stop` event consumes it:

```swift
        if stamped.event.kind == .stop, config.emitDecisions {
            lock.lock()
            let instruction = pendingInstruction
            pendingInstruction = nil
            lock.unlock()

            if let instruction {
                reply(on: connection, NavigatorResponse(
                    output: try? HookOutput.instruction(
                        instruction, for: .stop, emitDecisions: config.emitDecisions)))
                return
            }
        }
```

Cleared on read, because an instruction delivered twice is an agent told to do
the same thing twice.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter Instructions`
Expected: PASS — 5 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/NavigatorIO Tests/NavigatorIOTests/InstructionTests.swift
git commit -m "feat: hand spoken direction to a running agent"
```

---

### Task 5: Terminal commands and the longer deadline

**Files:**
- Modify: `Sources/navigator/main.swift`
- Modify: `Sources/navigator-hook/main.swift`
- Modify: `Sources/NavigatorIO/HookInstaller.swift`
- Test: `Tests/NavigatorIOTests/HookInstallerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
    @Test func theHookTimeoutExceedsTheAnswerDeadline() throws {
        // Claude Code kills a hook at its own timeout. Installed at 5s it would
        // cut every question off a quarter of the way through.
        let config = HookInstaller.configuration(hookPath: "/x/h", timeoutSeconds: 30)
        let hooks = try #require(config["hooks"] as? [String: Any])
        let entries = try #require(
            (hooks["PreToolUse"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])

        #expect((entries.first?["timeout"] as? Int ?? 0) > 25)
    }
```

- [ ] **Step 2: Raise the deadlines**

The hook's read deadline becomes 25s (`NAVIGATOR_DEADLINE_MS` default 25000).
This costs the silent majority nothing: the deadline is a maximum and the daemon
still answers those in under a millisecond.

Installed `timeout` becomes 30. The ordering matters and should be commented
where it is set: **daemon 20 < hook 25 < Claude Code 30**. Each is a backstop for
the one before, so a failure at any level still releases the agent.

Add commands: `navigator approve`, `deny`, `escalate`, `tell <text>`.

- [ ] **Step 3: Verify by hand**

```bash
navigator config --write     # set emitDecisions manually — see Task 6
navigator service restart
```

In one terminal, run something that trips a decision point. In another:

```bash
navigator approve
```

Expected: the first terminal's command proceeds, and the daemon speaks the
question before waiting.

- [ ] **Step 4: Commit**

---

### Task 6: Opening the gate, deliberately

**Files:**
- Modify: `Sources/NavigatorIO/ConfigFile.swift`
- Modify: `Sources/navigator/main.swift`
- Test: `Tests/NavigatorIOTests/ConfigFileTests.swift`

`emitDecisions` is currently unreadable from the config file on purpose. That was
right for a build that could never act. Now it is the switch, and it needs a
deliberate way to flip that is harder than editing a number.

- [ ] **Step 1: Write the failing test**

```swift
    @Test func theGateStillCannotBeOpenedByAStrayConfigFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"emitDecisions": true}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(ConfigFile.load(from: url).emitDecisions == false)
    }

    @Test func itOpensOnlyWithTheExplicitAcknowledgement() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"iUnderstandThisWillActOnMyBehalf": true}"#
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(ConfigFile.load(from: url).emitDecisions == true)
    }
```

- [ ] **Step 2: Implement**

A single key, named so it cannot be set by accident or by copying an example.
`navigator gate --open` writes it after printing exactly what changes; `navigator
gate --close` removes it; `navigator gate` reports the current state.

The daemon's startup banner must say plainly which mode it is in — the difference
between narrating and acting should never be something you have to infer.

- [ ] **Step 3: Commit**

---

### Task 7: End to end, with the gate open

**Files:**
- Test: `Tests/NavigatorIOTests/EndToEndTests.swift`

- [ ] **Step 1: Add the test**

A full loop against a real socket and the real hook binary: fire a force push,
confirm the hook is still waiting after a second, answer `approve` from another
connection, confirm the hook prints an `allow` and exits 0.

Then the same with no answer: confirm it exits 0, prints no allow, and takes
roughly the answer deadline.

- [ ] **Step 2: Confirm the hook still cannot block a tool call**

Extend `HookBinaryContract`: with the daemon parked and then killed mid-question,
the hook must still exit 0. Being made to wait must not create a path to a
non-zero exit.

- [ ] **Step 3: Commit**

---

## Known Gaps

- **No voice.** Every answer is typed. This plan exists so voice has a proven path to plug into, on whichever device holds the AirPods.
- **No iOS app.** The `Speaker` protocol is where a remote one goes; nothing here forecloses it.
- **One question at a time.** A second is escalated, not queued. Revisit only if that turns out to be common in real use.
- **Instructions are global, not per-session.** `tell` hands text to whichever session stops next. Per-session addressing needs a way to say *which* session out loud, which is a voice problem.
- **A wedged daemon now costs ~25s** instead of 5. Bounded by three independent deadlines, but real.

## Verification

```bash
swift build && swift test
```

Every suite green, including the extended gate property: with the gate shut,
**no decision, escalation or instruction reaches Claude Code**, checked over every
event kind and every permission value. That guarantee is what makes it safe to
build all of this before deciding to turn it on.
