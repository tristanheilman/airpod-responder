# Daemon and Hook Binary Implementation Plan


**Goal:** Get the policy engine running against real Claude Code sessions as a pure observer — a daemon that decides, a hook binary that reports, and a decision log on disk — with provably zero effect on what Claude Code does.

**Architecture:** Two executables over a Unix domain socket. `navigator-hook` is invoked by Claude Code on every matched event, forwards the payload, and prints whatever the daemon returns. `navigator` holds the `PolicyEngine`, decides, responds, and appends to a decision log. In this build the daemon's response is **always empty** — the wire gate is closed — so the hook is silent and Claude Code behaves exactly as it would with no hook installed. Audio is not in this plan.

**Tech Stack:** Swift 6 (language mode v6), Foundation, POSIX sockets (`AF_UNIX`), Swift Testing, SwiftPM.

## Global Constraints

- **The hook must never exit 2.** Exit 2 is a *blocking* error in Claude Code — it stops the tool call. The hook exits 0 on every path including daemon-down, malformed input, timeout, and internal error. There is no code path that can produce 2.
- **The wire gate is closed in this build.** `emitDecisions` is `false`, and `HookOutput.encode` returns `nil` for every input when it is. This is asserted as a property over all decisions × all event kinds, and it is the safety guarantee — stronger than the blast-radius invariant, which remains as a backstop.
- **`NavigatorCore` stays pure.** No I/O is added to it. All filesystem and socket code lives in the new `NavigatorIO` target.
- **The daemon responds before it logs.** Disk writes never sit on the hook's critical path.
- **Hook timeout is set explicitly.** Claude Code's default for `command` hooks is **600 seconds**; the installed config sets 5. The hook also enforces its own, shorter read deadline rather than trusting either the daemon or Claude Code.
- **"No daemon" is success, not error.** A failed connect is the expected steady state whenever the daemon is not running, and must be indistinguishable from not having a hook installed.
- Socket: `~/.claude/navigator.sock`. Logs: `~/.claude/navigator/decisions-YYYY-MM-DD.jsonl`.
- `#expect`/`#require` cannot contain `mutating` or `throws` calls — hoist into a `let` first. (Learned in the policy-engine plan; it will bite again here.)

---

### Task 1: Close the wire gate

**Files:**
- Modify: `Sources/NavigatorCore/Events/HookOutput.swift`
- Modify: `Sources/NavigatorCore/Policy/PolicyConfig.swift`
- Test: `Tests/NavigatorCoreTests/HookOutputTests.swift`

**Interfaces:**
- Consumes: `Decision`, `HookEventKind`, `PermissionDecision`.
- Produces: `HookOutput.encode(_:for:emitDecisions:) throws -> String?` (the existing two-argument form keeps working, defaulting `emitDecisions` to `true`); `PolicyConfig.emitDecisions: Bool` defaulting to `false`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/NavigatorCoreTests/HookOutputTests.swift`:

```swift
@Suite struct WireGate {
    /// Every decision the engine can possibly produce.
    private static let decisions: [Decision] = {
        var all: [Decision] = []
        for tier in Tier.allCases {
            for permission: PermissionDecision? in [nil, .allow, .defer, .deny] {
                all.append(Decision(
                    tier: tier, permission: permission,
                    utterance: nil, reason: "r", blocking: tier.isBlocking))
            }
        }
        return all
    }()

    @Test func closedGateEmitsNothingForAnyInputAtAll() throws {
        // This is the observer-build safety guarantee: not "the engine won't
        // decide badly", but "nothing the engine decides can reach the wire".
        for decision in Self.decisions {
            for kind in HookEventKind.allCases {
                let out = try HookOutput.encode(decision, for: kind, emitDecisions: false)
                #expect(out == nil, "gate leaked for \(kind) \(String(describing: decision.permission))")
            }
        }
    }

    @Test func closedGateDoesNotThrowOnDeny() throws {
        // With the gate shut, deny is not an error — nothing is being emitted,
        // so there is nothing to refuse. The throw belongs to the open gate.
        let deny = Decision(tier: .silent, permission: .deny,
                            utterance: nil, reason: "r", blocking: false)
        #expect(try HookOutput.encode(deny, for: .preToolUse, emitDecisions: false) == nil)
    }

    @Test func openGateStillEmitsAllow() throws {
        let allow = Decision(tier: .silent, permission: .allow,
                             utterance: nil, reason: "ok", blocking: false)
        let out = try HookOutput.encode(allow, for: .preToolUse, emitDecisions: true)
        #expect(out != nil)
    }

