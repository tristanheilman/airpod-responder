import Foundation
import NavigatorCore

/// Measures the daemon-side round trip: connect, send, decide, reply.
///
/// This excludes process startup, which was measured separately at ~3.3ms for a
/// Swift + Foundation binary. Total hook cost is roughly the sum of the two.
public enum HookLatency {
    public static func measure(
        socketPath: String, iterations: Int
    ) -> (median: TimeInterval, p95: TimeInterval) {
        let request = NavigatorRequest(
            event: HookEvent(
                kind: .preToolUse, sessionID: "bench", cwd: "/p",
                toolName: "Bash", toolInput: ["command": .string("swift build")]),
            at: Date(timeIntervalSince1970: 1_770_000_000))

        guard let line = try? NavigatorMessage.encodeLine(request) else { return (0, 0) }

        var samples: [TimeInterval] = []
        samples.reserveCapacity(iterations)

        for _ in 0..<iterations {
            let start = Date()
            guard let socket = try? UnixSocket.connect(to: socketPath, timeout: 1) else { continue }
            try? socket.write(line)
            _ = try? socket.readLine(deadline: 1)
            socket.close()
            samples.append(Date().timeIntervalSince(start))
        }

        guard !samples.isEmpty else { return (0, 0) }
        samples.sort()
        return (
            samples[samples.count / 2],
            samples[min(samples.count - 1, samples.count * 95 / 100)])
    }
}
