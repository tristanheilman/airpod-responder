import Foundation
import Testing
@testable import NavigatorAudio
@testable import NavigatorCore
@testable import NavigatorIO

/// Serialized: every test here holds a real listener thread and a socket.
/// Running ten at once starves accept and the client deadlines expire.
@Suite(.serialized) struct ServerAudio {
    private func tempPath() -> String {
        "/tmp/navaudio-\(UInt32.random(in: 0..<UInt32.max)).sock"
    }

    private func makeServer(
        _ path: String, speaker: RecordingSpeaker
    ) throws -> NavigatorServer {
        var config = PolicyConfig.default
        config.speechInterval = 1  // do not let the budget mask wiring bugs
        let server = NavigatorServer(
            socketPath: path, log: nil, config: config, speaker: speaker,
            startingAt: Date(timeIntervalSince1970: 1_770_000_000))
        try server.start()
        return server
    }

    private func send(_ path: String, _ request: NavigatorRequest) throws -> NavigatorResponse {
        let client = try UnixSocket.connect(to: path, timeout: 10)
        defer { client.close() }
        try client.write(try NavigatorMessage.encodeLine(request))
        return try NavigatorMessage.decode(
            try client.readLine(deadline: 10), as: NavigatorResponse.self)
    }

    private func bash(_ command: String, at: Date) -> NavigatorRequest {
        NavigatorRequest(
            event: HookEvent(
                kind: .preToolUse, sessionID: "s1", cwd: "/Users/t/Projects/app",
                toolName: "Bash", toolInput: ["command": .string(command)]),
            at: at)
    }

