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

    private let lock = NSLock()
    private var engine: PolicyEngine
    private var _transcript = Transcript()
    private var lastCatchUp: Date?
    private var count = 0

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
        speaker: any Speaker = SilentSpeaker(),
        startingAt: Date
    ) {
        self.socketPath = socketPath
        self.log = log
        self.config = config
        self.speaker = speaker
        self.announcer = Announcer(speaker: speaker)
        self.engine = PolicyEngine(config: config, startingAt: startingAt)
    }

    public var decisionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    public var transcript: Transcript {
        lock.lock(); defer { lock.unlock() }
        return _transcript
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
        let record = engine.log.last
        let sessionName = engine.registry.session(id: stamped.event.sessionID)
            .map(Transcript.name(of:)) ?? "a session"
        count += 1
        lock.unlock()

        let output = try? HookOutput.encode(
            decision, for: stamped.event.kind, emitDecisions: config.emitDecisions)

        // Respond first. Neither disk nor audio sits on the hook's critical path.
        reply(on: connection, NavigatorResponse(output: output ?? nil))

        audio.async { [self] in
            guard let utterance = announcer.announce(
                decision, sessionName: sessionName, at: stamped.at) else { return }
            lock.lock(); _transcript.record(utterance); lock.unlock()
        }

        if let log, let record {
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
        }
    }
}