    @Test func defaultConfigHasTheGateClosed() {
        #expect(PolicyConfig.default.emitDecisions == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WireGate`
Expected: FAIL — `extra argument 'emitDecisions' in call`

- [ ] **Step 3: Add the gate**

In `Sources/NavigatorCore/Events/HookOutput.swift`, replace the `encode` function with:

```swift
    /// Returns the JSON to print, or `nil` when the hook must print nothing.
    ///
    /// `emitDecisions: false` is the observer build's guarantee. It short-circuits
    /// before any other consideration, so no decision — not even a malformed one —
    /// can reach Claude Code. That is a property of this function rather than of
    /// the policy engine's correctness, which is why it is checked exhaustively.
    public static func encode(
        _ decision: Decision, for kind: HookEventKind, emitDecisions: Bool = true
    ) throws -> String? {
        guard emitDecisions else { return nil }
        guard kind == .preToolUse else { return nil }
        guard let permission = decision.permission else { return nil }

        switch permission {
        case .defer:
            return nil
        case .deny:
            throw HookOutputError.denyIsNeverEmitted
        case .allow:
            break
        }

        let encoder = JSONEncoder()
        // Sorted keys keep the output stable so it can be asserted on directly.
        // No .prettyPrinted: the payload must stay on one line.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let data = try encoder.encode(Envelope(
            hookSpecificOutput: PreToolUseOutput(
                permissionDecision: permission.rawValue,
                permissionDecisionReason: decision.reason)))

        return String(decoding: data, as: UTF8.self)
    }
```

In `Sources/NavigatorCore/Policy/PolicyConfig.swift`, add the property, its initialiser parameter, and assignment:

```swift
    /// Whether decisions may reach Claude Code at all.
    ///
    /// Off for the observer build. The engine still computes and logs the real
    /// verdict, so the log shows exactly what would have happened — which is how
    /// this gets turned on with evidence rather than optimism.
    public var emitDecisions: Bool
```

Add `emitDecisions: Bool = false` as the last initialiser parameter and `self.emitDecisions = emitDecisions` in the body.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS — all existing tests plus 4 new

- [ ] **Step 5: Commit**

```bash
git add Sources/NavigatorCore Tests/NavigatorCoreTests/HookOutputTests.swift
git commit -m "feat: wire gate so the observer build cannot affect Claude Code

Checked over every tier x permission x event kind: with the gate shut,
nothing reaches the wire. A property of the encoder, not of the engine
being right."
```

---

### Task 2: Wire protocol

**Files:**
- Create: `Sources/NavigatorCore/Protocol/NavigatorMessage.swift`
- Test: `Tests/NavigatorCoreTests/NavigatorMessageTests.swift`

**Interfaces:**
- Consumes: `HookEvent`, `StampedEvent`.
- Produces: `NavigatorRequest { event: HookEvent, at: Date, protocolVersion: Int }` with `static let currentVersion = 1`; `NavigatorResponse { output: String?, protocolVersion: Int }` and `static let empty: NavigatorResponse`; `NavigatorMessage.encodeLine(_:) throws -> Data` and `NavigatorMessage.decode<T: Decodable>(_:as:) throws -> T`.

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorCoreTests/NavigatorMessageTests.swift`:

```swift
import Foundation
import Testing
@testable import NavigatorCore

@Suite struct NavigatorMessaging {
    let event = HookEvent(
        kind: .preToolUse, sessionID: "s1", cwd: "/p",
        toolName: "Bash", toolInput: ["command": .string("swift build")])

    @Test func requestRoundTrips() throws {
        let request = NavigatorRequest(event: event, at: Date(timeIntervalSince1970: 1000))
        let line = try NavigatorMessage.encodeLine(request)
        let back: NavigatorRequest = try NavigatorMessage.decode(line, as: NavigatorRequest.self)

        #expect(back.event == event)
        #expect(back.at == Date(timeIntervalSince1970: 1000))
        #expect(back.protocolVersion == NavigatorRequest.currentVersion)
    }

    @Test func encodedLineEndsWithExactlyOneNewline() throws {
        let request = NavigatorRequest(event: event, at: Date(timeIntervalSince1970: 1000))
        let line = try NavigatorMessage.encodeLine(request)
        let text = String(decoding: line, as: UTF8.self)

        #expect(text.hasSuffix("\n"))
        #expect(text.dropLast().contains("\n") == false, "payload must stay on one line")
    }

    @Test func responseRoundTrips() throws {
        let response = NavigatorResponse(output: "{\"a\":1}")
        let line = try NavigatorMessage.encodeLine(response)
        let back: NavigatorResponse = try NavigatorMessage.decode(line, as: NavigatorResponse.self)
        #expect(back.output == "{\"a\":1}")
    }

    @Test func emptyResponseCarriesNoOutput() throws {
        let line = try NavigatorMessage.encodeLine(NavigatorResponse.empty)
        let back: NavigatorResponse = try NavigatorMessage.decode(line, as: NavigatorResponse.self)
        #expect(back.output == nil)
    }

    @Test func decodingToleratesTrailingNewline() throws {
        let request = NavigatorRequest(event: event, at: Date(timeIntervalSince1970: 1000))
        var line = try NavigatorMessage.encodeLine(request)
        line.append(contentsOf: [0x0a])
        let back: NavigatorRequest = try NavigatorMessage.decode(line, as: NavigatorRequest.self)
        #expect(back.event.sessionID == "s1")
    }

    @Test func eventWithEmbeddedNewlinesStillEncodesToOneLine() throws {
        // Bash commands routinely contain newlines. If they leaked into the
        // framing, the daemon would read half a message.
        let multiline = HookEvent(
            kind: .preToolUse, sessionID: "s1", cwd: "/p", toolName: "Bash",
            toolInput: ["command": .string("git commit -m \"a\n\nb\"")])
        let line = try NavigatorMessage.encodeLine(
            NavigatorRequest(event: multiline, at: Date(timeIntervalSince1970: 0)))
        let text = String(decoding: line, as: UTF8.self)

        #expect(text.dropLast().contains("\n") == false)

        let back: NavigatorRequest = try NavigatorMessage.decode(line, as: NavigatorRequest.self)
        #expect(back.event.command == "git commit -m \"a\n\nb\"")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NavigatorMessaging`
Expected: FAIL — `cannot find 'NavigatorRequest' in scope`

- [ ] **Step 3: Write the protocol types**

Create `Sources/NavigatorCore/Protocol/NavigatorMessage.swift`:

```swift
import Foundation

/// One hook event on its way to the daemon.
public struct NavigatorRequest: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public let protocolVersion: Int
    public let event: HookEvent
    /// Stamped by the hook, not the daemon: it is closer to when the event
    /// actually happened, and it keeps the daemon's engine free of clock reads.
    public let at: Date

    public init(event: HookEvent, at: Date, protocolVersion: Int = currentVersion) {
        self.event = event
        self.at = at
        self.protocolVersion = protocolVersion
    }

    public var stamped: StampedEvent { StampedEvent(event: event, at: at) }
}

/// What the hook should print on stdout. `nil` means print nothing.
public struct NavigatorResponse: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let output: String?

    public init(output: String?, protocolVersion: Int = NavigatorRequest.currentVersion) {
        self.output = output
        self.protocolVersion = protocolVersion
    }

    public static let empty = NavigatorResponse(output: nil)
}

/// Newline-delimited JSON, one message per line.
///
/// JSON escaping guarantees no raw newline survives inside a payload, so a bare
/// `\n` is a safe frame terminator even for bash commands full of them.
public enum NavigatorMessage {
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        var data = try encoder.encode(value)
        data.append(0x0a)
        return data
    }

    public static func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        // Trim trailing newlines only; JSONDecoder already tolerates leading
        // whitespace. Written as a loop rather than chained drop/reversed
        // because `DropWhileSequence` is only a Sequence and has no `reversed()`.
        var bytes = Data(data)
        while bytes.last == 0x0a { bytes.removeLast() }
        return try decoder.decode(type, from: bytes)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter NavigatorMessaging`
Expected: PASS — 6 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/NavigatorCore/Protocol Tests/NavigatorCoreTests/NavigatorMessageTests.swift
git commit -m "feat: newline-delimited wire protocol for hook and daemon

JSON escaping means no raw newline survives a payload, so a bare \\n is a
safe frame terminator even for bash commands that are full of them."
```

---

### Task 3: Unix socket layer

**Files:**
- Create: `Sources/NavigatorIO/UnixSocket.swift`
- Modify: `Package.swift`
- Test: `Tests/NavigatorIOTests/UnixSocketTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `SocketError` (`.pathTooLong`, `.systemCall(String, Int32)`, `.closed`, `.timedOut`); `UnixSocket` with `static func listen(at: String) throws -> UnixSocket`, `static func connect(to: String, timeout: TimeInterval) throws -> UnixSocket`, `func accept() throws -> UnixSocket`, `func readLine(deadline: TimeInterval) throws -> Data`, `func write(_ data: Data) throws`, `func close()`, `var fileDescriptor: Int32`.

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorIOTests/UnixSocketTests.swift`:

```swift
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
        var received: Data?

        Thread.detachNewThread {
            let conn = try? server.accept()
            received = try? conn?.readLine(deadline: 2)
            try? conn?.write(Data("world\n".utf8))
            conn?.close()
            done.signal()
        }

        let client = try UnixSocket.connect(to: path, timeout: 2)
        try client.write(sent)
        let reply = try client.readLine(deadline: 2)
        client.close()
        _ = done.wait(timeout: .now() + 5)

        #expect(received == sent)
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
}
```

- [ ] **Step 2: Add the target and run the test to verify it fails**

In `Package.swift`, add to `targets:` (before the test targets):

```swift
        .target(name: "NavigatorIO", dependencies: ["NavigatorCore"]),
```

and add a test target:

```swift
        .testTarget(name: "NavigatorIOTests", dependencies: ["NavigatorIO"]),
```

Run: `swift test --filter UnixSocketBehavior`
Expected: FAIL — `cannot find 'UnixSocket' in scope`

- [ ] **Step 3: Write the socket wrapper**

Create `Sources/NavigatorIO/UnixSocket.swift`:

```swift
import Darwin
import Foundation

public enum SocketError: Error, Equatable {
    case pathTooLong
    case systemCall(String, Int32)
    case closed
    case timedOut
}

/// A thin blocking wrapper over an `AF_UNIX` stream socket.
///
/// Deliberately blocking with explicit deadlines rather than async: the hook is
/// a short-lived process that does exactly one exchange and exits, and the
/// daemon's accept loop runs on its own thread. Introducing async here would add
/// an executor to a process whose whole job is to start, talk, and die.
public final class UnixSocket: @unchecked Sendable {
    public let fileDescriptor: Int32
    private var buffer = Data()
    private var isClosed = false

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit { close() }

    // MARK: - Address

    private static func address(for path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw SocketError.pathTooLong }

        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    private static func withSockAddr<R>(
        _ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R
    ) -> R {
        withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                body(sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    // MARK: - Lifecycle

    public static func listen(at path: String) throws -> UnixSocket {
        var addr = try address(for: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.systemCall("socket", errno) }

        // A socket file left by a killed daemon would make bind fail with
        // EADDRINUSE forever. Removing it is safe: a live daemon holds the
        // socket, not the directory entry, and a second daemon fails at listen.
        unlink(path)

        let bound = withSockAddr(&addr) { sa, len in Darwin.bind(fd, sa, len) }
        guard bound == 0 else {
            Darwin.close(fd)
            throw SocketError.systemCall("bind", errno)
        }
        guard Darwin.listen(fd, 64) == 0 else {
            Darwin.close(fd)
            throw SocketError.systemCall("listen", errno)
        }
        return UnixSocket(fileDescriptor: fd)
    }

    public static func connect(to path: String, timeout: TimeInterval) throws -> UnixSocket {
        var addr = try address(for: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.systemCall("socket", errno) }

        var tv = timeval(seconds: timeout)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let connected = withSockAddr(&addr) { sa, len in Darwin.connect(fd, sa, len) }
        guard connected == 0 else {
            let saved = errno
            Darwin.close(fd)
            // ENOENT / ECONNREFUSED here is the ordinary "daemon not running"
            // case. The caller treats it as success, not as an error.
            throw SocketError.systemCall("connect", saved)
        }
        return UnixSocket(fileDescriptor: fd)
    }

    public func accept() throws -> UnixSocket {
        let fd = Darwin.accept(fileDescriptor, nil, nil)
        guard fd >= 0 else { throw SocketError.systemCall("accept", errno) }
        return UnixSocket(fileDescriptor: fd)
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fileDescriptor)
    }

    // MARK: - I/O

    public func write(_ data: Data) throws {
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { raw in
                Darwin.write(fileDescriptor, raw.baseAddress, raw.count)
            }
            if written > 0 {
                remaining = remaining.dropFirst(written)
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                throw SocketError.systemCall("write", errno)
            }
        }
    }

    /// Reads until the first newline, inclusive.
    ///
    /// Enforces its own deadline instead of relying on `SO_RCVTIMEO` alone,
    /// because a socket that dribbles one byte at a time would reset that
    /// timeout on every byte and never actually expire.
    public func readLine(deadline: TimeInterval) throws -> Data {
        let expiry = Date().addingTimeInterval(deadline)

        while true {
            if let index = buffer.firstIndex(of: 0x0a) {
                // Re-base both slices with `Data(...)`. Slicing a Data preserves
                // the parent's indices, so a sliced buffer whose startIndex is
                // no longer 0 will break the next `firstIndex` comparison.
                let line = Data(buffer[buffer.startIndex...index])
                buffer = Data(buffer[buffer.index(after: index)...])
                return line
            }

            let remaining = expiry.timeIntervalSinceNow
            guard remaining > 0 else { throw SocketError.timedOut }

            var tv = timeval(seconds: remaining)
            setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO,
                       &tv, socklen_t(MemoryLayout<timeval>.size))

            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fileDescriptor, &chunk, chunk.count)

            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
            } else if count == 0 {
                throw SocketError.closed
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                throw SocketError.timedOut
            } else {
                throw SocketError.systemCall("read", errno)
            }
        }
    }
}

