import Darwin
import Foundation
import NavigatorAudio
import NavigatorCore

/// Accepts hook connections, decides, replies, then speaks and logs.
///
/// Threading is deliberately old-fashioned: a dedicated thread blocks in
/// `accept`, each connection is handled on a concurrent queue, and the engine
/// sits behind a lock. Structured concurrency would mean parking a blocking
/// `accept` inside a cooperative thread pool, which starves it — this is the
/// one place where a raw thread is the simpler correct answer.
public final class NavigatorServer: @unchecked Sendable {
    private let socketPath: String
    private let log: DecisionLog?
    private let config: PolicyConfig
    private let speaker: any Speaker
    private let announcer: Announcer
    /// Used when the microphone is busy: the decision still reaches the
    /// transcript, so catch-up can tell you what happened during a call.
    private let silentAnnouncer = Announcer(speaker: SilentSpeaker())
    /// Injectable so the busy-microphone path can be tested without a call.
    private let microphoneIsBusy: @Sendable () -> Bool

    private let lock = NSLock()
    private var engine: PolicyEngine
    private var _transcript = Transcript()
    private var lastCatchUp: Date?
    private var count = 0
    private var _lastRecord: DecisionRecord?

    /// The one question that may be outstanding. Answers arrive on other
    /// connections — a terminal today, a nod later — and resolve it here.
    private let desk = QuestionDesk()

    private let stateLock = NSLock()
    private var listener: UnixSocket?
    private var running = false

    private let workers = DispatchQueue(
        label: "navigator.connections", attributes: .concurrent)
    private let logging = DispatchQueue(label: "navigator.logging")
    /// Serial, so utterances queue rather than overlap.
    private let audio = DispatchQueue(label: "navigator.audio")

    public init(
        socketPath: String, log: DecisionLog?,
        config: PolicyConfig = .default,
        userRules: UserRules = UserRules(),
        speaker: any Speaker = SilentSpeaker(),
        microphoneIsBusy: @escaping @Sendable () -> Bool
            = InputDeviceMonitor.shouldSuppressAudio,
        startingAt: Date
    ) {
        self.socketPath = socketPath
        self.log = log
        self.config = config
        self.speaker = speaker
        self.announcer = Announcer(speaker: speaker)
        self.microphoneIsBusy = microphoneIsBusy
        self.engine = PolicyEngine(
            config: config, userRules: userRules, startingAt: startingAt)
    }

    public var decisionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    public var transcript: Transcript {
        lock.lock(); defer { lock.unlock() }
        return _transcript
    }

    /// The most recent record as it was written to the log, answer included.
    public var lastRecord: DecisionRecord? {
        lock.lock(); defer { lock.unlock() }
        return _lastRecord
    }

    private var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    public func start() throws {
        let listener = try UnixSocket.listen(at: socketPath)

        stateLock.lock()
        self.listener = listener
        running = true
        stateLock.unlock()

        Thread.detachNewThread { [weak self] in
            while self?.isRunning == true {
                guard let connection = try? listener.accept() else {
                    // A closed listener during stop() lands here; so does a
                    // transient accept failure. Only the former should end the
                    // loop, which is what the isRunning check above decides.
                    if self?.isRunning == true { continue } else { return }
                }
                self?.workers.async { self?.handleOnce(connection) }
            }
        }
    }

    public func stop() {
        stateLock.lock()
        running = false
        let listener = self.listener
        self.listener = nil
        stateLock.unlock()

        listener?.close()

        // A hook parked mid-shutdown must be released, not abandoned: its own
        // deadline would eventually free it, but "eventually" is 25 seconds of
        // a stalled tool call for no reason.
        desk.answerCurrent(.escalate)
        desk.clear()

        // Drain both queues before returning. Records and utterances are
        // dispatched asynchronously so neither disk nor audio sits on the hook's
        // critical path, which means a shutdown that does not wait here silently
        // discards whatever was still in flight.
        logging.sync {}
        audio.sync {}

        unlink(socketPath)
    }

    /// One request, one response, then close.
    public func handleOnce(_ connection: UnixSocket) {
        defer { connection.close() }

        guard let line = try? connection.readLine(deadline: 5),
              let request = try? NavigatorMessage.decode(line, as: NavigatorRequest.self)
        else {
            // Reply with silence rather than dropping the connection: the hook
            // is waiting, and a malformed request must not stall a tool call.
            reply(on: connection, NavigatorResponse.empty)
            return
        }

        if let command = request.command {
            let message = handle(command, argument: request.argument, at: request.at)
            reply(on: connection, NavigatorResponse(output: nil, message: message))
            return
        }

        guard let stamped = request.stamped else {
            reply(on: connection, NavigatorResponse.empty)
            return
        }

        lock.lock()
        let decision = engine.decide(stamped)
        var record = engine.log.last
        let sessionName = engine.registry.session(id: stamped.event.sessionID)
            .map(Transcript.name(of:)) ?? "a session"
        count += 1
        lock.unlock()

        let kind = stamped.event.kind

        // A decision point stops the agent on purpose — an approval that
        // arrives after the command ran is not an approval. Everything else
        // still answers in under a millisecond. Only PermissionRequest parks:
        // PreToolUse fires for the same call moments earlier, and asking twice
        // is worse than asking once.
        if kind == .permissionRequest, decision.blocking, config.canAcceptAnswers,
           let utterance = decision.utterance {
            let answer: Answer?
            let source: AnswerSource?

            if microphoneIsBusy() {
                // The question would go unspoken. Holding the agent behind a
                // question you cannot hear is a stall with no payoff.
                (answer, source) = (.escalate, nil)
            } else if desk.park(PendingQuestion(sessionName: sessionName, text: utterance)) {
                let question = desk.current!
                audio.async { [self] in speaker.say(utterance) }
                answer = question.wait(timeout: config.questionDeadline)
                source = question.answeredBy
                desk.clear()
                lock.lock(); engine.resolveQuestion(); lock.unlock()
            } else {
                // Refused rather than queued: stalling behind another agent's
                // unanswered question is worse than showing a prompt.
                (answer, source) = (.escalate, nil)
            }

            record = record?.answered(answer ?? .escalate, by: source)
            reply(on: connection, NavigatorResponse(
                output: encode(answer, for: kind, decision: decision)))
            announce(decision, sessionName: sessionName, at: stamped.at)
            append(record)
            return
        }

        // Respond first. Neither disk nor audio sits on the hook's critical path.
        // The engine's own allow needs both switches; everything else is nil,
        // which on PermissionRequest means the prompt appears.
        let output = try? HookOutput.encode(
            decision, for: kind, emitDecisions: config.emitDecisions && config.autoAllow)
        reply(on: connection, NavigatorResponse(output: output ?? nil))

        announce(decision, sessionName: sessionName, at: stamped.at)
        append(record)
    }

