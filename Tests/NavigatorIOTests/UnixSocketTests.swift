import Foundation
import Testing
@testable import NavigatorIO

@Suite struct UnixSocketBehavior {
    /// Socket paths are capped near 104 bytes on macOS, so tests use a short
    /// unique path rather than the usual long temp directory.
    private func tempPath(_ label: String) -> String {
        "/tmp/nav-\(label)-\(UInt32.random(in: 0..<UInt32.max)).sock"
    }

    @Test func roundTripsALine() throws {
        let path = tempPath("rt")
        let server = try UnixSocket.listen(at: path)
        defer { server.close(); unlink(path) }

        let sent = Data("hello\n".utf8)
        let done = DispatchSemaphore(value: 0)
        let received = Box<Data?>(nil)

        Thread.detachNewThread {
            let conn = try? server.accept()
            received.value = try? conn?.readLine(deadline: 2)
            try? conn?.write(Data("world\n".utf8))
            conn?.close()
            done.signal()
        }

        let client = try UnixSocket.connect(to: path, timeout: 2)
        try client.write(sent)
        let reply = try client.readLine(deadline: 2)
        client.close()
        _ = done.wait(timeout: .now() + 5)

        #expect(received.value == sent)
        #expect(reply == Data("world\n".utf8))
    }

    @Test func connectingToNothingFailsFast() {
        // The steady state when the daemon is not running. It must fail, and it
        // must fail immediately rather than hanging the tool call.
        let start = Date()
        #expect(throws: (any Error).self) {
            try UnixSocket.connect(to: tempPath("absent"), timeout: 2)
        }
        #expect(Date().timeIntervalSince(start) < 0.5)
    }

    @Test func readDeadlineIsEnforced() throws {
        let path = tempPath("dl")
        let server = try UnixSocket.listen(at: path)
        defer { server.close(); unlink(path) }

        // Accept but never reply.
        Thread.detachNewThread {
            let conn = try? server.accept()
            Thread.sleep(forTimeInterval: 3)
            conn?.close()
        }

        let client = try UnixSocket.connect(to: path, timeout: 2)
        defer { client.close() }

        let start = Date()
        #expect(throws: SocketError.timedOut) {
            try client.readLine(deadline: 0.25)
        }
        #expect(Date().timeIntervalSince(start) < 1.5)
    }

    @Test func rejectsOverlongPath() {
        let long = "/tmp/" + String(repeating: "x", count: 200) + ".sock"
        #expect(throws: SocketError.pathTooLong) {
            try UnixSocket.listen(at: long)
        }
    }

    @Test func listenReplacesAStaleSocketFile() throws {
        let path = tempPath("stale")
        // A socket file left behind by a killed daemon must not block startup.
        FileManager.default.createFile(atPath: path, contents: Data())
        defer { unlink(path) }

        let server = try UnixSocket.listen(at: path)
        server.close()
    }

    @Test func readsALineThatArrivesInPieces() throws {
        let path = tempPath("chunk")
        let server = try UnixSocket.listen(at: path)
        defer { server.close(); unlink(path) }

        Thread.detachNewThread {
            guard let conn = try? server.accept() else { return }
            try? conn.write(Data("par".utf8))
            Thread.sleep(forTimeInterval: 0.1)
            try? conn.write(Data("tial\n".utf8))
            conn.close()
        }

        let client = try UnixSocket.connect(to: path, timeout: 2)
        defer { client.close() }
        let line = try client.readLine(deadline: 2)
        #expect(line == Data("partial\n".utf8))
    }

    @Test func readsTwoLinesFromOneStream() throws {
        // Guards the buffer re-basing: Data slices keep the parent's indices,
        // so a naive implementation reads the first line and then loses its
        // place on the second.
        let path = tempPath("two")
        let server = try UnixSocket.listen(at: path)
        defer { server.close(); unlink(path) }

        Thread.detachNewThread {
            guard let conn = try? server.accept() else { return }
            try? conn.write(Data("first\nsecond\n".utf8))
            Thread.sleep(forTimeInterval: 0.5)
            conn.close()
        }

        let client = try UnixSocket.connect(to: path, timeout: 2)
        defer { client.close() }
        #expect(try client.readLine(deadline: 2) == Data("first\n".utf8))
        #expect(try client.readLine(deadline: 2) == Data("second\n".utf8))
    }
}

/// Minimal mutable box so a detached thread can hand a value back without
/// tripping Swift 6's capture checking.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