extension timeval {
    init(seconds: TimeInterval) {
        let whole = max(0, seconds)
        self.init(tv_sec: Int(whole), tv_usec: Int32((whole - Double(Int(whole))) * 1_000_000))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter UnixSocketBehavior`
Expected: PASS — 6 tests

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/NavigatorIO Tests/NavigatorIOTests
git commit -m "feat: blocking AF_UNIX socket wrapper with real deadlines

readLine enforces its own expiry rather than trusting SO_RCVTIMEO, which
a socket dribbling one byte at a time would reset forever."
```

---

### Task 4: Decision log

**Files:**
- Create: `Sources/NavigatorIO/DecisionLog.swift`
- Test: `Tests/NavigatorIOTests/DecisionLogTests.swift`

**Interfaces:**
- Consumes: `DecisionRecord` from `NavigatorCore`.
- Produces: `DecisionLog` with `init(directory: URL)`, `func append(_ record: DecisionRecord, on day: Date) throws`, `func path(for day: Date) -> URL`, `static func replayable(from: URL) throws -> [DecisionRecord]`.

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorIOTests/DecisionLogTests.swift`:

```swift
import Foundation
import Testing
@testable import NavigatorCore
@testable import NavigatorIO

@Suite struct DecisionLogging {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("navlog-\(UUID().uuidString)")
        return url
    }

    private func record(_ session: String, at: Date) -> DecisionRecord {
        DecisionRecord(
            at: at, sessionID: session, kind: .preToolUse, toolName: "Bash",
            reversibility: "reversible", route: "on-route",
            tierAssigned: .silent, delivered: .silent,
            suppressedBecause: nil, permission: .allow, reason: "reversible, on route")
    }

    @Test func createsDirectoryAndWritesOneLinePerRecord() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = DecisionLog(directory: dir)
        let day = Date(timeIntervalSince1970: 1_770_000_000)
        try log.append(record("s1", at: day), on: day)
        try log.append(record("s2", at: day), on: day)

        let text = try String(contentsOf: log.path(for: day), encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
    }

    @Test func fileNameIsDatedForRotation() {
        let log = DecisionLog(directory: URL(fileURLWithPath: "/tmp/x"))
        let day = Date(timeIntervalSince1970: 1_770_000_000)  // 2026-02-02 UTC
        #expect(log.path(for: day).lastPathComponent == "decisions-2026-02-02.jsonl")
    }

    @Test func separateDaysGoToSeparateFiles() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = DecisionLog(directory: dir)
        let dayOne = Date(timeIntervalSince1970: 1_770_000_000)
        let dayTwo = dayOne.addingTimeInterval(86_400)
        try log.append(record("s1", at: dayOne), on: dayOne)
        try log.append(record("s2", at: dayTwo), on: dayTwo)

        #expect(log.path(for: dayOne) != log.path(for: dayTwo))
        #expect(FileManager.default.fileExists(atPath: log.path(for: dayOne).path))
        #expect(FileManager.default.fileExists(atPath: log.path(for: dayTwo).path))
    }

