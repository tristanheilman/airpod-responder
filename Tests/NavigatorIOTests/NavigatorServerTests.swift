import Foundation
import Testing
@testable import NavigatorCore
@testable import NavigatorIO

@Suite struct NavigatorServing {
    private func tempPath() -> String {
        "/tmp/navsrv-\(UInt32.random(in: 0..<UInt32.max)).sock"
    }

    private func request(_ command: String) -> NavigatorRequest {
        NavigatorRequest(
            event: HookEvent(
                kind: .preToolUse, sessionID: "s1", cwd: "/p",
                toolName: "Bash", toolInput: ["command": .string(command)]),
            at: Date(timeIntervalSince1970: 1_770_000_000))
    }

    private func exchange(_ path: String, _ request: NavigatorRequest) throws -> NavigatorResponse {
        let client = try UnixSocket.connect(to: path, timeout: 2)
        defer { client.close() }
        try client.write(try NavigatorMessage.encodeLine(request))
        let line = try client.readLine(deadline: 2)
        return try NavigatorMessage.decode(line, as: NavigatorResponse.self)
    }

    @Test func respondsEmptyWithTheGateClosed() throws {
        let path = tempPath()
        let server = NavigatorServer(
            socketPath: path, log: nil, config: .default,
            startingAt: Date(timeIntervalSince1970: 1_770_000_000))
        try server.start()
        defer { server.stop() }

        // Safe and unsafe alike: with the gate shut, both get nothing.
        #expect(try exchange(path, request("swift build")).output == nil)
        #expect(try exchange(path, request("git push --force")).output == nil)
    }

    @Test func emitsAllowWhenTheGateIsOpen() throws {
        let path = tempPath()
        var config = PolicyConfig.default
        config.emitDecisions = true
        let server = NavigatorServer(
            socketPath: path, log: nil, config: config,
            startingAt: Date(timeIntervalSince1970: 1_770_000_000))
        try server.start()
        defer { server.stop() }

        let safe = try exchange(path, request("swift build"))
        let unsafe = try exchange(path, request("git push --force"))

        #expect(safe.output?.contains("\"permissionDecision\":\"allow\"") == true)
        #expect(unsafe.output == nil, "irreversible defers, which is silence")
    }

    @Test func handlesSequentialConnections() throws {
        let path = tempPath()
        let server = NavigatorServer(
            socketPath: path, log: nil, config: .default,
            startingAt: Date(timeIntervalSince1970: 1_770_000_000))
        try server.start()
        defer { server.stop() }

        for _ in 0..<20 { _ = try exchange(path, request("swift build")) }
        #expect(server.decisionCount == 20)
    }

    @Test func handlesConcurrentConnections() throws {
        // Parallel tool calls across several sessions are the normal case.
        let path = tempPath()
        let server = NavigatorServer(
            socketPath: path, log: nil, config: .default,
            startingAt: Date(timeIntervalSince1970: 1_770_000_000))
        try server.start()
        defer { server.stop() }

        let group = DispatchGroup()
        for _ in 0..<16 {
            group.enter()
            DispatchQueue.global().async {
                _ = try? self.exchange(path, self.request("swift build"))
                group.leave()
            }
        }
        #expect(group.wait(timeout: .now() + 10) == .success)
        #expect(server.decisionCount == 16)
    }

    @Test func writesToTheDecisionLog() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("navsrvlog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = tempPath()
        let log = DecisionLog(directory: dir)
        let day = Date(timeIntervalSince1970: 1_770_000_000)
        let server = NavigatorServer(
            socketPath: path, log: log, config: .default, startingAt: day)
        try server.start()
        defer { server.stop() }

        _ = try exchange(path, request("git push --force"))

        // Logging happens after the response, so give it a moment to land.
        var records: [DecisionRecord] = []
        for _ in 0..<50 {
            records = (try? DecisionLog.replayable(from: log.path(for: day))) ?? []
            if !records.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.05)
        }

        #expect(records.count == 1)
        #expect(records.first?.tierAssigned == .decisionPoint)
        #expect(records.first?.permission == .defer)
    }

    @Test func stopDrainsPendingLogWrites() throws {
        // Records are appended asynchronously so disk stays off the hook's
        // critical path. A stop that does not wait therefore drops whatever is
        // still queued — in practice the last few decisions of every session.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("navdrain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = tempPath()
        let log = DecisionLog(directory: dir)
        let day = Date(timeIntervalSince1970: 1_770_000_000)
        let server = NavigatorServer(
            socketPath: path, log: log, config: .default, startingAt: day)
        try server.start()

        for _ in 0..<10 { _ = try exchange(path, request("swift build")) }

        // No sleep: stop() must do the waiting.
        server.stop()

        let records = try DecisionLog.replayable(from: log.path(for: day))
        #expect(records.count == 10, "lost \(10 - records.count) records on shutdown")
    }

    @Test func stopRemovesTheSocketFile() throws {
        let path = tempPath()
        let server = NavigatorServer(
            socketPath: path, log: nil, config: .default,
            startingAt: Date(timeIntervalSince1970: 1_770_000_000))
        try server.start()
        #expect(FileManager.default.fileExists(atPath: path))

        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path),
                "a stale socket left behind confuses the next status check")
    }

    @Test func malformedRequestDoesNotKillTheServer() throws {
        let path = tempPath()
        let server = NavigatorServer(
            socketPath: path, log: nil, config: .default,
            startingAt: Date(timeIntervalSince1970: 1_770_000_000))
        try server.start()
        defer { server.stop() }

        let bad = try UnixSocket.connect(to: path, timeout: 2)
        try bad.write(Data("this is not json\n".utf8))
        _ = try? bad.readLine(deadline: 1)
        bad.close()

        // Still serving.
        #expect(try exchange(path, request("swift build")).output == nil)
    }
}
