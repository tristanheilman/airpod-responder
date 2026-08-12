import Foundation
import Testing
@testable import NavigatorCore
@testable import NavigatorIO

@Suite(.serialized) struct EndToEnd {
    @Test func aDayOfEventsProducesALogAndNoOutput() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nav-e2e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = "/tmp/nav-e2e-\(UInt32.random(in: 0..<UInt32.max)).sock"
        let day = Date(timeIntervalSince1970: 1_770_000_000)
        let log = DecisionLog(directory: dir)
        let server = NavigatorServer(
            socketPath: path, log: log, config: .default, startingAt: day)
        try server.start()
        defer { server.stop() }

        let events: [HookEvent] = [
            HookEvent(kind: .sessionStart, sessionID: "s1", cwd: "/p"),
            HookEvent(kind: .userPromptSubmit, sessionID: "s1", cwd: "/p", prompt: "build it"),
            HookEvent(kind: .preToolUse, sessionID: "s1", cwd: "/p",
                      toolName: "Bash", toolInput: ["command": .string("swift build")]),
            HookEvent(kind: .preToolUse, sessionID: "s1", cwd: "/p",
                      toolName: "Bash", toolInput: ["command": .string("git push --force")]),
            HookEvent(kind: .postToolUseFailure, sessionID: "s1", cwd: "/p",
                      error: "cannot find 'Foo' in scope"),
            HookEvent(kind: .stop, sessionID: "s1", cwd: "/p"),
        ]

        for (i, event) in events.enumerated() {
            let client = try UnixSocket.connect(to: path, timeout: 10)
            defer { client.close() }
            let request = NavigatorRequest(
                event: event, at: day.addingTimeInterval(Double(i) * 10))
            try client.write(try NavigatorMessage.encodeLine(request))
            let reply = try client.readLine(deadline: 10)
            let response = try NavigatorMessage.decode(reply, as: NavigatorResponse.self)

            // The whole point of the observer build.
            #expect(response.output == nil, "gate leaked on \(event.kind)")
        }

        var records: [DecisionRecord] = []
        for _ in 0..<50 {
            records = (try? DecisionLog.replayable(from: log.path(for: day))) ?? []
            if records.count == events.count { break }
            Thread.sleep(forTimeInterval: 0.05)
        }

        #expect(records.count == events.count)
        // The log still shows what it *would* have done, which is how the gate
        // gets opened later with evidence rather than optimism.
        #expect(records.contains { $0.permission == .allow })
        #expect(records.contains { $0.tierAssigned == .decisionPoint })
    }

    @Test func medianRoundTripStaysUnderFiveMilliseconds() throws {
        let path = "/tmp/nav-lat-\(UInt32.random(in: 0..<UInt32.max)).sock"
        let server = NavigatorServer(
            socketPath: path, log: nil, config: .default,
            startingAt: Date(timeIntervalSince1970: 1_770_000_000))
        try server.start()
        defer { server.stop() }

        let result = HookLatency.measure(socketPath: path, iterations: 200)

        // This sits in front of every matched tool call, so it is a budget, not
        // a curiosity. Generous enough not to be flaky on a loaded machine.
        #expect(result.median < 0.005, "median \(result.median * 1000)ms")
        #expect(result.p95 < 0.020, "p95 \(result.p95 * 1000)ms")
    }
}