    @Test func appendsRatherThanTruncating() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let day = Date(timeIntervalSince1970: 1_770_000_000)
        // A fresh DecisionLog each time simulates a daemon restart mid-day.
        try DecisionLog(directory: dir).append(record("s1", at: day), on: day)
        try DecisionLog(directory: dir).append(record("s2", at: day), on: day)

        let text = try String(contentsOf: DecisionLog(directory: dir).path(for: day), encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)
    }

    @Test func recordsSurviveARoundTrip() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = DecisionLog(directory: dir)
        let day = Date(timeIntervalSince1970: 1_770_000_000)
        try log.append(record("s1", at: day), on: day)

        let back = try DecisionLog.replayable(from: log.path(for: day))
        #expect(back.count == 1)
        #expect(back.first?.sessionID == "s1")
        #expect(back.first?.reason == "reversible, on route")
    }

    @Test func reasonWithNewlinesStaysOnOneLine() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = DecisionLog(directory: dir)
        let day = Date(timeIntervalSince1970: 1_770_000_000)
        let nasty = DecisionRecord(
            at: day, sessionID: "s1", kind: .preToolUse, toolName: "Bash",
            reversibility: "reversible", route: "on-route",
            tierAssigned: .silent, delivered: .silent, suppressedBecause: nil,
            permission: .allow, reason: "ran:\ngit commit -m \"x\ny\"")
        try log.append(nasty, on: day)

        let text = try String(contentsOf: log.path(for: day), encoding: .utf8)
        #expect(text.split(separator: "\n").count == 1)

        let back = try DecisionLog.replayable(from: log.path(for: day))
        #expect(back.first?.reason == "ran:\ngit commit -m \"x\ny\"")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DecisionLogging`