    /// Turns an answer into wire output. **Nil means nobody answered**, and
    /// that must never become `allow`.
    private func encode(
        _ answer: Answer?, for kind: HookEventKind, decision: Decision
    ) -> String? {
        switch answer {
        case .approve:
            return (try? HookOutput.encode(
                Decision(tier: decision.tier, permission: .allow,
                         utterance: nil, reason: decision.reason, blocking: false),
                for: kind, emitDecisions: config.emitDecisions)) ?? nil
        case .deny:
            return (try? HookOutput.answeredDenial(
                for: kind, reason: decision.reason,
                emitDecisions: config.emitDecisions)) ?? nil
        case .escalate, nil:
            // Silence is the escalation: nothing printed, prompt shown. There
            // is no wire value for it on any event.
            return nil
        }
    }

    private func announce(_ decision: Decision, sessionName: String, at: Date) {
        audio.async { [self] in
            // Checked per utterance rather than once at startup: whether you are
            // on a call changes minute to minute, which is the whole point.
            let onACall = microphoneIsBusy()
            let active = onACall ? silentAnnouncer : announcer

            guard let utterance = active.announce(
                decision, sessionName: sessionName, at: at) else { return }

            // Still recorded, but marked unheard — so catch-up can tell you what
            // happened while you were talking to someone.
            let recorded = onACall
                ? Utterance(
                    at: utterance.at, sessionName: utterance.sessionName,
                    text: utterance.text, tier: utterance.tier, wasSpoken: false)
                : utterance

            lock.lock(); _transcript.record(recorded); lock.unlock()
        }
    }

    private func append(_ record: DecisionRecord?) {
        guard let record else { return }
        lock.lock(); _lastRecord = record; lock.unlock()
        guard let log else { return }
        logging.async {
            do {
                try log.append(record, on: record.at)
            } catch {
                // The log is this build's entire product. A silent failure
                // here would look exactly like a quiet day.
                FileHandle.standardError.write(
                    Data("navigator: cannot write decision log: \(error)\n".utf8))
            }
        }
    }

    private func reply(on connection: UnixSocket, _ response: NavigatorResponse) {
        let data = (try? NavigatorMessage.encodeLine(response)) ?? Data("{}\n".utf8)
        try? connection.write(data)
    }

    // MARK: - Commands

    /// Returns text for the terminal. Speaking is a side effect where it makes
    /// sense — you may be asking from a keyboard or from across the room.
    private func handle(
        _ command: NavigatorCommand, argument: String?, at now: Date
    ) -> String {
        switch command {
        case .repeatLast:
            lock.lock()
            let last = _transcript.lastSpoken
            lock.unlock()

            guard let last else { return "Nothing has been said yet." }
            audio.async { [self] in speaker.say(last.text) }
            return last.text

        case .status:
            lock.lock()
            let sessions = engine.registry.activeSessions
            let text = _transcript.statusDigest(sessions: sessions, at: now)
            lock.unlock()

            audio.async { [self] in speaker.say(text) }
            return text

        case .catchUp:
            lock.lock()
            let text = _transcript.digest(since: lastCatchUp)
            lastCatchUp = now
            lock.unlock()

            audio.async { [self] in speaker.say(text) }
            return text

        case .mute:
            lock.lock(); engine.setMuted(true); lock.unlock()
            // Stop synchronously: the point of muting is that the current
            // sentence stops, not that it finishes first.
            speaker.stop()
            speaker.play(.acknowledged)
            return "Muted."

        case .unmute:
            lock.lock(); engine.setMuted(false); lock.unlock()
            speaker.play(.acknowledged)
            return "Unmuted."

        case .say:
            let text = argument ?? ""
            guard !text.isEmpty else { return "Nothing to say." }
            audio.async { [self] in speaker.say(text) }
            return text

        case .approve, .deny, .escalate:
            let answer: Answer = command == .approve ? .approve
                : command == .deny ? .deny : .escalate
            guard let text = desk.answerCurrent(answer, from: .terminal) else {
                return "No question is waiting."
            }
            speaker.play(.acknowledged)
            return "\(answer.rawValue): \(text)"
        }
    }
}
