import Foundation
import Testing
@testable import NavigatorAudio
@testable import NavigatorCore
@testable import NavigatorIO

/// The whole loop with nothing faked: a real socket, the real hook binary as a
/// subprocess, and an answer arriving on a second connection. Serialized
/// because every test spawns a process.
@Suite(.serialized) struct AnsweringEndToEnd {
    private var hookURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/navigator-hook")
    }

    private let question = """
    {"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/p","tool_name":"Bash","tool_input":{"command":"git push --force"}}
    """

    /// A hook left running so the test can look at it mid-question.
    private final class RunningHook {
        let process = Process()
        let stdout = Pipe()

        init(binary: URL, socket: String, stdin: String) throws {
            process.executableURL = binary
            process.environment = [
                "NAVIGATOR_SOCKET": socket,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            ]
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = stdout
            process.standardError = Pipe()
            try process.run()
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }

        func finish() -> (status: Int32, stdout: String) {
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: out, as: UTF8.self))
        }
    }

    private func answer(_ command: NavigatorCommand, on path: String) throws {
        let client = try UnixSocket.connect(to: path, timeout: 10)
        defer { client.close() }
        try client.write(try NavigatorMessage.encodeLine(
            NavigatorRequest.control(command, at: Date())))
        _ = try client.readLine(deadline: 10)
    }

    @Test func aTypedApproveLetsTheToolCallThrough() throws {
        // This is milestone 1: the first time anything this daemon says
        // reaches Claude Code. Everything before it was narration.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nav-ans-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = "/tmp/nav-ans-\(UInt32.random(in: 0..<UInt32.max)).sock"

        var config = PolicyConfig.default
        config.emitDecisions = true
        config.canAcceptAnswers = true
        config.questionDeadline = 10
        let log = DecisionLog(directory: dir)
        let server = NavigatorServer(
            socketPath: path, log: log, config: config,
            microphoneIsBusy: { false }, startingAt: Date())
        try server.start()
        defer { server.stop() }

        let hook = try RunningHook(binary: hookURL, socket: path, stdin: question)
        Thread.sleep(forTimeInterval: 1)
        #expect(hook.process.isRunning, "the hook did not wait for an answer")

        try answer(.approve, on: path)
        let result = hook.finish()

        #expect(result.status == 0)
        #expect(result.stdout.contains("\"hookEventName\":\"PermissionRequest\""))
        #expect(result.stdout.contains("\"decision\":{\"behavior\":\"allow\"}"))

        var records: [DecisionRecord] = []
        for _ in 0..<50 {
            records = (try? DecisionLog.replayable(from: log.path(for: Date()))) ?? []
            if !records.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let record = try #require(records.last)
        #expect(record.answer == .approve)
        #expect(record.answerSource == .terminal)
    }

    @Test func aDaemonThatDiesMidQuestionStillFreesTheHook() throws {
        // Being made to wait must not create a way to exit non-zero, and the
        // hook must notice the daemon is gone rather than sit out its 25s.
        let path = "/tmp/nav-dead-\(UInt32.random(in: 0..<UInt32.max)).sock"
        let listener = try UnixSocket.listen(at: path)
        defer { listener.close(); unlink(path) }

        // Accepts, reads the question, then drops dead without replying.
        Thread.detachNewThread {
            guard let conn = try? listener.accept() else { return }
            _ = try? conn.readLine(deadline: 5)
            Thread.sleep(forTimeInterval: 1)
            conn.close()
        }

        let start = Date()
        let hook = try RunningHook(binary: hookURL, socket: path, stdin: question)
        let result = hook.finish()
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.status == 0)
        #expect(result.stdout.isEmpty, "printed a decision nobody made: \(result.stdout)")
        #expect(elapsed < 5, "sat out the deadline after the daemon died: \(elapsed)s")
    }
}