Expected: FAIL — `cannot find 'DecisionLog' in scope`

- [ ] **Step 3: Write the log**

Create `Sources/NavigatorIO/DecisionLog.swift`:

```swift
import Foundation
import NavigatorCore

/// Append-only JSONL, one file per day.
///
/// This is the observer build's actual product. The budget and thresholds are
/// guesses; this file is how they get replaced with numbers, so it is written
/// with `O_APPEND` on every record rather than buffered — a daemon killed
/// mid-session must not lose the day.
public struct DecisionLog: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func path(for day: Date) -> URL {
        directory.appendingPathComponent("decisions-\(Self.stamp(day)).jsonl")
    }

    public func append(_ record: DecisionRecord, on day: Date) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(record)
        line.append(0x0a)

        let url = path(for: day)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    public static func replayable(from url: URL) throws -> [DecisionRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try decoder.decode(DecisionRecord.self, from: Data($0.utf8)) }
    }

    private static func stamp(_ day: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DecisionLogging`
Expected: PASS — 6 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/NavigatorIO/DecisionLog.swift Tests/NavigatorIOTests/DecisionLogTests.swift
git commit -m "feat: append-only daily decision log

Written with an explicit seek-to-end per record rather than buffered: a
daemon killed mid-session must not take the day's data with it."
```

---

### Task 5: The server

**Files:**
- Create: `Sources/NavigatorIO/NavigatorServer.swift`
- Test: `Tests/NavigatorIOTests/NavigatorServerTests.swift`

**Interfaces:**
- Consumes: `UnixSocket`, `DecisionLog`, `PolicyEngine`, `PolicyConfig`, `NavigatorRequest`, `NavigatorResponse`, `NavigatorMessage`, `HookOutput`.
- Produces: `NavigatorServer` with `init(socketPath: String, log: DecisionLog?, config: PolicyConfig, startingAt: Date)`, `func start() throws`, `func stop()`, `func handleOnce(_ connection: UnixSocket)`, `var decisionCount: Int`.

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorIOTests/NavigatorServerTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NavigatorServing`
Expected: FAIL — `cannot find 'NavigatorServer' in scope`

- [ ] **Step 3: Write the server**

Create `Sources/NavigatorIO/NavigatorServer.swift`:

```swift
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

    public func start() throws {
        let listener = try UnixSocket.listen(at: socketPath)
        self.listener = listener
        running = true

        Thread.detachNewThread { [weak self] in
            while self?.running == true {
                guard let connection = try? listener.accept() else {
                    // A closed listener during stop() lands here; so does a
                    // transient accept failure. Neither should end the loop
                    // unless we are actually shutting down.
                    if self?.running == true { continue } else { return }
                }
                self?.workers.async { self?.handleOnce(connection) }
            }
        }
    }

    public func stop() {
        running = false
        listener?.close()
        listener = nil
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
            _ = try? connection.write(
                (try? NavigatorMessage.encodeLine(NavigatorResponse.empty)) ?? Data("{}\n".utf8))
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
        _ = try? connection.write(
            try NavigatorMessage.encodeLine(NavigatorResponse(output: output ?? nil)))

        if let log, let record {
            logging.async { try? log.append(record, on: record.at) }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter NavigatorServing`
Expected: PASS — 6 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/NavigatorIO/NavigatorServer.swift Tests/NavigatorIOTests/NavigatorServerTests.swift
git commit -m "feat: navigator server, responds before it logs

Raw accept thread plus a lock rather than actors: parking a blocking
accept inside the cooperative pool starves it."
```

---

### Task 6: The hook binary

**Files:**
- Create: `Sources/navigator-hook/main.swift`
- Modify: `Package.swift`
- Test: `Tests/NavigatorIOTests/HookBinaryTests.swift`

**Interfaces:**
- Consumes: `UnixSocket`, `NavigatorMessage`, `NavigatorRequest`, `NavigatorResponse`, `HookEvent`.
- Produces: executable `navigator-hook`. Reads env `NAVIGATOR_SOCKET` (default `~/.claude/navigator.sock`) and `NAVIGATOR_DEADLINE_MS` (default 250).

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorIOTests/HookBinaryTests.swift`:

```swift
import Foundation
import Testing
@testable import NavigatorCore
@testable import NavigatorIO

@Suite struct HookBinaryContract {
    /// Locates the built `navigator-hook` next to the test bundle.
    private var hookURL: URL {
        var url = URL(fileURLWithPath: Bundle.main.bundlePath)
        while url.pathComponents.count > 1 && !FileManager.default.fileExists(
            atPath: url.appendingPathComponent("navigator-hook").path) {
            url = url.deletingLastPathComponent()
        }
        return url.appendingPathComponent("navigator-hook")
    }

    private struct Result { let status: Int32; let stdout: String; let stderr: String }

    private func run(stdin: String, socket: String, deadlineMS: Int = 250) throws -> Result {
        let process = Process()
        process.executableURL = hookURL
        process.environment = [
            "NAVIGATOR_SOCKET": socket,
            "NAVIGATOR_DEADLINE_MS": String(deadlineMS),
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
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

        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self))
    }

    private let samplePayload = """
    {"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/p","tool_name":"Bash","tool_input":{"command":"swift build"}}
    """

    @Test func exitsZeroAndSilentWhenNoDaemonIsRunning() throws {
        // The steady state with the daemon down. Must be indistinguishable from
        // having no hook installed at all.
        let result = try run(stdin: samplePayload, socket: "/tmp/definitely-absent.sock")
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
    }

    @Test func neverExitsTwoOnMalformedInput() throws {
        // Exit 2 BLOCKS the tool call. No input may ever produce it.
        for junk in ["", "not json", "{", "{\"hook_event_name\":\"Nope\"}", "null"] {
            let result = try run(stdin: junk, socket: "/tmp/definitely-absent.sock")
            #expect(result.status != 2, "exit 2 on input: \(junk)")
            #expect(result.status == 0, "expected 0, got \(result.status) on: \(junk)")
        }
    }

    @Test func printsWhateverTheDaemonReturns() throws {
        let path = "/tmp/navhook-\(UInt32.random(in: 0..<UInt32.max)).sock"
        var config = PolicyConfig.default
        config.emitDecisions = true
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
}
```

