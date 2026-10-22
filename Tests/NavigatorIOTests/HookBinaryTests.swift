import Foundation
import Testing
@testable import NavigatorCore
@testable import NavigatorIO

/// Serialized because every test here spawns a subprocess; running them against
/// the rest of the suite concurrently starves the daemon's worker queue and the
/// hook gives up on its deadline before a reply arrives.
@Suite(.serialized) struct HookBinaryContract {
    /// Resolved from this file's path rather than `Bundle.main`, which points at
    /// the xctest harness and moves around between toolchains. `.build/debug` is
    /// a stable symlink to the current triple's products directory.
    private var hookURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // NavigatorIOTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(".build/debug/navigator-hook")
    }

    private struct Outcome { let status: Int32; let stdout: String; let stderr: String }

    /// The default deadline here is deliberately far looser than production's
    /// 250ms. These tests check the hook's *contract* — what it prints and what
    /// it exits with — and a CI box mid-suite is nothing like an idle daemon.
    /// Actual latency is pinned by `EndToEnd.medianRoundTripStaysUnder...`,
    /// which measures it directly instead of inferring it from a timeout.
    private func run(stdin: String, socket: String, deadlineMS: Int? = 3000) throws -> Outcome {
        let process = Process()
        process.executableURL = hookURL
        var environment = [
            "NAVIGATOR_SOCKET": socket,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
        // nil leaves the override unset, so the binary's own default applies.
        if let deadlineMS { environment["NAVIGATOR_DEADLINE_MS"] = String(deadlineMS) }
        process.environment = environment
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        try? inPipe.fileHandleForWriting.close()

        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Outcome(
            status: process.terminationStatus,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self))
    }

    private let samplePayload = """
    {"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/p","tool_name":"Bash","tool_input":{"command":"swift build"}}
    """

    @Test func theBinaryExists() {
        #expect(FileManager.default.isExecutableFile(atPath: hookURL.path),
                "run `swift build` before the test suite: \(hookURL.path)")
    }

    @Test func exitsZeroAndSilentWhenNoDaemonIsRunning() throws {
        // The steady state with the daemon down. Must be indistinguishable from
        // having no hook installed at all.
        let result = try run(stdin: samplePayload, socket: "/tmp/definitely-absent.sock")
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
    }

    @Test func neverExitsTwoOnMalformedInput() throws {
        // Exit 2 BLOCKS the tool call. No input may ever produce it.
        for junk in ["", "not json", "{", "{\"hook_event_name\":\"Nope\"}", "null", "[]"] {
            let result = try run(stdin: junk, socket: "/tmp/definitely-absent.sock")
            #expect(result.status != 2, "exit 2 on input: \(junk)")
            #expect(result.status == 0, "expected 0, got \(result.status) on: \(junk)")
        }
    }

    @Test func printsWhateverTheDaemonReturns() throws {
        let path = "/tmp/navhook-\(UInt32.random(in: 0..<UInt32.max)).sock"
        var config = PolicyConfig.default
        config.emitDecisions = true
        // The engine's own verdict reaches the wire only behind both switches.
        config.autoAllow = true
        let server = NavigatorServer(
            socketPath: path, log: nil, config: config,
            startingAt: Date(timeIntervalSince1970: 1_770_000_000))
        try server.start()
        defer { server.stop() }

        let result = try run(stdin: samplePayload, socket: path)
        #expect(result.status == 0)
        #expect(result.stdout.contains("permissionDecision"))
        #expect(result.stdout.contains("allow"))
    }

    @Test func printsNothingWhenTheGateIsClosed() throws {
        let path = "/tmp/navhook-\(UInt32.random(in: 0..<UInt32.max)).sock"
        let server = NavigatorServer(
            socketPath: path, log: nil, config: .default,
            startingAt: Date(timeIntervalSince1970: 1_770_000_000))
        try server.start()
        defer { server.stop() }

        let result = try run(stdin: samplePayload, socket: path)
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
    }

    @Test func givesUpOnAWedgedDaemonWithoutBlocking() throws {
        // A listener that accepts and then never answers.
        let path = "/tmp/navwedge-\(UInt32.random(in: 0..<UInt32.max)).sock"
        let listener = try UnixSocket.listen(at: path)
        defer { listener.close(); unlink(path) }
        Thread.detachNewThread {
            let conn = try? listener.accept()
            Thread.sleep(forTimeInterval: 10)
            conn?.close()
        }

        let start = Date()
        let result = try run(stdin: samplePayload, socket: path, deadlineMS: 200)
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(elapsed < 3, "hook waited \(elapsed)s on a wedged daemon")
    }

    @Test func aLeftoverDeadlineOverrideCannotStopParking() throws {
        // NAVIGATOR_DEADLINE_MS tunes the 250ms the silent majority gets. A
        // stray 200 left in a launchd plist from testing must not quietly
        // turn every question into an instant escalation.
        let path = "/tmp/navhook-\(UInt32.random(in: 0..<UInt32.max)).sock"
        var config = PolicyConfig.default
        config.emitDecisions = true
        config.canAcceptAnswers = true
        config.questionDeadline = 1
        let server = NavigatorServer(
            socketPath: path, log: nil, config: config,
            microphoneIsBusy: { false },
            startingAt: Date(timeIntervalSince1970: 1_770_000_000))
        try server.start()
        defer { server.stop() }

        let question = """
        {"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/p","tool_name":"Bash","tool_input":{"command":"git push --force"}}
        """
        let start = Date()
        let result = try run(stdin: question, socket: path, deadlineMS: 200)
        #expect(result.status == 0)
        #expect(Date().timeIntervalSince(start) >= 0.9, "the override shortened the hold")
    }

    @Test func waitsOutAQuestionByDefaultOnlyForPermissionRequest() throws {
        // The hook's built-in deadline is 250ms — right for the silent majority,
        // fatal for a question. PermissionRequest is the one event that parks,
        // so it alone gets a deadline longer than the daemon's hold.
        let path = "/tmp/navhook-\(UInt32.random(in: 0..<UInt32.max)).sock"
        var config = PolicyConfig.default
        config.emitDecisions = true
        config.canAcceptAnswers = true
        config.questionDeadline = 1
        let server = NavigatorServer(
            socketPath: path, log: nil, config: config,
            microphoneIsBusy: { false },
            startingAt: Date(timeIntervalSince1970: 1_770_000_000))
        try server.start()
        defer { server.stop() }

        let question = """
        {"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/p","tool_name":"Bash","tool_input":{"command":"git push --force"}}
        """
        let start = Date()
        let result = try run(stdin: question, socket: path, deadlineMS: nil)
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.status == 0)
        #expect(elapsed >= 0.9, "gave up before the daemon's deadline: \(elapsed)s")
        #expect(result.stdout.isEmpty, "nobody answered, so the prompt must appear: \(result.stdout)")
    }
}
