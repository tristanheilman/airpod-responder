import Darwin
import Foundation
import NavigatorCore

/// Accepts hook connections, decides, replies, then logs.
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

    private let lock = NSLock()
    private var engine: PolicyEngine
    private var count = 0

    private let stateLock = NSLock()
    private var listener: UnixSocket?
    private var running = false

    private let workers = DispatchQueue(
        label: "navigator.connections", attributes: .concurrent)
    private let logging = DispatchQueue(label: "navigator.logging")

    public init(
        socketPath: String, log: DecisionLog?,
        config: PolicyConfig = .default, startingAt: Date
    ) {
        self.socketPath = socketPath
        self.log = log
        self.config = config
        self.engine = PolicyEngine(config: config, startingAt: startingAt)
    }

    public var decisionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
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
            let empty = (try? NavigatorMessage.encodeLine(NavigatorResponse.empty))
                ?? Data("{}\n".utf8)
            try? connection.write(empty)
            return
        }

        lock.lock()
        let decision = engine.decide(request.stamped)
        let record = engine.log.last
        count += 1
        lock.unlock()

        let output = try? HookOutput.encode(
            decision, for: request.event.kind, emitDecisions: config.emitDecisions)

        // Respond first. Disk never sits on the hook's critical path.
        if let reply = try? NavigatorMessage.encodeLine(
            NavigatorResponse(output: output ?? nil)) {
            try? connection.write(reply)
        }

        if let log, let record {
            logging.async { try? log.append(record, on: record.at) }
        }
    }
}