- [ ] **Step 2: Add the executable and run the test to verify it fails**

In `Package.swift`, add to `targets:`:

```swift
        .executableTarget(name: "navigator-hook", dependencies: ["NavigatorCore", "NavigatorIO"]),
```

Run: `swift test --filter HookBinaryContract`
Expected: FAIL — the executable does not exist yet, so `hookURL` will not resolve and the process launch throws.

- [ ] **Step 3: Write the hook**

Create `Sources/navigator-hook/main.swift`:

```swift
import Darwin
import Foundation
import NavigatorCore
import NavigatorIO

// The single most important property of this program: it exits 0 on every path.
//
// Claude Code treats exit code 2 as a *blocking* error that stops the tool call,
// and any other non-zero as a non-blocking error. Since a notification tool must
// never be able to stop your work, there is exactly one exit call in this file.
func finish(printing output: String?) -> Never {
    if let output, !output.isEmpty {
        FileHandle.standardOutput.write(Data((output + "\n").utf8))
    }
    exit(0)
}

let environment = ProcessInfo.processInfo.environment

let socketPath = environment["NAVIGATOR_SOCKET"]
    ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude/navigator.sock")

let deadline = TimeInterval(environment["NAVIGATOR_DEADLINE_MS"].flatMap(Int.init) ?? 250) / 1000

let input = FileHandle.standardInput.readDataToEndOfFile()

guard let event = try? JSONDecoder().decode(HookEvent.self, from: input) else {
    // Unrecognised or unparseable payload — including event kinds this build
    // does not model. Say nothing and get out of the way.
    finish(printing: nil)
}

let request = NavigatorRequest(event: event, at: Date())

guard let line = try? NavigatorMessage.encodeLine(request) else {
    finish(printing: nil)
}

// Connect timeout is tight on purpose: for AF_UNIX this either succeeds
// immediately or fails immediately, and "no daemon" is the expected steady state
// rather than an error worth waiting on.
guard let socket = try? UnixSocket.connect(to: socketPath, timeout: 0.05) else {
    finish(printing: nil)
}
defer { socket.close() }

guard (try? socket.write(line)) != nil,
      let reply = try? socket.readLine(deadline: deadline),
      let response = try? NavigatorMessage.decode(reply, as: NavigatorResponse.self)
else {
    // Wedged or dead daemon. The hook enforces its own deadline rather than
    // trusting the daemon or Claude Code's much longer hook timeout.
    finish(printing: nil)
}

finish(printing: response.output)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift build && swift test --filter HookBinaryContract`
Expected: PASS — 5 tests

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/navigator-hook Tests/NavigatorIOTests/HookBinaryTests.swift
git commit -m "feat: hook binary that can never block a tool call

Exactly one exit call in the file, and it is exit 0. Claude Code reads
exit 2 as a blocking error, so no input may be able to produce one."
```

---

### Task 7: The daemon executable and installer

**Files:**
- Create: `Sources/navigator/main.swift`
- Create: `Sources/NavigatorIO/HookInstaller.swift`
- Modify: `Package.swift`
- Test: `Tests/NavigatorIOTests/HookInstallerTests.swift`

**Interfaces:**
- Consumes: `NavigatorServer`, `DecisionLog`.
- Produces: executable `navigator` with subcommands `run`, `install`, `status`; `HookInstaller` with `static func configuration(hookPath: String, timeoutSeconds: Int) -> [String: Any]`, `static func merged(into: [String: Any], hookPath: String, timeoutSeconds: Int) -> [String: Any]`, `static let observedEvents: [String]`.

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorIOTests/HookInstallerTests.swift`:

```swift
import Foundation
import Testing
@testable import NavigatorIO

@Suite struct HookInstalling {
    @Test func configuresEveryObservedEvent() {
        let config = HookInstaller.configuration(hookPath: "/x/navigator-hook", timeoutSeconds: 5)
        let hooks = config["hooks"] as? [String: Any]

        for event in HookInstaller.observedEvents {
            #expect(hooks?[event] != nil, "missing \(event)")
        }
    }

    @Test func setsAnExplicitShortTimeout() throws {
        // Claude Code's default for command hooks is 600 seconds. Inheriting
        // that would let a wedged daemon stall a session for ten minutes.
        let config = HookInstaller.configuration(hookPath: "/x/navigator-hook", timeoutSeconds: 5)
        let hooks = try #require(config["hooks"] as? [String: Any])
        let preToolUse = try #require(hooks["PreToolUse"] as? [[String: Any]])
        let entries = try #require(preToolUse.first?["hooks"] as? [[String: Any]])

        #expect(entries.first?["timeout"] as? Int == 5)
        #expect(entries.first?["type"] as? String == "command")
        #expect(entries.first?["command"] as? String == "/x/navigator-hook")
    }

    @Test func omitsMatcherSoEveryToolIsObserved() throws {
        let config = HookInstaller.configuration(hookPath: "/x/h", timeoutSeconds: 5)
        let hooks = try #require(config["hooks"] as? [String: Any])
        let preToolUse = try #require(hooks["PreToolUse"] as? [[String: Any]])
        // An omitted matcher matches all tools. Narrowing it would blind the
        // decision log to exactly the routine calls we need to count.
        #expect(preToolUse.first?["matcher"] == nil)
    }

    @Test func preservesUnrelatedExistingSettings() throws {
        let existing: [String: Any] = [
            "theme": "dark-ansi",
            "enabledPlugins": ["some-plugin": true],
        ]
        let merged = HookInstaller.merged(
            into: existing, hookPath: "/x/h", timeoutSeconds: 5)

        #expect(merged["theme"] as? String == "dark-ansi")
        #expect(merged["enabledPlugins"] != nil)
        #expect(merged["hooks"] != nil)
    }

    @Test func preservesForeignHooksOnTheSameEvent() throws {
        let existing: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["hooks": [["type": "command", "command": "/other/tool"]]]
                ]
            ]
        ]
        let merged = HookInstaller.merged(into: existing, hookPath: "/x/h", timeoutSeconds: 5)
        let hooks = try #require(merged["hooks"] as? [String: Any])
        let preToolUse = try #require(hooks["PreToolUse"] as? [[String: Any]])

        let commands = preToolUse
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }

        #expect(commands.contains("/other/tool"), "clobbered someone else's hook")
        #expect(commands.contains("/x/h"))
    }

    @Test func isIdempotent() throws {
        let once = HookInstaller.merged(into: [:], hookPath: "/x/h", timeoutSeconds: 5)
        let twice = HookInstaller.merged(into: once, hookPath: "/x/h", timeoutSeconds: 5)

        let hooks = try #require(twice["hooks"] as? [String: Any])
        let preToolUse = try #require(hooks["PreToolUse"] as? [[String: Any]])
        let commands = preToolUse
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }
            .filter { $0 == "/x/h" }

        #expect(commands.count == 1, "installed twice")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HookInstalling`