    /// Audio is dispatched after the response, so wait for it rather than sleep.
    private func settle(_ speaker: RecordingSpeaker, until: () -> Bool) {
        for _ in 0..<100 {
            if until() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    @Test func speaksABlockingDecision() throws {
        let path = tempPath(), speaker = RecordingSpeaker()
        let server = try makeServer(path, speaker: speaker)
        defer { server.stop() }

        _ = try send(path, bash("git push --force", at: Date(timeIntervalSince1970: 1_770_000_000)))
        settle(speaker) { !speaker.spoken.isEmpty }

        #expect(speaker.spoken.count == 1)
        #expect(speaker.spoken.first?.contains("force push") == true)
    }

    @Test func staysSilentOnRoutineCalls() throws {
        let path = tempPath(), speaker = RecordingSpeaker()
        let server = try makeServer(path, speaker: speaker)
        defer { server.stop() }

        _ = try send(path, bash("swift build", at: Date(timeIntervalSince1970: 1_770_000_000)))
        server.stop()  // drains the audio queue, so this is not a race

        #expect(speaker.spoken.isEmpty)
        #expect(speaker.played.isEmpty)
    }

    @Test func repeatReplaysTheLastSpokenLine() throws {
        let path = tempPath(), speaker = RecordingSpeaker()
        let server = try makeServer(path, speaker: speaker)
        defer { server.stop() }

        let t0 = Date(timeIntervalSince1970: 1_770_000_000)
        _ = try send(path, bash("git push --force", at: t0))
        settle(speaker) { !speaker.spoken.isEmpty }

        let first = speaker.spoken[0]
        let response = try send(path, .control(.repeatLast, at: t0.addingTimeInterval(30)))
        settle(speaker) { speaker.spoken.count == 2 }

        #expect(speaker.spoken.count == 2)
        #expect(speaker.spoken.last == first)
        #expect(response.message == first)
    }

    @Test func repeatWithNothingToSayIsGraceful() throws {
        let path = tempPath(), speaker = RecordingSpeaker()
        let server = try makeServer(path, speaker: speaker)
        defer { server.stop() }

        let response = try send(
            path, .control(.repeatLast, at: Date(timeIntervalSince1970: 1_770_000_000)))
        #expect(response.message?.isEmpty == false)
        #expect(speaker.spoken.isEmpty)
    }

    @Test func statusNamesActiveSessions() throws {
        let path = tempPath(), speaker = RecordingSpeaker()
        let server = try makeServer(path, speaker: speaker)
        defer { server.stop() }

        let t0 = Date(timeIntervalSince1970: 1_770_000_000)
        _ = try send(path, NavigatorRequest(
            event: HookEvent(
                kind: .sessionStart, sessionID: "s1", cwd: "/Users/t/Projects/app"),
            at: t0))

        let response = try send(path, .control(.status, at: t0.addingTimeInterval(10)))
        #expect(response.message?.contains("app") == true)
    }

    @Test func muteStopsSpeechAndUnmuteRestoresIt() throws {
        let path = tempPath(), speaker = RecordingSpeaker()
        let server = try makeServer(path, speaker: speaker)
        defer { server.stop() }

        let t0 = Date(timeIntervalSince1970: 1_770_000_000)
        _ = try send(path, .control(.mute, at: t0))
        _ = try send(path, bash("git push --force", at: t0.addingTimeInterval(1)))
        Thread.sleep(forTimeInterval: 0.2)
        #expect(speaker.spoken.isEmpty, "spoke while muted")

        _ = try send(path, .control(.unmute, at: t0.addingTimeInterval(2)))
        _ = try send(path, bash("rm -rf build", at: t0.addingTimeInterval(3)))
        settle(speaker) { !speaker.spoken.isEmpty }
        #expect(!speaker.spoken.isEmpty, "stayed silent after unmute")
    }

    @Test func catchUpIncludesWhatWasSuppressed() throws {
        let path = tempPath(), speaker = RecordingSpeaker()
        let server = try makeServer(path, speaker: speaker)
        defer { server.stop() }

        let t0 = Date(timeIntervalSince1970: 1_770_000_000)
        _ = try send(path, .control(.mute, at: t0))
        _ = try send(path, bash("git push --force", at: t0.addingTimeInterval(1)))
        Thread.sleep(forTimeInterval: 0.2)
        _ = try send(path, .control(.unmute, at: t0.addingTimeInterval(2)))

        let response = try send(path, .control(.catchUp, at: t0.addingTimeInterval(3)))
        #expect(response.message?.contains("force push") == true)
    }

    @Test func catchUpOnlyReportsWhatIsNewSinceLastTime() throws {
        let path = tempPath(), speaker = RecordingSpeaker()
        let server = try makeServer(path, speaker: speaker)
        defer { server.stop() }

        let t0 = Date(timeIntervalSince1970: 1_770_000_000)
        _ = try send(path, bash("git push --force", at: t0))
        Thread.sleep(forTimeInterval: 0.2)
        _ = try send(path, .control(.catchUp, at: t0.addingTimeInterval(10)))

        let second = try send(path, .control(.catchUp, at: t0.addingTimeInterval(20)))
        #expect(second.message?.lowercased().contains("nothing") == true)
    }

    @Test func sayCommandSpeaksItsArgument() throws {
        let path = tempPath(), speaker = RecordingSpeaker()
        let server = try makeServer(path, speaker: speaker)
        defer { server.stop() }

        _ = try send(path, .control(
            .say, argument: "audio check",
            at: Date(timeIntervalSince1970: 1_770_000_000)))
        settle(speaker) { !speaker.spoken.isEmpty }

        #expect(speaker.spoken == ["audio check"])
    }

    @Test func commandsNeverReturnOutputToClaudeCode() throws {
        let path = tempPath(), speaker = RecordingSpeaker()
        let server = try makeServer(path, speaker: speaker)
        defer { server.stop() }

        let t0 = Date(timeIntervalSince1970: 1_770_000_000)
        for command in NavigatorCommand.allCases {
            let response = try send(path, .control(command, argument: "x", at: t0))
            #expect(response.output == nil, "\(command) produced hook output")
        }
    }
}