Expected: FAIL — `cannot find 'HookInstaller' in scope`

- [ ] **Step 3: Write the installer**

Create `Sources/NavigatorIO/HookInstaller.swift`:

```swift
import Foundation

/// Builds the `hooks` block for `~/.claude/settings.json`.
///
/// Produces the configuration but never writes it — `navigator install` prints
/// it and applies only with `--apply`. Editing a user's Claude Code settings
/// behind their back is not something a notification daemon should do quietly.
public enum HookInstaller {
    /// Every event the engine models. `PreToolUse` carries the decisions;
    /// the rest are what make the log a picture of the day rather than a list
    /// of tool calls.
    public static let observedEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit",
        "PreToolUse", "PostToolUseFailure",
        "Notification", "Elicitation",
        "Stop", "StopFailure", "SubagentStop",
        "TaskCompleted", "TeammateIdle",
    ]

    public static func configuration(
        hookPath: String, timeoutSeconds: Int
    ) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in observedEvents {
            // No `matcher` key: omitted means every tool, and a narrower
            // matcher would hide the routine calls the silence rate is made of.
            hooks[event] = [["hooks": [entry(hookPath: hookPath, timeout: timeoutSeconds)]]]
        }
        return ["hooks": hooks]
    }

    public static func merged(
        into existing: [String: Any], hookPath: String, timeoutSeconds: Int
    ) -> [String: Any] {
        var result = existing
        var hooks = (existing["hooks"] as? [String: Any]) ?? [:]

        for event in observedEvents {
            var groups = (hooks[event] as? [[String: Any]]) ?? []

            // Drop any previous install of *this* hook, leave everything else.
            groups = groups.compactMap { group in
                guard var entries = group["hooks"] as? [[String: Any]] else { return group }
                entries.removeAll { $0["command"] as? String == hookPath }
                if entries.isEmpty { return nil }
                var updated = group
                updated["hooks"] = entries
                return updated
            }

            groups.append(["hooks": [entry(hookPath: hookPath, timeout: timeoutSeconds)]])
            hooks[event] = groups
        }

        result["hooks"] = hooks
        return result
    }

    private static func entry(hookPath: String, timeout: Int) -> [String: Any] {
        // The explicit timeout matters: the default for command hooks is 600
        // seconds, which would let a wedged daemon stall a session for ten
        // minutes before Claude Code gave up on it.
        ["type": "command", "command": hookPath, "timeout": timeout]
    }
}
```

- [ ] **Step 4: Write the daemon executable**

In `Package.swift`, add:

```swift
        .executableTarget(name: "navigator", dependencies: ["NavigatorCore", "NavigatorIO"]),
```

Create `Sources/navigator/main.swift`:

```swift
import Darwin
import Foundation
import NavigatorCore
import NavigatorIO

let home = NSHomeDirectory() as NSString
let defaultSocket = home.appendingPathComponent(".claude/navigator.sock")
let defaultLogDir = URL(fileURLWithPath: home.appendingPathComponent(".claude/navigator"))
let settingsPath = home.appendingPathComponent(".claude/settings.json")

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: navigator <command>

      run                 start the daemon in the foreground
      install [--apply]   print the hook configuration; write it with --apply
      status              report whether a daemon is listening

    The observer build never returns a decision to Claude Code. Sessions behave
    exactly as they would with no hook installed.

    """.utf8))
    exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { usage() }

switch arguments[1] {

case "run":
    let socketPath = ProcessInfo.processInfo.environment["NAVIGATOR_SOCKET"] ?? defaultSocket
    let server = NavigatorServer(
        socketPath: socketPath,
        log: DecisionLog(directory: defaultLogDir),
        config: .default,
        startingAt: Date())

    do {
        try server.start()
    } catch {
        FileHandle.standardError.write(Data("cannot listen on \(socketPath): \(error)\n".utf8))
        exit(1)
    }

    print("navigator listening on \(socketPath)")
    print("logging to \(defaultLogDir.path)")
    print("wire gate CLOSED — no decisions are returned to Claude Code")

    signal(SIGINT) { _ in exit(0) }
    signal(SIGTERM) { _ in exit(0) }
    dispatchMain()

case "install":
    let hookPath = (Bundle.main.bundlePath as NSString)
        .deletingLastPathComponent + "/navigator-hook"

    let existing = (try? Data(contentsOf: URL(fileURLWithPath: settingsPath)))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

    let merged = HookInstaller.merged(
        into: existing, hookPath: hookPath, timeoutSeconds: 5)

    let rendered = try JSONSerialization.data(
        withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])

    guard arguments.contains("--apply") else {
        print("Would write to \(settingsPath):\n")
        print(String(decoding: rendered, as: UTF8.self))
        print("\nRe-run with --apply to write it.")
        exit(0)
    }

    // Back up before touching a file the user's whole CLI depends on.
    if FileManager.default.fileExists(atPath: settingsPath) {
        try? FileManager.default.copyItem(
            atPath: settingsPath, toPath: settingsPath + ".navigator-backup")
    }
    try rendered.write(to: URL(fileURLWithPath: settingsPath))
    print("Installed. Backup at \(settingsPath).navigator-backup")

case "status":
    let socketPath = ProcessInfo.processInfo.environment["NAVIGATOR_SOCKET"] ?? defaultSocket
    if let socket = try? UnixSocket.connect(to: socketPath, timeout: 0.1) {
        socket.close()
        print("daemon listening on \(socketPath)")
    } else {
        // Not an error: "no daemon" is a supported state, and hooks degrade to
        // silence when it is true.
        print("no daemon on \(socketPath) — sessions run unaffected")
    }

default:
    usage()
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift build && swift test --filter HookInstalling`
Expected: PASS — 6 tests

Run: `swift run navigator install`
Expected: prints a merged settings blob including your existing `theme` and `enabledPlugins`, and does **not** write anything.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/navigator Sources/NavigatorIO/HookInstaller.swift Tests/NavigatorIOTests/HookInstallerTests.swift
git commit -m "feat: navigator daemon with print-only installer

install prints by default and writes only with --apply, taking a backup
first. Silently rewriting the settings file the whole CLI depends on is
not a notification daemon's call to make."
```

---

### Task 8: End-to-end proof and latency measurement

**Files:**
- Create: `Tests/NavigatorIOTests/EndToEndTests.swift`
- Create: `Sources/NavigatorIO/HookLatency.swift`

**Interfaces:**
- Consumes: everything.
- Produces: `HookLatency.measure(socketPath:iterations:) -> (median: TimeInterval, p95: TimeInterval)`.

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorIOTests/EndToEndTests.swift`:

```swift
import Foundation
import Testing
@testable import NavigatorCore
@testable import NavigatorIO

@Suite struct EndToEnd {
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
            let client = try UnixSocket.connect(to: path, timeout: 2)
            defer { client.close() }
            let request = NavigatorRequest(
                event: event, at: day.addingTimeInterval(Double(i) * 10))
            try client.write(try NavigatorMessage.encodeLine(request))
            let reply = try client.readLine(deadline: 2)
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter EndToEnd`
Expected: FAIL — `cannot find 'HookLatency' in scope`

- [ ] **Step 3: Write the measurement helper**

Create `Sources/NavigatorIO/HookLatency.swift`:

```swift
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
            _ = try? socket.write(line)
            _ = try? socket.readLine(deadline: 1)
            socket.close()
            samples.append(Date().timeIntervalSince(start))
        }

        guard !samples.isEmpty else { return (0, 0) }
        samples.sort()
        return (samples[samples.count / 2], samples[min(samples.count - 1, samples.count * 95 / 100)])
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter EndToEnd`
Expected: PASS — 2 tests

- [ ] **Step 5: Run the whole suite and the harness on a real log**

Run: `swift build && swift test`
Expected: PASS — every suite

Then prove the loop closes, using the daemon's own output as the harness's input:

```bash
swift run navigator run &
sleep 1
echo '{"hook_event_name":"PreToolUse","session_id":"x","cwd":"'$PWD'","tool_name":"Bash","tool_input":{"command":"git push --force"}}' \
  | swift run navigator-hook
swift run navigator status
kill %1
```

Expected: the hook prints **nothing**, `status` reports a listening daemon, and `~/.claude/navigator/decisions-<today>.jsonl` gains a line whose `tierAssigned` is `decisionPoint` and whose `delivered` is `decisionPoint`.

- [ ] **Step 6: Commit**

```bash
git add Sources/NavigatorIO/HookLatency.swift Tests/NavigatorIOTests/EndToEndTests.swift
git commit -m "test: end-to-end observer proof and round-trip latency budget

Asserts the gate holds across every event kind and pins the daemon-side
round trip, which sits in front of every matched tool call."
```

---

## Known Gaps

Deliberately out of scope; each belongs to a later plan.

- **No audio.** No TTS, no earcons, no STT, no `MPRemoteCommandCenter`. The engine assigns tiers and the log records them; nothing is spoken.
- **No mute detection.** `PolicyEngine.setMuted` exists but nothing calls it. Focus/DND, full-screen, and microphone-in-use detection are the audio plan's job.
- **No menu bar item.** The daemon runs in the foreground; `navigator status` is the liveness check.
- **No launchd job.** Starting on login comes with the menu bar work.
- **The gate stays shut.** `emitDecisions` defaults to `false` and nothing flips it outside tests. Opening it is a decision to make against a week of real log data, not now.
- **`resolveQuestion` is never called.** Nothing blocks yet, so nothing needs resolving. The concurrency gate is exercised only by unit tests.
- **Single daemon assumed.** A second `navigator run` unlinks the first one's socket and steals the path. A lockfile belongs with the launchd work.

## Verification

```bash
swift build && swift test
```

Expected: every suite green, including `WireGate` — the exhaustive check that with `emitDecisions: false`, nothing any decision can produce reaches Claude Code. That suite is this build's central claim, and `HookBinaryContract.neverExitsTwoOnMalformedInput` is its companion: the hook cannot block a tool call no matter what it is fed.
