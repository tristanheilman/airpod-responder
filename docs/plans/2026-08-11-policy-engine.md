# Policy Engine Implementation Plan


**Goal:** Build `NavigatorCore` — the pure policy engine that decides what has earned the right to interrupt you — plus a replay harness that counts utterances over a recorded day of events.

**Architecture:** A single Swift package with no I/O in the policy path. Events and a timestamp go in; a tier decision, a permission verdict, and a log record come out. Every source of nondeterminism (the clock, mute state, session history) is passed in as data rather than read from the environment, so the whole engine is table-testable. The daemon, hook binary, and audio layer are separate plans and are deliberately absent here.

**Tech Stack:** Swift 6 (language mode v6, strict concurrency), Foundation, Swift Testing (`import Testing`), SwiftPM.

## Global Constraints

- **The policy engine is pure.** No filesystem access, no network, no `Date()`, no environment reads, no logging side effects anywhere in `Sources/NavigatorCore`. Time arrives as a parameter. A test that needs a clock constructs one.
- **Never widen the blast radius.** `permission == .allow` is legal only when reversibility is `.reversible` *and* route is `.onRoute`. Any other combination returns `.defer`.
- **Never auto-deny.** `PermissionDecision.deny` is not returned by the engine under any input. It exists in the enum only because the hook protocol defines it.
- **Uncertainty defers silently.** An unrecognized tool or command yields `.defer` with tier `.silent` — the normal on-screen prompt is the fallback, and it needs no narration.
- **Only one question is in flight.** A blocking decision point arriving while another is live returns `.defer` immediately. Never queue behind a live question.
- **Hard blocks are free.** Blocking speech bypasses the speech budget entirely. Everything else is rationed.
- **Every decision produces a `DecisionRecord`**, including suppressed ones and silent ones.
- All public types are `Sendable`. All enums with associated values are `Equatable`.
- Swift Testing only. Do not use XCTest.
- Package platform floor is `.macOS("14.0")`. The core is pure and must stay buildable without the daemon's macOS 26 dependencies.

---

### Task 1: Package scaffold and event model

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `Sources/NavigatorCore/Events/JSONValue.swift`
- Create: `Sources/NavigatorCore/Events/HookEvent.swift`
- Test: `Tests/NavigatorCoreTests/HookEventTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `JSONValue` (`.string`/`.number`/`.bool`/`.null`/`.array`/`.object`, with `stringValue: String?`); `HookEventKind: String` enum; `HookEvent` with fields `kind`, `sessionID`, `cwd`, `toolName: String?`, `toolInput: [String: JSONValue]?`, `message: String?`, `prompt: String?` and accessors `command`, `filePath`, `url`; `StampedEvent { event: HookEvent, at: Date }`.

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorCoreTests/HookEventTests.swift`:

```swift
import Foundation
import Testing
@testable import NavigatorCore

@Suite struct HookEventDecoding {
    @Test func decodesPreToolUseBashEvent() throws {
        let json = """
        {
          "hook_event_name": "PreToolUse",
          "session_id": "abc123",
          "cwd": "/Users/t/Projects/app",
          "tool_name": "Bash",
          "tool_input": { "command": "git status", "timeout": 5000 }
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(HookEvent.self, from: json)

        #expect(event.kind == .preToolUse)
        #expect(event.sessionID == "abc123")
        #expect(event.cwd == "/Users/t/Projects/app")
        #expect(event.toolName == "Bash")
        #expect(event.command == "git status")
    }

    @Test func decodesEventWithoutToolFields() throws {
        let json = """
        { "hook_event_name": "Stop", "session_id": "abc123", "cwd": "/tmp" }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(HookEvent.self, from: json)

        #expect(event.kind == .stop)
        #expect(event.toolName == nil)
        #expect(event.command == nil)
    }

    @Test func preservesEmbeddedQuotesAndNewlinesInCommands() throws {
        let json = """
        {
          "hook_event_name": "PreToolUse",
          "session_id": "s",
          "cwd": "/tmp",
          "tool_name": "Bash",
          "tool_input": { "command": "git commit -m \\"fix: the \\\\\\"thing\\\\\\"\\n\\nbody\\"" }
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(HookEvent.self, from: json)

        #expect(event.command == "git commit -m \"fix: the \\\"thing\\\"\n\nbody\"")
    }

    @Test func decodesNestedToolInput() throws {
        let json = """
        {
          "hook_event_name": "PreToolUse",
          "session_id": "s",
          "cwd": "/tmp",
          "tool_name": "Edit",
          "tool_input": { "file_path": "/tmp/a.swift", "edits": [ { "old": "a", "new": "b" } ] }
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(HookEvent.self, from: json)

        #expect(event.filePath == "/tmp/a.swift")
        if case .array(let edits)? = event.toolInput?["edits"] {
            #expect(edits.count == 1)
        } else {
            Issue.record("expected edits array")
        }
    }
}
```

- [ ] **Step 2: Create the package and run the test to verify it fails**

Create `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirPodResponder",
    platforms: [.macOS("14.0")],
    targets: [
        .target(name: "NavigatorCore"),
        .testTarget(name: "NavigatorCoreTests", dependencies: ["NavigatorCore"]),
    ]
)
```

Create `.gitignore`:

```
.build/
.swiftpm/
*.xcodeproj
.DS_Store
```

Run: `swift test`
Expected: FAIL — `cannot find 'HookEvent' in scope`

- [ ] **Step 3: Write JSONValue**

Create `Sources/NavigatorCore/Events/JSONValue.swift`:

```swift
import Foundation

/// A decoded JSON value of unknown shape.
///
/// Tool inputs are heterogeneous — `Bash` carries a command string, `Edit`
/// carries a path and an edit array — so they are decoded structurally rather
/// than into per-tool types. The engine only ever reads a handful of fields.
public enum JSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue {
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            // Must precede Double: JSONDecoder will not coerce `true` to a number,
            // but it will happily decode `1` as Bool on some paths.
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unrepresentable JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}
```

- [ ] **Step 4: Write HookEvent**

Create `Sources/NavigatorCore/Events/HookEvent.swift`:

```swift
import Foundation

public enum HookEventKind: String, Codable, Sendable, CaseIterable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUseFailure = "PostToolUseFailure"
    case notification = "Notification"
    case stop = "Stop"
    case stopFailure = "StopFailure"
    case subagentStop = "SubagentStop"
    case taskCompleted = "TaskCompleted"
    case teammateIdle = "TeammateIdle"
    case fileChanged = "FileChanged"
    case elicitation = "Elicitation"
}

public struct HookEvent: Codable, Sendable, Equatable {
    public let kind: HookEventKind
    public let sessionID: String
    public let cwd: String
    public let toolName: String?
    public let toolInput: [String: JSONValue]?
    public let message: String?
    public let prompt: String?

    enum CodingKeys: String, CodingKey {
        case kind = "hook_event_name"
        case sessionID = "session_id"
        case cwd
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case message
        case prompt
    }

    public init(
        kind: HookEventKind,
        sessionID: String,
        cwd: String,
        toolName: String? = nil,
        toolInput: [String: JSONValue]? = nil,
        message: String? = nil,
        prompt: String? = nil
    ) {
        self.kind = kind
        self.sessionID = sessionID
        self.cwd = cwd
        self.toolName = toolName
        self.toolInput = toolInput
        self.message = message
        self.prompt = prompt
    }
}

extension HookEvent {
    public var command: String? { toolInput?["command"]?.stringValue }
    public var filePath: String? { toolInput?["file_path"]?.stringValue }
    public var url: String? { toolInput?["url"]?.stringValue }
}

/// An event paired with the instant the daemon received it.
///
/// Claude Code does not timestamp hook payloads, and the engine must never read
/// the clock itself, so arrival time is stamped at the edge and passed in.
public struct StampedEvent: Sendable, Equatable {
    public let event: HookEvent
    public let at: Date

    public init(event: HookEvent, at: Date) {
        self.event = event
        self.at = at
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test`
Expected: PASS — 4 tests

- [ ] **Step 6: Commit**

```bash
git add Package.swift .gitignore Sources Tests docs
git commit -m "feat: event model for Claude Code hook payloads

Structural JSON decoding rather than per-tool types: tool inputs are
heterogeneous and the engine reads only a few fields from each."
```

---

### Task 2: Session registry and route capture

**Files:**
- Create: `Sources/NavigatorCore/Registry/Session.swift`
- Create: `Sources/NavigatorCore/Registry/SessionRegistry.swift`
- Test: `Tests/NavigatorCoreTests/SessionRegistryTests.swift`

**Interfaces:**
- Consumes: `StampedEvent`, `HookEvent`, `HookEventKind` from Task 1.
- Produces: `Session { id: String, cwd: String, declaredDirs: [String], route: String?, startedAt: Date, lastEventAt: Date, isActive: Bool }`; `SessionRegistry` with `init()`, `mutating func apply(_ stamped: StampedEvent)`, `func session(id: String) -> Session?`, `var activeSessions: [Session]`.

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorCoreTests/SessionRegistryTests.swift`:

```swift
import Foundation
import Testing
@testable import NavigatorCore

@Suite struct SessionRegistryBehavior {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func stamped(_ event: HookEvent, plus seconds: TimeInterval = 0) -> StampedEvent {
        StampedEvent(event: event, at: t0.addingTimeInterval(seconds))
    }

    @Test func registersSessionOnSessionStart() {
        var registry = SessionRegistry()
        registry.apply(stamped(HookEvent(kind: .sessionStart, sessionID: "s1", cwd: "/a")))

        let session = registry.session(id: "s1")
        #expect(session?.cwd == "/a")
        #expect(session?.isActive == true)
        #expect(session?.route == nil)
    }

    @Test func capturesRouteFromFirstUserPromptOnly() {
        var registry = SessionRegistry()
        registry.apply(stamped(HookEvent(kind: .sessionStart, sessionID: "s1", cwd: "/a")))
        registry.apply(stamped(HookEvent(
            kind: .userPromptSubmit, sessionID: "s1", cwd: "/a", prompt: "fix the parser")))
        registry.apply(stamped(HookEvent(
            kind: .userPromptSubmit, sessionID: "s1", cwd: "/a", prompt: "now do something else")))

        #expect(registry.session(id: "s1")?.route == "fix the parser")
    }

    @Test func adoptsSessionSeenMidFlight() {
        // The daemon may start after a session is already running, so any event
        // for an unknown session implicitly registers it.
        var registry = SessionRegistry()
        registry.apply(stamped(HookEvent(
            kind: .preToolUse, sessionID: "s9", cwd: "/b", toolName: "Read")))

        #expect(registry.session(id: "s9")?.cwd == "/b")
        #expect(registry.session(id: "s9")?.isActive == true)
    }

    @Test func marksInactiveOnSessionEnd() {
        var registry = SessionRegistry()
        registry.apply(stamped(HookEvent(kind: .sessionStart, sessionID: "s1", cwd: "/a")))
        registry.apply(stamped(HookEvent(kind: .sessionEnd, sessionID: "s1", cwd: "/a"), plus: 60))

        #expect(registry.session(id: "s1")?.isActive == false)
        #expect(registry.activeSessions.isEmpty)
    }

    @Test func tracksLastEventTime() {
        var registry = SessionRegistry()
        registry.apply(stamped(HookEvent(kind: .sessionStart, sessionID: "s1", cwd: "/a")))
        registry.apply(stamped(HookEvent(kind: .stop, sessionID: "s1", cwd: "/a"), plus: 30))

        #expect(registry.session(id: "s1")?.lastEventAt == t0.addingTimeInterval(30))
        #expect(registry.session(id: "s1")?.startedAt == t0)
    }

    @Test func tracksMultipleSessionsIndependently() {
        var registry = SessionRegistry()
        registry.apply(stamped(HookEvent(kind: .sessionStart, sessionID: "s1", cwd: "/a")))
        registry.apply(stamped(HookEvent(kind: .sessionStart, sessionID: "s2", cwd: "/b")))
        registry.apply(stamped(HookEvent(
            kind: .userPromptSubmit, sessionID: "s2", cwd: "/b", prompt: "run tests")))

        #expect(registry.session(id: "s1")?.route == nil)
        #expect(registry.session(id: "s2")?.route == "run tests")
        #expect(registry.activeSessions.count == 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionRegistryBehavior`
Expected: FAIL — `cannot find 'SessionRegistry' in scope`

- [ ] **Step 3: Write Session**

Create `Sources/NavigatorCore/Registry/Session.swift`:

```swift
import Foundation

public struct Session: Sendable, Equatable {
    public let id: String
    public var cwd: String
    /// Additional directories the session is permitted to write to, beyond `cwd`.
    /// Populated by the daemon from Claude Code's configuration; empty in v1.
    public var declaredDirs: [String]
    /// The session's first user prompt, used as its stated destination.
    public var route: String?
    public var startedAt: Date
    public var lastEventAt: Date
    public var isActive: Bool

    public init(
        id: String,
        cwd: String,
        declaredDirs: [String] = [],
        route: String? = nil,
        startedAt: Date,
        lastEventAt: Date,
        isActive: Bool = true
    ) {
        self.id = id
        self.cwd = cwd
        self.declaredDirs = declaredDirs
        self.route = route
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
        self.isActive = isActive
    }
}
```

- [ ] **Step 4: Write SessionRegistry**

Create `Sources/NavigatorCore/Registry/SessionRegistry.swift`:

```swift
import Foundation

public struct SessionRegistry: Sendable {
    private var sessions: [String: Session] = [:]

    public init() {}

    public func session(id: String) -> Session? { sessions[id] }

    public var activeSessions: [Session] {
        sessions.values.filter(\.isActive).sorted { $0.startedAt < $1.startedAt }
    }

    public mutating func apply(_ stamped: StampedEvent) {
        let event = stamped.event

        var session = sessions[event.sessionID] ?? Session(
            id: event.sessionID,
            cwd: event.cwd,
            startedAt: stamped.at,
            lastEventAt: stamped.at
        )

        session.lastEventAt = stamped.at
        session.cwd = event.cwd

        switch event.kind {
        case .sessionStart:
            session.isActive = true
        case .sessionEnd:
            session.isActive = false
        case .userPromptSubmit:
            // First prompt only. Later prompts refine the work but the route is
            // the destination declared at the outset; re-reading it every turn
            // would make off-route detection track the agent rather than you.
            if session.route == nil { session.route = event.prompt }
        default:
            break
        }

        sessions[event.sessionID] = session
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter SessionRegistryBehavior`
Expected: PASS — 6 tests

- [ ] **Step 6: Commit**

```bash
git add Sources/NavigatorCore/Registry Tests/NavigatorCoreTests/SessionRegistryTests.swift
git commit -m "feat: session registry with first-prompt route capture

Route is fixed at the first prompt. Re-reading it each turn would make
off-route detection follow the agent's drift instead of catching it."
```

---

### Task 3: Reversibility classifier

**Files:**
- Create: `Sources/NavigatorCore/Policy/Reversibility.swift`
- Create: `Sources/NavigatorCore/Policy/BashRules.swift`
- Create: `Sources/NavigatorCore/Policy/ReversibilityClassifier.swift`
- Test: `Tests/NavigatorCoreTests/ReversibilityTests.swift`

**Interfaces:**
- Consumes: `JSONValue`, `HookEvent` from Task 1.
- Produces: `Reversibility` (`.reversible`, `.irreversible(reason: String)`, `.unknown(reason: String)`); `BashRule`; `BashRules.irreversibleCommands: [BashRule]`, `BashRules.irreversibleContent: [(pattern: String, reason: String)]`, `BashRules.safeCommands: [BashRule]`; `ReversibilityClassifier` with `init(rules:)` defaulting to `BashRules`, and `func classify(toolName: String?, toolInput: [String: JSONValue]?) -> Reversibility`.

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorCoreTests/ReversibilityTests.swift`:

```swift
import Foundation
import Testing
@testable import NavigatorCore

@Suite struct ReversibilityClassification {
    let subject = ReversibilityClassifier()

    private func bash(_ command: String) -> Reversibility {
        subject.classify(toolName: "Bash", toolInput: ["command": .string(command)])
    }

    @Test(arguments: [
        "git status",
        "git log --oneline -10",
        "git diff HEAD",
        "git add .",
        "git commit -m \"feat: thing\"",
        "swift build",
        "swift test --filter Foo",
        "cargo test",
        "npm test",
        "ls -la",
        "rg pattern src/",
        "cat README.md",
        "mkdir -p build",
    ])
    func recognisesReversibleCommands(_ command: String) {
        #expect(bash(command) == .reversible, "expected reversible: \(command)")
    }

    @Test(arguments: [
        "git push --force origin main",
        "git push -f",
        "git push --force-with-lease",
        "git reset --hard HEAD~3",
        "git rebase -i main",
        "git filter-branch --tree-filter true",
        "git commit --amend -m \"oops\"",
        "git clean -fd",
        "rm -rf build",
        "rm somefile.txt",
        "npm publish",
        "cargo publish",
        "npm install lodash",
        "pip install requests",
        "brew install jq",
        "ssh homelab.local uptime",
        "scp file tristan@homelab.local:/tmp",
        "kubectl delete pod foo",
        "terraform apply",
        "npx prisma migrate reset",
    ])
    func recognisesIrreversibleCommands(_ command: String) {
        guard case .irreversible = bash(command) else {
            Issue.record("expected irreversible: \(command)")
            return
        }
    }

    @Test(arguments: [
        "psql -c \"DROP TABLE users\"",
        "psql -c \"drop database app\"",
        "mysql -e \"TRUNCATE TABLE sessions\"",
    ])
    func recognisesIrreversibleSQLByContent(_ command: String) {
        guard case .irreversible = bash(command) else {
            Issue.record("expected irreversible: \(command)")
            return
        }
    }

    @Test func unrecognisedCommandIsUnknown() {
        guard case .unknown = bash("frobnicate --widget 3") else {
            Issue.record("expected unknown")
            return
        }
    }

    @Test func compoundCommandTakesTheMostDangerousSegment() {
        guard case .irreversible = bash("swift build && rm -rf .build") else {
            Issue.record("expected irreversible")
            return
        }
        guard case .irreversible = bash("git add . ; git push --force") else {
            Issue.record("expected irreversible")
            return
        }
    }

    @Test func compoundCommandWithOneUnknownSegmentIsUnknown() {
        guard case .unknown = bash("swift build && frobnicate") else {
            Issue.record("expected unknown")
            return
        }
    }

    @Test func irreversibleBeatsUnknownInCompound() {
        guard case .irreversible = bash("frobnicate && rm -rf /tmp/x") else {
            Issue.record("expected irreversible")
            return
        }
    }

    @Test(arguments: ["Read", "Glob", "Grep", "Edit", "Write", "NotebookEdit", "TodoWrite"])
    func fileToolsAreReversible(_ tool: String) {
        #expect(subject.classify(toolName: tool, toolInput: nil) == .reversible)
    }

    @Test func webFetchIsUnknownBecauseHostFamiliarityIsNotModelled() {
        guard case .unknown = subject.classify(
            toolName: "WebFetch", toolInput: ["url": .string("https://example.com")]
        ) else {
            Issue.record("expected unknown")
            return
        }
    }

    @Test func unknownToolIsUnknown() {
        guard case .unknown = subject.classify(toolName: "SomeMCPTool", toolInput: nil) else {
            Issue.record("expected unknown")
            return
        }
    }

    @Test func nilToolIsUnknown() {
        guard case .unknown = subject.classify(toolName: nil, toolInput: nil) else {
            Issue.record("expected unknown")
            return
        }
    }

    @Test func bashWithoutCommandIsUnknown() {
        guard case .unknown = subject.classify(toolName: "Bash", toolInput: [:]) else {
            Issue.record("expected unknown")
            return
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ReversibilityClassification`
Expected: FAIL — `cannot find 'ReversibilityClassifier' in scope`

- [ ] **Step 3: Write the Reversibility type**

Create `Sources/NavigatorCore/Policy/Reversibility.swift`:

```swift
import Foundation

/// Whether an action can be quietly undone on this machine.
///
/// `.unknown` is a first-class outcome, not a failure. It is the honest answer
/// for anything the rule table does not cover, and it routes to `defer` — which
/// falls back to the on-screen prompt the user would have seen anyway.
public enum Reversibility: Sendable, Equatable {
    case reversible
    case irreversible(reason: String)
    case unknown(reason: String)
}
```

- [ ] **Step 4: Write the rule table**

Create `Sources/NavigatorCore/Policy/BashRules.swift`:

```swift
import Foundation

/// Matches a shell command segment by its leading tokens.
///
/// Deliberately not a regex. The classifier decides whether to interrupt you,
/// and a rule you cannot read at a glance is a rule you will not trust.
public struct BashRule: Sendable, Equatable {
    public let command: String
    public let subcommand: String?
    /// Any one of these flags must be present. Empty means the rule always
    /// matches once command and subcommand line up.
    public let anyFlag: [String]
    public let reason: String

    public init(_ command: String, _ subcommand: String? = nil,
                anyFlag: [String] = [], reason: String) {
        self.command = command
        self.subcommand = subcommand
        self.anyFlag = anyFlag
        self.reason = reason
    }

    public func matches(tokens: [String]) -> Bool {
        guard let first = tokens.first, first == command else { return false }
        if let subcommand {
            guard tokens.count > 1, tokens[1] == subcommand else { return false }
        }
        guard !anyFlag.isEmpty else { return true }
        return tokens.contains { anyFlag.contains($0) }
    }
}

public enum BashRules {
    public static let irreversibleCommands: [BashRule] = [
        BashRule("rm", reason: "deletes files"),
        BashRule("git", "push", anyFlag: ["--force", "-f", "--force-with-lease"],
                 reason: "force push rewrites remote history"),
        BashRule("git", "reset", anyFlag: ["--hard"], reason: "discards the working tree"),
        BashRule("git", "rebase", reason: "rewrites history"),
        BashRule("git", "filter-branch", reason: "rewrites history"),
        BashRule("git", "commit", anyFlag: ["--amend"], reason: "rewrites the last commit"),
        BashRule("git", "clean", reason: "deletes untracked files"),
        BashRule("npm", "publish", reason: "publishes a package"),
        BashRule("pnpm", "publish", reason: "publishes a package"),
        BashRule("yarn", "publish", reason: "publishes a package"),
        BashRule("cargo", "publish", reason: "publishes a crate"),
        BashRule("gem", "push", reason: "publishes a gem"),
        BashRule("twine", "upload", reason: "publishes to PyPI"),
        BashRule("npm", "install", reason: "installs dependencies"),
        BashRule("npm", "i", reason: "installs dependencies"),
        BashRule("pnpm", "install", reason: "installs dependencies"),
        BashRule("pnpm", "add", reason: "installs dependencies"),
        BashRule("yarn", "add", reason: "installs dependencies"),
        BashRule("pip", "install", reason: "installs dependencies"),
        BashRule("pip3", "install", reason: "installs dependencies"),
        BashRule("uv", "add", reason: "installs dependencies"),
        BashRule("cargo", "add", reason: "installs dependencies"),
        BashRule("brew", "install", reason: "installs software"),
        BashRule("ssh", reason: "acts on a remote host"),
        BashRule("scp", reason: "copies to or from a remote host"),
        BashRule("rsync", reason: "syncs with a remote host"),
        BashRule("kubectl", "delete", reason: "deletes cluster resources"),
        BashRule("kubectl", "apply", reason: "mutates a cluster"),
        BashRule("terraform", "apply", reason: "mutates infrastructure"),
        BashRule("terraform", "destroy", reason: "destroys infrastructure"),
        BashRule("docker", "push", reason: "publishes an image"),
        BashRule("docker", "rm", reason: "deletes a container"),
        BashRule("docker", "prune", reason: "deletes unused resources"),
        BashRule("aws", reason: "acts on cloud infrastructure"),
        BashRule("gcloud", reason: "acts on cloud infrastructure"),
    ]

    /// Case-insensitive substrings checked against the whole segment. These
    /// catch destructive payloads passed as arguments, where the command name
    /// alone is harmless.
    public static let irreversibleContent: [(pattern: String, reason: String)] = [
        ("drop table", "drops a database table"),
        ("drop database", "drops a database"),
        ("truncate table", "truncates a database table"),
        ("migrate reset", "resets the database"),
        ("db:reset", "resets the database"),
        ("--no-preserve-root", "deletes from the filesystem root"),
    ]

    public static let safeCommands: [BashRule] = [
        BashRule("ls", reason: ""), BashRule("cat", reason: ""),
        BashRule("echo", reason: ""), BashRule("pwd", reason: ""),
        BashRule("which", reason: ""), BashRule("grep", reason: ""),
        BashRule("rg", reason: ""), BashRule("find", reason: ""),
        BashRule("head", reason: ""), BashRule("tail", reason: ""),
        BashRule("wc", reason: ""), BashRule("sort", reason: ""),
        BashRule("uniq", reason: ""), BashRule("diff", reason: ""),
        BashRule("jq", reason: ""), BashRule("sed", reason: ""),
        BashRule("awk", reason: ""), BashRule("true", reason: ""),
        BashRule("mkdir", reason: ""), BashRule("touch", reason: ""),
        BashRule("cp", reason: ""), BashRule("mv", reason: ""),
        BashRule("git", "status", reason: ""), BashRule("git", "log", reason: ""),
        BashRule("git", "diff", reason: ""), BashRule("git", "show", reason: ""),
        BashRule("git", "branch", reason: ""), BashRule("git", "add", reason: ""),
        BashRule("git", "commit", reason: ""), BashRule("git", "checkout", reason: ""),
        BashRule("git", "switch", reason: ""), BashRule("git", "stash", reason: ""),
        BashRule("git", "fetch", reason: ""), BashRule("git", "pull", reason: ""),
        BashRule("git", "push", reason: ""), BashRule("git", "worktree", reason: ""),
        BashRule("git", "init", reason: ""), BashRule("git", "remote", reason: ""),
        BashRule("swift", reason: ""), BashRule("cargo", reason: ""),
        BashRule("make", reason: ""), BashRule("pytest", reason: ""),
        BashRule("go", reason: ""), BashRule("npm", "test", reason: ""),
        BashRule("npm", "run", reason: ""), BashRule("pnpm", "test", reason: ""),
        BashRule("pnpm", "run", reason: ""), BashRule("npx", reason: ""),
        BashRule("xcodebuild", reason: ""), BashRule("open", reason: ""),
    ]
}
```

- [ ] **Step 5: Write the classifier**

Create `Sources/NavigatorCore/Policy/ReversibilityClassifier.swift`:

```swift
import Foundation

public struct ReversibilityClassifier: Sendable {
    private let irreversibleCommands: [BashRule]
    private let irreversibleContent: [(pattern: String, reason: String)]
    private let safeCommands: [BashRule]

    /// Tools that only read, or whose writes are ordinary local file edits.
    private static let reversibleTools: Set<String> = [
        "Read", "Glob", "Grep", "NotebookRead", "TodoWrite",
        "Edit", "Write", "NotebookEdit", "WebSearch",
    ]

    public init(
        irreversibleCommands: [BashRule] = BashRules.irreversibleCommands,
        irreversibleContent: [(pattern: String, reason: String)] = BashRules.irreversibleContent,
        safeCommands: [BashRule] = BashRules.safeCommands
    ) {
        self.irreversibleCommands = irreversibleCommands
        self.irreversibleContent = irreversibleContent
        self.safeCommands = safeCommands
    }

    public func classify(toolName: String?, toolInput: [String: JSONValue]?) -> Reversibility {
        guard let toolName else { return .unknown(reason: "no tool name") }

        if Self.reversibleTools.contains(toolName) { return .reversible }

        if toolName == "Bash" {
            guard let command = toolInput?["command"]?.stringValue else {
                return .unknown(reason: "Bash call with no command")
            }
            return classifyCommand(command)
        }

        // WebFetch reaches the network, and host familiarity is not modelled in
        // v1. MCP tools are opaque by construction. Both defer.
        return .unknown(reason: "unrecognised tool \(toolName)")
    }

    private func classifyCommand(_ command: String) -> Reversibility {
        var sawUnknown: String?

        for segment in Self.segments(of: command) {
            switch classifySegment(segment) {
            case .irreversible(let reason):
                return .irreversible(reason: reason)  // most dangerous segment wins
            case .unknown(let reason):
                sawUnknown = reason
            case .reversible:
                continue
            }
        }

        if let sawUnknown { return .unknown(reason: sawUnknown) }
        return .reversible
    }

    private func classifySegment(_ segment: String) -> Reversibility {
        let lowered = segment.lowercased()
        for entry in irreversibleContent where lowered.contains(entry.pattern) {
            return .irreversible(reason: entry.reason)
        }

        let tokens = Self.tokenize(segment)
        guard !tokens.isEmpty else { return .reversible }

        for rule in irreversibleCommands where rule.matches(tokens: tokens) {
            return .irreversible(reason: rule.reason)
        }
        for rule in safeCommands where rule.matches(tokens: tokens) {
            return .reversible
        }
        return .unknown(reason: "unrecognised command \(tokens[0])")
    }

    /// Splits on shell separators. Crude on purpose: quoting is not honoured,
    /// which can only ever over-segment and so can only make the classifier
    /// more cautious, never less.
    static func segments(of command: String) -> [String] {
        command
            .replacingOccurrences(of: "&&", with: "\n")
            .replacingOccurrences(of: "||", with: "\n")
            .replacingOccurrences(of: ";", with: "\n")
            .replacingOccurrences(of: "|", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func tokenize(_ segment: String) -> [String] {
        segment.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter ReversibilityClassification`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add Sources/NavigatorCore/Policy Tests/NavigatorCoreTests/ReversibilityTests.swift
git commit -m "feat: reversibility classifier with explicit rule table

Unknown is a first-class outcome, not a fallback to 'probably fine' —
it routes to defer, which is the on-screen prompt you'd have seen anyway."
```

---

### Task 4: Route classifier

**Files:**
- Create: `Sources/NavigatorCore/Policy/PathNormalizer.swift`
- Create: `Sources/NavigatorCore/Policy/RouteClassifier.swift`
- Test: `Tests/NavigatorCoreTests/RouteTests.swift`

**Interfaces:**
- Consumes: `JSONValue`, `HookEvent` (Task 1); `Session` (Task 2).
- Produces: `PathNormalizer.normalize(_ path: String) -> String`, `PathNormalizer.contains(dir: String, path: String) -> Bool`; `RouteStatus` (`.onRoute`, `.offRoute(reason: String)`); `RouteClassifier` with `init()` and `func classify(toolName: String?, toolInput: [String: JSONValue]?, session: Session) -> RouteStatus`.

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorCoreTests/RouteTests.swift`:

```swift
import Foundation
import Testing
@testable import NavigatorCore

@Suite struct PathNormalization {
    @Test(arguments: [
        ("/a/b/../c", "/a/c"),
        ("/a/./b", "/a/b"),
        ("/a//b", "/a/b"),
        ("/a/b/", "/a/b"),
        ("/a/b/../../c", "/c"),
        ("/..", "/"),
        ("/", "/"),
    ])
    func normalizesLexically(_ input: String, _ expected: String) {
        #expect(PathNormalizer.normalize(input) == expected)
    }

    @Test func containmentIsBoundaryAware() {
        #expect(PathNormalizer.contains(dir: "/a/b", path: "/a/b/c.txt"))
        #expect(PathNormalizer.contains(dir: "/a/b", path: "/a/b"))
        // /a/bcd must not count as inside /a/b
        #expect(!PathNormalizer.contains(dir: "/a/b", path: "/a/bcd/e.txt"))
        #expect(!PathNormalizer.contains(dir: "/a/b", path: "/a/c.txt"))
        #expect(!PathNormalizer.contains(dir: "/a/b", path: "/"))
    }

    @Test func containmentResolvesTraversalBeforeComparing() {
        #expect(!PathNormalizer.contains(dir: "/a/b", path: "/a/b/../../etc/passwd"))
    }
}

@Suite struct RouteClassification {
    let subject = RouteClassifier()
    let session = Session(
        id: "s1", cwd: "/Users/t/Projects/app",
        startedAt: Date(timeIntervalSince1970: 0),
        lastEventAt: Date(timeIntervalSince1970: 0))

    @Test func writeInsideCwdIsOnRoute() {
        let status = subject.classify(
            toolName: "Edit",
            toolInput: ["file_path": .string("/Users/t/Projects/app/src/main.swift")],
            session: session)
        #expect(status == .onRoute)
    }

    @Test func writeOutsideCwdIsOffRoute() {
        let status = subject.classify(
            toolName: "Write",
            toolInput: ["file_path": .string("/Users/t/.zshrc")],
            session: session)
        guard case .offRoute = status else {
            Issue.record("expected offRoute")
            return
        }
    }

    @Test func writeInsideDeclaredDirIsOnRoute() {
        var wider = session
        wider.declaredDirs = ["/Users/t/Projects/shared"]
        let status = subject.classify(
            toolName: "Edit",
            toolInput: ["file_path": .string("/Users/t/Projects/shared/lib.swift")],
            session: wider)
        #expect(status == .onRoute)
    }

    @Test func relativePathIsResolvedAgainstCwd() {
        let status = subject.classify(
            toolName: "Edit",
            toolInput: ["file_path": .string("src/main.swift")],
            session: session)
        #expect(status == .onRoute)
    }

    @Test func relativeTraversalEscapingCwdIsOffRoute() {
        let status = subject.classify(
            toolName: "Write",
            toolInput: ["file_path": .string("../other/file.swift")],
            session: session)
        guard case .offRoute = status else {
            Issue.record("expected offRoute")
            return
        }
    }

    @Test func readsAreAlwaysOnRoute() {
        // Reading outside the project is how you look things up. It is not drift.
        let status = subject.classify(
            toolName: "Read",
            toolInput: ["file_path": .string("/usr/share/doc/thing")],
            session: session)
        #expect(status == .onRoute)
    }

    @Test func bashWithNoPathIsOnRoute() {
        // Location is not knowable from the command string; the reversibility
        // axis is what guards these.
        let status = subject.classify(
            toolName: "Bash",
            toolInput: ["command": .string("swift build")],
            session: session)
        #expect(status == .onRoute)
    }

    @Test func toolWithoutPathIsOnRoute() {
        #expect(subject.classify(toolName: "Glob", toolInput: nil, session: session) == .onRoute)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "PathNormalization|RouteClassification"`
Expected: FAIL — `cannot find 'PathNormalizer' in scope`

- [ ] **Step 3: Write PathNormalizer**

Create `Sources/NavigatorCore/Policy/PathNormalizer.swift`:

```swift
import Foundation

/// Lexical path handling only.
///
/// `URL.resolvingSymlinksInPath` would be more accurate but touches the
/// filesystem, and the policy engine does no I/O. Lexical normalization can be
/// fooled by a symlink out of the project; that is a known v1 limitation and is
/// noted in the plan's Known Gaps.
public enum PathNormalizer {
    public static func normalize(_ path: String) -> String {
        var stack: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": _ = stack.popLast()
            default: stack.append(String(component))
            }
        }
        return "/" + stack.joined(separator: "/")
    }

    public static func resolve(_ path: String, relativeTo base: String) -> String {
        path.hasPrefix("/") ? normalize(path) : normalize(base + "/" + path)
    }

    public static func contains(dir: String, path: String) -> Bool {
        let dir = normalize(dir)
        let path = normalize(path)
        if dir == path { return true }
        // The trailing slash is what stops /a/b from swallowing /a/bcd.
        return path.hasPrefix(dir == "/" ? "/" : dir + "/")
    }
}
```

- [ ] **Step 4: Write RouteClassifier**

Create `Sources/NavigatorCore/Policy/RouteClassifier.swift`:

```swift
import Foundation

public enum RouteStatus: Sendable, Equatable {
    case onRoute
    case offRoute(reason: String)
}

public struct RouteClassifier: Sendable {
    /// Tools that write to a path. Only these can be off-route by location.
    private static let writingTools: Set<String> = ["Edit", "Write", "NotebookEdit"]

    public init() {}

    public func classify(
        toolName: String?,
        toolInput: [String: JSONValue]?,
        session: Session
    ) -> RouteStatus {
        guard let toolName, Self.writingTools.contains(toolName) else { return .onRoute }
        guard let rawPath = toolInput?["file_path"]?.stringValue else { return .onRoute }

        let path = PathNormalizer.resolve(rawPath, relativeTo: session.cwd)
        let permitted = [session.cwd] + session.declaredDirs

        for dir in permitted where PathNormalizer.contains(dir: dir, path: path) {
            return .onRoute
        }
        return .offRoute(reason: "writes to \(path), outside \(session.cwd)")
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter "PathNormalization|RouteClassification"`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/NavigatorCore/Policy Tests/NavigatorCoreTests/RouteTests.swift
git commit -m "feat: route classifier with lexical path containment

Lexical only — resolving symlinks would mean filesystem I/O, and the
policy engine stays pure so it can be exhaustively table-tested."
```

---

### Task 5: Tier assignment and the blast-radius invariant

**Files:**
- Create: `Sources/NavigatorCore/Policy/Tier.swift`
- Create: `Sources/NavigatorCore/Policy/TierAssigner.swift`
- Test: `Tests/NavigatorCoreTests/TierTests.swift`

**Interfaces:**
- Consumes: `Reversibility` (Task 3), `RouteStatus` (Task 4), `HookEventKind` (Task 1).
- Produces: `Tier` (`.decisionPoint`, `.needsInput`, `.speak`, `.earcon`, `.silentQueue`, `.silent`) with `var isSpeech: Bool` and `var isBlocking: Bool`; `PermissionDecision` (`.allow`, `.deny`, `.ask`, `` `defer` ``); `TierVerdict { tier: Tier, permission: PermissionDecision?, reason: String }`; `TierAssigner` with `init()` and `func assign(kind: HookEventKind, reversibility: Reversibility, route: RouteStatus, message: String?) -> TierVerdict`.

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorCoreTests/TierTests.swift`:

```swift
import Foundation
import Testing
@testable import NavigatorCore

@Suite struct TierAssignment {
    let subject = TierAssigner()

    private func preToolUse(_ r: Reversibility, _ route: RouteStatus) -> TierVerdict {
        subject.assign(kind: .preToolUse, reversibility: r, route: route, message: nil)
    }

    @Test func reversibleOnRouteIsSilentAndAllowed() {
        let verdict = preToolUse(.reversible, .onRoute)
        #expect(verdict.tier == .silent)
        #expect(verdict.permission == .allow)
    }

    @Test func reversibleOffRouteEarconsAndDefers() {
        let verdict = preToolUse(.reversible, .offRoute(reason: "writes to /etc"))
        #expect(verdict.tier == .earcon)
        #expect(verdict.permission == .defer)
    }

    @Test func irreversibleOnRouteSpeaksAndDefers() {
        let verdict = preToolUse(.irreversible(reason: "force push"), .onRoute)
        #expect(verdict.tier == .decisionPoint)
        #expect(verdict.permission == .defer)
        #expect(verdict.reason.contains("force push"))
    }

    @Test func irreversibleOffRouteLeadsWithTheRouteReason() {
        let verdict = preToolUse(
            .irreversible(reason: "deletes files"),
            .offRoute(reason: "writes to /Users/t/.zshrc, outside /Users/t/Projects/app"))
        #expect(verdict.tier == .decisionPoint)
        #expect(verdict.permission == .defer)
        #expect(verdict.reason.hasPrefix("writes to /Users/t/.zshrc"))
    }

    @Test func unknownIsSilentAndDefers() {
        // Deferring shows the on-screen prompt. Narrating it would be noise.
        let verdict = preToolUse(.unknown(reason: "unrecognised command frobnicate"), .onRoute)
        #expect(verdict.tier == .silent)
        #expect(verdict.permission == .defer)
    }

    @Test func unknownOffRouteStillDefersSilently() {
        let verdict = preToolUse(.unknown(reason: "x"), .offRoute(reason: "y"))
        #expect(verdict.permission == .defer)
    }

    @Test(arguments: [
        (HookEventKind.stop, Tier.silentQueue),
        (.taskCompleted, .silentQueue),
        (.subagentStop, .silentQueue),
        (.teammateIdle, .silentQueue),
        (.postToolUseFailure, .earcon),
        (.stopFailure, .earcon),
        (.elicitation, .needsInput),
        (.sessionStart, .silent),
        (.sessionEnd, .silent),
        (.userPromptSubmit, .silent),
    ])
    func mapsNonToolEventsToTiers(_ kind: HookEventKind, _ expected: Tier) {
        let verdict = subject.assign(
            kind: kind, reversibility: .reversible, route: .onRoute, message: nil)
        #expect(verdict.tier == expected)
        #expect(verdict.permission == nil, "only PreToolUse yields a permission verdict")
    }

    @Test(arguments: ["agent_needs_input", "permission_prompt"])
    func matchedNotificationsNeedInput(_ message: String) {
        let verdict = subject.assign(
            kind: .notification, reversibility: .reversible, route: .onRoute, message: message)
        #expect(verdict.tier == .needsInput)
    }

    @Test func unmatchedNotificationIsQueued() {
        let verdict = subject.assign(
            kind: .notification, reversibility: .reversible,
            route: .onRoute, message: "compacting conversation")
        #expect(verdict.tier == .silentQueue)
    }

    @Test func fileChangedOffRouteAndIrreversibleSpeaks() {
        let verdict = subject.assign(
            kind: .fileChanged, reversibility: .irreversible(reason: "deletes files"),
            route: .offRoute(reason: "outside project"), message: nil)
        #expect(verdict.tier == .speak)
    }

    @Test func fileChangedOffRouteAndReversibleEarcons() {
        let verdict = subject.assign(
            kind: .fileChanged, reversibility: .reversible,
            route: .offRoute(reason: "outside project"), message: nil)
        #expect(verdict.tier == .earcon)
    }

    @Test func fileChangedOnRouteIsSilent() {
        let verdict = subject.assign(
            kind: .fileChanged, reversibility: .reversible, route: .onRoute, message: nil)
        #expect(verdict.tier == .silent)
    }

    @Test func tierPropertiesAreConsistent() {
        #expect(Tier.decisionPoint.isBlocking)
        #expect(Tier.decisionPoint.isSpeech)
        #expect(Tier.needsInput.isSpeech)
        #expect(Tier.speak.isSpeech)
        #expect(!Tier.needsInput.isBlocking)
        #expect(!Tier.earcon.isSpeech)
        #expect(!Tier.silent.isSpeech)
        #expect(!Tier.silentQueue.isSpeech)
    }
}

@Suite struct BlastRadiusInvariant {
    let subject = TierAssigner()

    private static let reversibilities: [Reversibility] = [
        .reversible, .irreversible(reason: "r"), .unknown(reason: "u"),
    ]
    private static let routes: [RouteStatus] = [.onRoute, .offRoute(reason: "o")]

    @Test func allowRequiresReversibleAndOnRoute() {
        for r in Self.reversibilities {
            for route in Self.routes {
                for kind in HookEventKind.allCases {
                    let verdict = subject.assign(
                        kind: kind, reversibility: r, route: route, message: nil)
                    guard verdict.permission == .allow else { continue }
                    #expect(r == .reversible, "allowed a non-reversible action: \(kind) \(r)")
                    #expect(route == .onRoute, "allowed an off-route action: \(kind) \(route)")
                }
            }
        }
    }

    @Test func neverAutoDenies() {
        for r in Self.reversibilities {
            for route in Self.routes {
                for kind in HookEventKind.allCases {
                    let verdict = subject.assign(
                        kind: kind, reversibility: r, route: route, message: nil)
                    #expect(verdict.permission != .deny,
                            "auto-denied \(kind) — agents must never fail mysteriously")
                }
            }
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "TierAssignment|BlastRadiusInvariant"`
Expected: FAIL — `cannot find 'TierAssigner' in scope`

- [ ] **Step 3: Write Tier and PermissionDecision**

Create `Sources/NavigatorCore/Policy/Tier.swift`:

```swift
import Foundation

public enum Tier: String, Sendable, Codable, Equatable, CaseIterable {
    /// Speech, and the agent waits for the answer.
    case decisionPoint
    /// Speech: the agent is stopped and needs you.
    case needsInput
    /// Speech: worth saying, but nothing is blocked on it.
    case speak
    /// A sound, no words.
    case earcon
    /// Held for the next `status` request.
    case silentQueue
    /// Nothing at all.
    case silent

    public var isSpeech: Bool {
        switch self {
        case .decisionPoint, .needsInput, .speak: true
        case .earcon, .silentQueue, .silent: false
        }
    }

    public var isBlocking: Bool { self == .decisionPoint }
}

public enum PermissionDecision: String, Sendable, Codable, Equatable {
    case allow
    case deny
    case ask
    case `defer`
}

public struct TierVerdict: Sendable, Equatable {
    public let tier: Tier
    /// Only `PreToolUse` produces a permission verdict; nil for every other event.
    public let permission: PermissionDecision?
    public let reason: String

    public init(tier: Tier, permission: PermissionDecision?, reason: String) {
        self.tier = tier
        self.permission = permission
        self.reason = reason
    }
}
```

- [ ] **Step 4: Write TierAssigner**

Create `Sources/NavigatorCore/Policy/TierAssigner.swift`:

```swift
import Foundation

public struct TierAssigner: Sendable {
    /// Notification payloads that mean the agent is stopped and waiting on you.
    private static let inputNeededMarkers = ["agent_needs_input", "permission_prompt"]

    public init() {}

    public func assign(
        kind: HookEventKind,
        reversibility: Reversibility,
        route: RouteStatus,
        message: String?
    ) -> TierVerdict {
        switch kind {
        case .preToolUse:
            return assignToolCall(reversibility: reversibility, route: route)

        case .notification:
            let matched = Self.inputNeededMarkers.contains {
                message?.contains($0) ?? false
            }
            return TierVerdict(
                tier: matched ? .needsInput : .silentQueue,
                permission: nil,
                reason: matched ? "agent is waiting on you" : "unmatched notification")

        case .elicitation:
            return TierVerdict(tier: .needsInput, permission: nil, reason: "agent asked a question")

        case .postToolUseFailure, .stopFailure:
            return TierVerdict(tier: .earcon, permission: nil, reason: "failure")

        case .stop, .taskCompleted, .subagentStop, .teammateIdle:
            return TierVerdict(tier: .silentQueue, permission: nil, reason: "completion")

        case .fileChanged:
            guard case .offRoute(let why) = route else {
                return TierVerdict(tier: .silent, permission: nil, reason: "on-route change")
            }
            if case .irreversible(let how) = reversibility {
                return TierVerdict(tier: .speak, permission: nil, reason: "\(why) — \(how)")
            }
            return TierVerdict(tier: .earcon, permission: nil, reason: why)

        case .sessionStart, .sessionEnd, .userPromptSubmit:
            return TierVerdict(tier: .silent, permission: nil, reason: "lifecycle")
        }
    }

    private func assignToolCall(
        reversibility: Reversibility, route: RouteStatus
    ) -> TierVerdict {
        // Uncertainty never speaks. Deferring surfaces the normal on-screen
        // prompt, which already says everything a spoken version would.
        if case .unknown(let why) = reversibility {
            return TierVerdict(tier: .silent, permission: .defer, reason: why)
        }

        switch (reversibility, route) {
        case (.reversible, .onRoute):
            return TierVerdict(tier: .silent, permission: .allow, reason: "reversible, on route")

        case (.reversible, .offRoute(let why)):
            return TierVerdict(tier: .earcon, permission: .defer, reason: why)

        case (.irreversible(let how), .onRoute):
            return TierVerdict(tier: .decisionPoint, permission: .defer, reason: how)

        case (.irreversible(let how), .offRoute(let why)):
            // Lead with the route reason: that it is off-route is the surprising
            // part, and it is what you need first to decide.
            return TierVerdict(tier: .decisionPoint, permission: .defer, reason: "\(why) — \(how)")

        case (.unknown, _):
            return TierVerdict(tier: .silent, permission: .defer, reason: "unknown")
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter "TierAssignment|BlastRadiusInvariant"`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/NavigatorCore/Policy Tests/NavigatorCoreTests/TierTests.swift
git commit -m "feat: tier assignment with blast-radius invariant tests

The invariant is enumerated over every event kind and both axes: allow
requires reversible AND on-route, and deny is never returned."
```

---

### Task 6: Speech budget

**Files:**
- Create: `Sources/NavigatorCore/Policy/TokenBucket.swift`
- Create: `Sources/NavigatorCore/Policy/SpeechBudget.swift`
- Test: `Tests/NavigatorCoreTests/SpeechBudgetTests.swift`

**Interfaces:**
- Consumes: `Tier` (Task 5).
- Produces: `TokenBucket` with `init(capacity: Double, refillPerSecond: Double, startingAt: Date)`, `mutating func tryConsume(at: Date) -> Bool`, `var tokens: Double`; `SpeechBudget` with `init(capacity: Double = 1, interval: TimeInterval = 300, startingAt: Date)` and `mutating func admit(_ tier: Tier, at: Date) -> Tier` returning the possibly-degraded tier.

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorCoreTests/SpeechBudgetTests.swift`:

```swift
import Foundation
import Testing
@testable import NavigatorCore

@Suite struct TokenBucketBehavior {
    let t0 = Date(timeIntervalSince1970: 0)

    @Test func consumesUntilEmpty() {
        var bucket = TokenBucket(capacity: 2, refillPerSecond: 0, startingAt: t0)
        #expect(bucket.tryConsume(at: t0))
        #expect(bucket.tryConsume(at: t0))
        #expect(!bucket.tryConsume(at: t0))
    }

    @Test func refillsOverTime() {
        var bucket = TokenBucket(capacity: 1, refillPerSecond: 1.0 / 300.0, startingAt: t0)
        #expect(bucket.tryConsume(at: t0))
        #expect(!bucket.tryConsume(at: t0.addingTimeInterval(299)))
        #expect(bucket.tryConsume(at: t0.addingTimeInterval(300)))
    }

    @Test func doesNotRefillAboveCapacity() {
        var bucket = TokenBucket(capacity: 1, refillPerSecond: 1.0 / 300.0, startingAt: t0)
        // An hour of idling must not bank twelve utterances.
        #expect(bucket.tryConsume(at: t0.addingTimeInterval(3600)))
        #expect(!bucket.tryConsume(at: t0.addingTimeInterval(3600)))
    }

    @Test func clockGoingBackwardsDoesNotGrantTokens() {
        var bucket = TokenBucket(capacity: 1, refillPerSecond: 1.0 / 300.0, startingAt: t0)
        #expect(bucket.tryConsume(at: t0))
        #expect(!bucket.tryConsume(at: t0.addingTimeInterval(-600)))
    }
}

@Suite struct SpeechBudgetBehavior {
    let t0 = Date(timeIntervalSince1970: 0)

    @Test func blockingSpeechIsFree() {
        var budget = SpeechBudget(startingAt: t0)
        // Ten in a row, no degradation: the agent is already stopped.
        for _ in 0..<10 {
            #expect(budget.admit(.decisionPoint, at: t0) == .decisionPoint)
        }
    }

    @Test func firstNonBlockingUtteranceIsAdmitted() {
        var budget = SpeechBudget(startingAt: t0)
        #expect(budget.admit(.speak, at: t0) == .speak)
    }

    @Test func secondUtteranceDegradesToEarcon() {
        var budget = SpeechBudget(startingAt: t0)
        _ = budget.admit(.speak, at: t0)
        #expect(budget.admit(.speak, at: t0.addingTimeInterval(1)) == .earcon)
    }

    @Test func budgetRecoversAfterTheInterval() {
        var budget = SpeechBudget(startingAt: t0)
        _ = budget.admit(.speak, at: t0)
        #expect(budget.admit(.speak, at: t0.addingTimeInterval(300)) == .speak)
    }

    @Test func needsInputIsRationedToo() {
        var budget = SpeechBudget(startingAt: t0)
        _ = budget.admit(.needsInput, at: t0)
        #expect(budget.admit(.needsInput, at: t0.addingTimeInterval(1)) == .earcon)
    }

    @Test func nonSpeechTiersPassThroughUntouched() {
        var budget = SpeechBudget(startingAt: t0)
        #expect(budget.admit(.earcon, at: t0) == .earcon)
        #expect(budget.admit(.silentQueue, at: t0) == .silentQueue)
        #expect(budget.admit(.silent, at: t0) == .silent)
        // And none of that consumed the speech budget.
        #expect(budget.admit(.speak, at: t0) == .speak)
    }

    @Test func blockingSpeechDoesNotDrainTheBudgetForOthers() {
        var budget = SpeechBudget(startingAt: t0)
        _ = budget.admit(.decisionPoint, at: t0)
        #expect(budget.admit(.speak, at: t0) == .speak)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "TokenBucketBehavior|SpeechBudgetBehavior"`
Expected: FAIL — `cannot find 'TokenBucket' in scope`

- [ ] **Step 3: Write TokenBucket**

Create `Sources/NavigatorCore/Policy/TokenBucket.swift`:

```swift
import Foundation

public struct TokenBucket: Sendable, Equatable {
    public private(set) var tokens: Double
    private let capacity: Double
    private let refillPerSecond: Double
    private var lastRefill: Date

    public init(capacity: Double, refillPerSecond: Double, startingAt: Date) {
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
        self.tokens = capacity
        self.lastRefill = startingAt
    }

    public mutating func tryConsume(at now: Date) -> Bool {
        refill(to: now)
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }

    private mutating func refill(to now: Date) {
        let elapsed = now.timeIntervalSince(lastRefill)
        // A backwards clock must not mint tokens. Advance the marker anyway so
        // the bucket re-anchors rather than banking the gap when time recovers.
        guard elapsed > 0 else {
            lastRefill = now
            return
        }
        tokens = min(capacity, tokens + elapsed * refillPerSecond)
        lastRefill = now
    }
}
```

- [ ] **Step 4: Write SpeechBudget**

Create `Sources/NavigatorCore/Policy/SpeechBudget.swift`:

```swift
import Foundation

/// Rations non-blocking speech.
///
/// The initial rate — one utterance per five minutes — is a guess. It is meant
/// to be replaced by a number the replay harness produces from real days, which
/// is why every degradation is recorded rather than silently applied.
public struct SpeechBudget: Sendable {
    private var bucket: TokenBucket

    public init(capacity: Double = 1, interval: TimeInterval = 300, startingAt: Date) {
        self.bucket = TokenBucket(
            capacity: capacity, refillPerSecond: 1 / interval, startingAt: startingAt)
    }

    /// Returns the tier that should actually be delivered.
    public mutating func admit(_ tier: Tier, at now: Date) -> Tier {
        guard tier.isSpeech else { return tier }
        // A hard block costs nothing you were not already losing, and buys back
        // the context switch. It is exempt, and it does not drain the bucket.
        if tier.isBlocking { return tier }
        return bucket.tryConsume(at: now) ? tier : .earcon
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter "TokenBucketBehavior|SpeechBudgetBehavior"`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/NavigatorCore/Policy Tests/NavigatorCoreTests/SpeechBudgetTests.swift
git commit -m "feat: token-bucket speech budget, blocking speech exempt

Rate is a guess by construction; degradations are recorded so the replay
harness can replace it with a number from real days."
```

---

### Task 7: Failure coalescing and thrash detection

**Files:**
- Create: `Sources/NavigatorCore/Policy/FailureCoalescer.swift`
- Create: `Sources/NavigatorCore/Policy/ThrashDetector.swift`
- Test: `Tests/NavigatorCoreTests/FailurePatternTests.swift`

**Interfaces:**
- Consumes: `Tier` (Task 5).
- Produces: `FailureCoalescer` with `init(window: TimeInterval = 60)` and `mutating func admit(sessionID: String, at: Date) -> Bool`; `ThrashDetector` with `init(repeatThreshold: Int = 3, minimumDuration: TimeInterval = 180)`, `mutating func recordFailure(sessionID: String, signature: String, at: Date) -> ThrashDetector.Verdict`, `mutating func noteFileChanged(sessionID: String)`, and nested `enum Verdict { case quiet, thrashing(signature: String, elapsed: TimeInterval, count: Int) }`; `static func signature(from message: String?) -> String`.

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorCoreTests/FailurePatternTests.swift`:

```swift
import Foundation
import Testing
@testable import NavigatorCore

@Suite struct FailureCoalescing {
    let t0 = Date(timeIntervalSince1970: 0)

    @Test func firstFailureInWindowIsAdmitted() {
        var coalescer = FailureCoalescer(window: 60)
        #expect(coalescer.admit(sessionID: "s1", at: t0))
    }

    @Test func furtherFailuresInWindowAreSuppressed() {
        var coalescer = FailureCoalescer(window: 60)
        _ = coalescer.admit(sessionID: "s1", at: t0)
        #expect(!coalescer.admit(sessionID: "s1", at: t0.addingTimeInterval(10)))
        #expect(!coalescer.admit(sessionID: "s1", at: t0.addingTimeInterval(59)))
    }

    @Test func newWindowAdmitsAgain() {
        var coalescer = FailureCoalescer(window: 60)
        _ = coalescer.admit(sessionID: "s1", at: t0)
        #expect(coalescer.admit(sessionID: "s1", at: t0.addingTimeInterval(61)))
    }

    @Test func sessionsCoalesceIndependently() {
        var coalescer = FailureCoalescer(window: 60)
        #expect(coalescer.admit(sessionID: "s1", at: t0))
        #expect(coalescer.admit(sessionID: "s2", at: t0))
    }
}

@Suite struct ThrashDetection {
    let t0 = Date(timeIntervalSince1970: 0)

    @Test func singleFailureIsQuiet() {
        var detector = ThrashDetector()
        #expect(detector.recordFailure(sessionID: "s1", signature: "E1", at: t0) == .quiet)
    }

    @Test func repeatsBelowThresholdAreQuiet() {
        var detector = ThrashDetector(repeatThreshold: 3, minimumDuration: 180)
        _ = detector.recordFailure(sessionID: "s1", signature: "E1", at: t0)
        #expect(detector.recordFailure(
            sessionID: "s1", signature: "E1", at: t0.addingTimeInterval(200)) == .quiet)
    }

    @Test func repeatsAtThresholdAndDurationReportThrashing() {
        var detector = ThrashDetector(repeatThreshold: 3, minimumDuration: 180)
        _ = detector.recordFailure(sessionID: "s1", signature: "E1", at: t0)
        _ = detector.recordFailure(sessionID: "s1", signature: "E1", at: t0.addingTimeInterval(100))
        let verdict = detector.recordFailure(
            sessionID: "s1", signature: "E1", at: t0.addingTimeInterval(200))

        guard case .thrashing(let signature, let elapsed, let count) = verdict else {
            Issue.record("expected thrashing")
            return
        }
        #expect(signature == "E1")
        #expect(elapsed == 200)
        #expect(count == 3)
    }

    @Test func fastRepeatsBelowMinimumDurationAreQuiet() {
        // Three failures in four seconds is a tight loop, not a stuck agent.
        var detector = ThrashDetector(repeatThreshold: 3, minimumDuration: 180)
        _ = detector.recordFailure(sessionID: "s1", signature: "E1", at: t0)
        _ = detector.recordFailure(sessionID: "s1", signature: "E1", at: t0.addingTimeInterval(2))
        #expect(detector.recordFailure(
            sessionID: "s1", signature: "E1", at: t0.addingTimeInterval(4)) == .quiet)
    }

    @Test func differentSignatureResetsTheStreak() {
        var detector = ThrashDetector(repeatThreshold: 3, minimumDuration: 180)
        _ = detector.recordFailure(sessionID: "s1", signature: "E1", at: t0)
        _ = detector.recordFailure(sessionID: "s1", signature: "E1", at: t0.addingTimeInterval(100))
        _ = detector.recordFailure(sessionID: "s1", signature: "E2", at: t0.addingTimeInterval(150))
        #expect(detector.recordFailure(
            sessionID: "s1", signature: "E1", at: t0.addingTimeInterval(400)) == .quiet)
    }

    @Test func fileChangeResetsTheStreak() {
        // Progress is being made, so the same error is a new attempt, not a loop.
        var detector = ThrashDetector(repeatThreshold: 3, minimumDuration: 180)
        _ = detector.recordFailure(sessionID: "s1", signature: "E1", at: t0)
        _ = detector.recordFailure(sessionID: "s1", signature: "E1", at: t0.addingTimeInterval(100))
        detector.noteFileChanged(sessionID: "s1")
        #expect(detector.recordFailure(
            sessionID: "s1", signature: "E1", at: t0.addingTimeInterval(400)) == .quiet)
    }

    @Test func sessionsThrashIndependently() {
        var detector = ThrashDetector(repeatThreshold: 2, minimumDuration: 0)
        _ = detector.recordFailure(sessionID: "s1", signature: "E1", at: t0)
        #expect(detector.recordFailure(sessionID: "s2", signature: "E1", at: t0) == .quiet)
    }

    @Test func signatureIgnoresVolatileDetail() {
        // Line numbers, addresses, and durations change between runs; the same
        // failure must hash the same or nothing ever reaches the threshold.
        let a = ThrashDetector.signature(from: "error at line 42: cannot find 'Foo' (0.31s)")
        let b = ThrashDetector.signature(from: "error at line 87: cannot find 'Foo' (1.02s)")
        #expect(a == b)
    }

    @Test func signatureDistinguishesDifferentErrors() {
        let a = ThrashDetector.signature(from: "cannot find 'Foo' in scope")
        let b = ThrashDetector.signature(from: "cannot find 'Bar' in scope")
        #expect(a != b)
    }

    @Test func signatureOfNilIsStable() {
        #expect(ThrashDetector.signature(from: nil) == ThrashDetector.signature(from: nil))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "FailureCoalescing|ThrashDetection"`
Expected: FAIL — `cannot find 'FailureCoalescer' in scope`

- [ ] **Step 3: Write FailureCoalescer**

Create `Sources/NavigatorCore/Policy/FailureCoalescer.swift`:

```swift
import Foundation

/// Collapses a burst of failures in one session into a single earcon.
///
/// One failing test is noise. The signal is in the pattern, and that is the
/// thrash detector's job, not this one's.
public struct FailureCoalescer: Sendable {
    private let window: TimeInterval
    private var lastAdmitted: [String: Date] = [:]

    public init(window: TimeInterval = 60) {
        self.window = window
    }

    /// Returns true if this failure should produce a sound.
    public mutating func admit(sessionID: String, at now: Date) -> Bool {
        if let last = lastAdmitted[sessionID], now.timeIntervalSince(last) <= window {
            return false
        }
        lastAdmitted[sessionID] = now
        return true
    }
}
```

- [ ] **Step 4: Write ThrashDetector**

Create `Sources/NavigatorCore/Policy/ThrashDetector.swift`:

```swift
import Foundation

/// Detects an agent stuck on the same error with no progress between attempts.
///
/// This is the one pattern worth promoting to speech: it is rare, it is
/// expensive to discover forty minutes late, and it is unambiguous.
public struct ThrashDetector: Sendable {
    public enum Verdict: Sendable, Equatable {
        case quiet
        case thrashing(signature: String, elapsed: TimeInterval, count: Int)
    }

    private struct Streak {
        var signature: String
        var count: Int
        var firstSeen: Date
    }

    private let repeatThreshold: Int
    private let minimumDuration: TimeInterval
    private var streaks: [String: Streak] = [:]

    public init(repeatThreshold: Int = 3, minimumDuration: TimeInterval = 180) {
        self.repeatThreshold = repeatThreshold
        self.minimumDuration = minimumDuration
    }

    public mutating func recordFailure(
        sessionID: String, signature: String, at now: Date
    ) -> Verdict {
        var streak = streaks[sessionID]
        if streak?.signature != signature {
            streak = Streak(signature: signature, count: 0, firstSeen: now)
        }
        guard var current = streak else { return .quiet }

        current.count += 1
        streaks[sessionID] = current

        let elapsed = now.timeIntervalSince(current.firstSeen)
        // Both gates matter: the count says it is not a one-off, and the
        // duration says it is not just a fast retry loop.
        guard current.count >= repeatThreshold, elapsed >= minimumDuration else {
            return .quiet
        }
        return .thrashing(signature: signature, elapsed: elapsed, count: current.count)
    }

    /// A file changed, so the next attempt is a genuinely new one.
    public mutating func noteFileChanged(sessionID: String) {
        streaks[sessionID] = nil
    }

    /// Reduces an error message to something stable across attempts.
    ///
    /// Digits are the volatile part — line numbers, addresses, elapsed times —
    /// so they are stripped. Without this, no two runs ever match and the
    /// detector never fires.
    public static func signature(from message: String?) -> String {
        guard let message else { return "<none>" }
        let stripped = message.map { $0.isNumber ? "#" : $0 }
        return String(stripped)
            .split(whereSeparator: \.isWhitespace)
            .prefix(20)
            .joined(separator: " ")
            .lowercased()
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter "FailureCoalescing|ThrashDetection"`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/NavigatorCore/Policy Tests/NavigatorCoreTests/FailurePatternTests.swift
git commit -m "feat: failure coalescing and thrash detection

Thrash needs both gates — repeat count and elapsed time — so a fast retry
loop reads as noise while a genuinely stuck session reads as signal."
```

---

### Task 8: PolicyEngine composition and decision log

**Files:**
- Create: `Sources/NavigatorCore/Log/DecisionRecord.swift`
- Create: `Sources/NavigatorCore/Policy/PolicyConfig.swift`
- Create: `Sources/NavigatorCore/Policy/PolicyEngine.swift`
- Test: `Tests/NavigatorCoreTests/PolicyEngineTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–7.
- Produces: `Decision { tier: Tier, permission: PermissionDecision?, utterance: String?, reason: String, blocking: Bool }`; `DecisionRecord` (Codable); `PolicyConfig { speechCapacity, speechInterval, failureWindow, thrashRepeatThreshold, thrashMinimumDuration }` with `static let `default``; `PolicyEngine` with `init(config:startingAt:)`, `mutating func decide(_ stamped: StampedEvent) -> Decision`, `mutating func setMuted(_ muted: Bool)`, `mutating func resolveQuestion()`, `var log: [DecisionRecord]`, `var registry: SessionRegistry`.

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorCoreTests/PolicyEngineTests.swift`:

```swift
import Foundation
import Testing
@testable import NavigatorCore

@Suite struct PolicyEngineBehavior {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func engine() -> PolicyEngine {
        var engine = PolicyEngine(startingAt: t0)
        engine.decideDiscarding(HookEvent(kind: .sessionStart, sessionID: "s1", cwd: "/p"), at: t0)
        engine.decideDiscarding(
            HookEvent(kind: .userPromptSubmit, sessionID: "s1", cwd: "/p", prompt: "build it"),
            at: t0)
        return engine
    }

    private func bash(_ command: String) -> HookEvent {
        HookEvent(kind: .preToolUse, sessionID: "s1", cwd: "/p",
                  toolName: "Bash", toolInput: ["command": .string(command)])
    }

    @Test func routineToolCallIsSilentlyAllowed() {
        var subject = engine()
        let decision = subject.decide(StampedEvent(event: bash("swift build"), at: t0))
        #expect(decision.tier == .silent)
        #expect(decision.permission == .allow)
        #expect(decision.utterance == nil)
    }

    @Test func irreversibleToolCallBlocksAndSpeaks() {
        var subject = engine()
        let decision = subject.decide(
            StampedEvent(event: bash("git push --force"), at: t0))
        #expect(decision.tier == .decisionPoint)
        #expect(decision.permission == .defer)
        #expect(decision.blocking)
        #expect(decision.utterance != nil)
    }

    @Test func secondQuestionWhileOneIsLiveDefersImmediately() {
        var subject = engine()
        _ = subject.decide(StampedEvent(event: bash("git push --force"), at: t0))
        let second = subject.decide(
            StampedEvent(event: bash("rm -rf build"), at: t0.addingTimeInterval(1)))

        #expect(second.permission == .defer)
        #expect(second.tier == .silent)
        #expect(second.reason.contains("another question"))
    }

    @Test func resolvingAQuestionAdmitsTheNextOne() {
        var subject = engine()
        _ = subject.decide(StampedEvent(event: bash("git push --force"), at: t0))
        subject.resolveQuestion()
        let second = subject.decide(
            StampedEvent(event: bash("rm -rf build"), at: t0.addingTimeInterval(1)))
        #expect(second.tier == .decisionPoint)
    }

    @Test func mutingSuppressesSpeechAndDefers() {
        var subject = engine()
        subject.setMuted(true)
        let decision = subject.decide(StampedEvent(event: bash("git push --force"), at: t0))
        #expect(decision.tier == .silent)
        #expect(decision.permission == .defer)
        #expect(decision.reason.contains("muted"))
    }

    @Test func mutingDoesNotBlockRoutineWork() {
        // Muted must mean "do not speak", not "stop working".
        var subject = engine()
        subject.setMuted(true)
        let decision = subject.decide(StampedEvent(event: bash("swift build"), at: t0))
        #expect(decision.permission == .allow)
        #expect(decision.tier == .silent)
    }

    @Test func nonBlockingSpeechDegradesOnceBudgetIsSpent() {
        var subject = engine()
        let first = subject.decide(StampedEvent(
            event: HookEvent(kind: .elicitation, sessionID: "s1", cwd: "/p"), at: t0))
        let second = subject.decide(StampedEvent(
            event: HookEvent(kind: .elicitation, sessionID: "s1", cwd: "/p"),
            at: t0.addingTimeInterval(5)))

        #expect(first.tier == .needsInput)
        #expect(second.tier == .earcon)
    }

    @Test func repeatedFailuresCoalesceToOneEarcon() {
        var subject = engine()
        let failure = HookEvent(
            kind: .postToolUseFailure, sessionID: "s1", cwd: "/p", message: "boom at line 3")

        let first = subject.decide(StampedEvent(event: failure, at: t0))
        let second = subject.decide(StampedEvent(event: failure, at: t0.addingTimeInterval(5)))

        #expect(first.tier == .earcon)
        #expect(second.tier == .silent)
        #expect(second.reason.contains("coalesced"))
    }

    @Test func sustainedThrashPromotesToSpeech() {
        var subject = engine()
        let failure = HookEvent(
            kind: .postToolUseFailure, sessionID: "s1", cwd: "/p",
            message: "cannot find 'Foo' in scope at line 12")

        _ = subject.decide(StampedEvent(event: failure, at: t0))
        _ = subject.decide(StampedEvent(event: failure, at: t0.addingTimeInterval(100)))
        let third = subject.decide(StampedEvent(event: failure, at: t0.addingTimeInterval(200)))

        #expect(third.tier == .speak)
        #expect(third.utterance?.contains("stuck") == true)
    }

    @Test func fileChangeBetweenFailuresPreventsThrashPromotion() {
        var subject = engine()
        let failure = HookEvent(
            kind: .postToolUseFailure, sessionID: "s1", cwd: "/p", message: "same error at line 12")
        let edit = HookEvent(
            kind: .preToolUse, sessionID: "s1", cwd: "/p",
            toolName: "Edit", toolInput: ["file_path": .string("/p/a.swift")])

        _ = subject.decide(StampedEvent(event: failure, at: t0))
        _ = subject.decide(StampedEvent(event: failure, at: t0.addingTimeInterval(100)))
        _ = subject.decide(StampedEvent(event: edit, at: t0.addingTimeInterval(150)))
        let third = subject.decide(StampedEvent(event: failure, at: t0.addingTimeInterval(200)))

        #expect(third.tier != .speak)
    }

    @Test func everyDecisionIsLogged() {
        var subject = engine()
        let before = subject.log.count
        _ = subject.decide(StampedEvent(event: bash("swift build"), at: t0))
        _ = subject.decide(StampedEvent(event: bash("git push --force"), at: t0))
        #expect(subject.log.count == before + 2)
    }

    @Test func logRecordsSuppressionReason() {
        var subject = engine()
        subject.setMuted(true)
        _ = subject.decide(StampedEvent(event: bash("git push --force"), at: t0))
        let record = try! #require(subject.log.last)

        #expect(record.tierAssigned == .decisionPoint)
        #expect(record.delivered == .silent)
        #expect(record.suppressedBecause?.contains("muted") == true)
    }

    @Test func logIsRoundTrippable() throws {
        var subject = engine()
        _ = subject.decide(StampedEvent(event: bash("git push --force"), at: t0))
        let record = try #require(subject.log.last)

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(DecisionRecord.self, from: data)
        #expect(decoded == record)
    }

    @Test func registryIsUpdatedAsASideEffectOfDeciding() {
        var subject = engine()
        #expect(subject.registry.session(id: "s1")?.route == "build it")
    }
}

extension PolicyEngine {
    mutating func decideDiscarding(_ event: HookEvent, at date: Date) {
        _ = decide(StampedEvent(event: event, at: date))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PolicyEngineBehavior`
Expected: FAIL — `cannot find 'PolicyEngine' in scope`

- [ ] **Step 3: Write DecisionRecord and PolicyConfig**

Create `Sources/NavigatorCore/Log/DecisionRecord.swift`:

```swift
import Foundation

public struct Decision: Sendable, Equatable {
    public let tier: Tier
    public let permission: PermissionDecision?
    public let utterance: String?
    public let reason: String
    public let blocking: Bool

    public init(
        tier: Tier, permission: PermissionDecision?,
        utterance: String?, reason: String, blocking: Bool
    ) {
        self.tier = tier
        self.permission = permission
        self.utterance = utterance
        self.reason = reason
        self.blocking = blocking
    }
}

/// One line of the decision log.
///
/// This is the primary deliverable alongside the engine itself. The budget and
/// thresholds are guesses; this record is how they get replaced with numbers.
public struct DecisionRecord: Sendable, Equatable, Codable {
    public let at: Date
    public let sessionID: String
    public let kind: HookEventKind
    public let toolName: String?
    public let reversibility: String
    public let route: String
    /// What the classifier asked for, before rationing.
    public let tierAssigned: Tier
    /// What actually happened.
    public let delivered: Tier
    public let suppressedBecause: String?
    public let permission: PermissionDecision?
    public let reason: String

    public init(
        at: Date, sessionID: String, kind: HookEventKind, toolName: String?,
        reversibility: String, route: String, tierAssigned: Tier, delivered: Tier,
        suppressedBecause: String?, permission: PermissionDecision?, reason: String
    ) {
        self.at = at
        self.sessionID = sessionID
        self.kind = kind
        self.toolName = toolName
        self.reversibility = reversibility
        self.route = route
        self.tierAssigned = tierAssigned
        self.delivered = delivered
        self.suppressedBecause = suppressedBecause
        self.permission = permission
        self.reason = reason
    }
}
```

Create `Sources/NavigatorCore/Policy/PolicyConfig.swift`:

```swift
import Foundation

/// Every number here is a guess pending replay data. They are gathered in one
/// place so the harness can sweep them.
public struct PolicyConfig: Sendable, Equatable {
    public var speechCapacity: Double
    public var speechInterval: TimeInterval
    public var failureWindow: TimeInterval
    public var thrashRepeatThreshold: Int
    public var thrashMinimumDuration: TimeInterval

    public init(
        speechCapacity: Double = 1,
        speechInterval: TimeInterval = 300,
        failureWindow: TimeInterval = 60,
        thrashRepeatThreshold: Int = 3,
        thrashMinimumDuration: TimeInterval = 180
    ) {
        self.speechCapacity = speechCapacity
        self.speechInterval = speechInterval
        self.failureWindow = failureWindow
        self.thrashRepeatThreshold = thrashRepeatThreshold
        self.thrashMinimumDuration = thrashMinimumDuration
    }

    public static let `default` = PolicyConfig()
}
```

- [ ] **Step 4: Write PolicyEngine**

Create `Sources/NavigatorCore/Policy/PolicyEngine.swift`:

```swift
import Foundation

public struct PolicyEngine: Sendable {
    public private(set) var registry = SessionRegistry()
    public private(set) var log: [DecisionRecord] = []

    private let reversibilityClassifier = ReversibilityClassifier()
    private let routeClassifier = RouteClassifier()
    private let tierAssigner = TierAssigner()

    private var budget: SpeechBudget
    private var coalescer: FailureCoalescer
    private var thrash: ThrashDetector
    private var muted = false
    private var questionInFlight = false

    public init(config: PolicyConfig = .default, startingAt: Date) {
        self.budget = SpeechBudget(
            capacity: config.speechCapacity,
            interval: config.speechInterval,
            startingAt: startingAt)
        self.coalescer = FailureCoalescer(window: config.failureWindow)
        self.thrash = ThrashDetector(
            repeatThreshold: config.thrashRepeatThreshold,
            minimumDuration: config.thrashMinimumDuration)
    }

    public mutating func setMuted(_ muted: Bool) { self.muted = muted }

    /// Called by the daemon once the live question has been answered or timed out.
    public mutating func resolveQuestion() { questionInFlight = false }

    public mutating func decide(_ stamped: StampedEvent) -> Decision {
        registry.apply(stamped)
        let event = stamped.event
        let session = registry.session(id: event.sessionID)!

        // A write is progress, so it clears any thrash streak.
        if event.kind == .preToolUse, event.filePath != nil {
            thrash.noteFileChanged(sessionID: event.sessionID)
        }

        let reversibility = reversibilityClassifier.classify(
            toolName: event.toolName, toolInput: event.toolInput)
        let route = routeClassifier.classify(
            toolName: event.toolName, toolInput: event.toolInput, session: session)
        var verdict = tierAssigner.assign(
            kind: event.kind, reversibility: reversibility, route: route, message: event.message)

        verdict = promoteThrash(verdict, event: event, at: stamped.at)

        let (delivered, suppression) = deliver(verdict, event: event, at: stamped.at)

        if delivered.isBlocking { questionInFlight = true }

        let decision = Decision(
            tier: delivered,
            permission: suppression == nil ? verdict.permission : demote(verdict.permission),
            utterance: delivered.isSpeech ? utterance(for: verdict, event: event) : nil,
            reason: suppression ?? verdict.reason,
            blocking: delivered.isBlocking)

        log.append(DecisionRecord(
            at: stamped.at,
            sessionID: event.sessionID,
            kind: event.kind,
            toolName: event.toolName,
            reversibility: describe(reversibility),
            route: describe(route),
            tierAssigned: verdict.tier,
            delivered: delivered,
            suppressedBecause: suppression,
            permission: decision.permission,
            reason: decision.reason))

        return decision
    }

    // MARK: - Delivery gates

    /// Returns the tier actually delivered, and why it differs if it does.
    private mutating func deliver(
        _ verdict: TierVerdict, event: HookEvent, at now: Date
    ) -> (Tier, String?) {
        if muted, verdict.tier.isSpeech || verdict.tier == .earcon {
            return (.silent, "muted — deferred to screen")
        }

        if verdict.tier.isBlocking, questionInFlight {
            // Stalling an agent behind another agent's ten-second exchange is
            // worse than showing a prompt.
            return (.silent, "another question is already in flight")
        }

        if verdict.tier == .earcon, isFailure(event.kind) {
            guard coalescer.admit(sessionID: event.sessionID, at: now) else {
                return (.silent, "coalesced into a recent failure earcon")
            }
            return (.earcon, nil)
        }

        let admitted = budget.admit(verdict.tier, at: now)
        return (admitted, admitted == verdict.tier ? nil : "speech budget spent")
    }

    private mutating func promoteThrash(
        _ verdict: TierVerdict, event: HookEvent, at now: Date
    ) -> TierVerdict {
        guard isFailure(event.kind) else { return verdict }

        let signature = ThrashDetector.signature(from: event.message)
        guard case .thrashing(_, let elapsed, _) = thrash.recordFailure(
            sessionID: event.sessionID, signature: signature, at: now)
        else { return verdict }

        let minutes = max(1, Int(elapsed / 60))
        return TierVerdict(
            tier: .speak,
            permission: verdict.permission,
            reason: "stuck on the same error for \(minutes) minute\(minutes == 1 ? "" : "s")")
    }

    private func isFailure(_ kind: HookEventKind) -> Bool {
        kind == .postToolUseFailure || kind == .stopFailure
    }

    /// Suppression never grants permission it would not otherwise have.
    private func demote(_ permission: PermissionDecision?) -> PermissionDecision? {
        guard let permission else { return nil }
        return permission == .allow ? .allow : .defer
    }

    // MARK: - Phrasing

    private func utterance(for verdict: TierVerdict, event: HookEvent) -> String {
        let session = registry.session(id: event.sessionID)
        let name = session.map { PathNormalizer.normalize($0.cwd) }
            .flatMap { $0.split(separator: "/").last.map(String.init) } ?? "a session"

        switch verdict.tier {
        case .decisionPoint:
            return "\(name) wants to \(verdict.reason). Approve?"
        case .needsInput:
            return "\(name) needs you."
        case .speak:
            return "\(name) has been \(verdict.reason)."
        case .earcon, .silentQueue, .silent:
            return ""
        }
    }

    private func describe(_ reversibility: Reversibility) -> String {
        switch reversibility {
        case .reversible: "reversible"
        case .irreversible(let reason): "irreversible: \(reason)"
        case .unknown(let reason): "unknown: \(reason)"
        }
    }

    private func describe(_ route: RouteStatus) -> String {
        switch route {
        case .onRoute: "on-route"
        case .offRoute(let reason): "off-route: \(reason)"
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter PolicyEngineBehavior`
Expected: PASS

- [ ] **Step 6: Run the whole suite**

Run: `swift test`
Expected: PASS — all suites

- [ ] **Step 7: Commit**

```bash
git add Sources/NavigatorCore Tests/NavigatorCoreTests/PolicyEngineTests.swift
git commit -m "feat: policy engine composition with decision log

Every decision logs the tier the classifier asked for alongside the tier
actually delivered, so suppression is visible rather than inferred."
```

---

### Task 9: Replay harness

**Files:**
- Create: `Sources/ReplayHarness/main.swift`
- Modify: `Package.swift` (add the executable target)
- Create: `Fixtures/sample-day.jsonl`
- Test: `Tests/NavigatorCoreTests/ReplayTests.swift`
- Create: `Sources/NavigatorCore/Replay/ReplaySummary.swift`

**Interfaces:**
- Consumes: `PolicyEngine`, `DecisionRecord`, `StampedEvent`, `PolicyConfig` (Tasks 1–8).
- Produces: `ReplaySummary { totalEvents, spoken, earcons, queued, silent, suppressed, blocking, utterancesPerHour }`; `Replay.run(events: [StampedEvent], config: PolicyConfig) -> (ReplaySummary, [DecisionRecord])`; `Replay.parse(jsonl: String) throws -> [StampedEvent]`.

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorCoreTests/ReplayTests.swift`:

```swift
import Foundation
import Testing
@testable import NavigatorCore

@Suite struct ReplayBehavior {
    let jsonl = """
    {"at":"2026-08-11T09:00:00Z","event":{"hook_event_name":"SessionStart","session_id":"s1","cwd":"/p"}}
    {"at":"2026-08-11T09:00:01Z","event":{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/p","prompt":"build it"}}
    {"at":"2026-08-11T09:00:02Z","event":{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/p","tool_name":"Bash","tool_input":{"command":"swift build"}}}
    {"at":"2026-08-11T09:00:03Z","event":{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/p","tool_name":"Bash","tool_input":{"command":"git push --force"}}}
    """

    @Test func parsesJSONLIntoStampedEvents() throws {
        let events = try Replay.parse(jsonl: jsonl)
        #expect(events.count == 4)
        #expect(events[0].event.kind == .sessionStart)
        #expect(events[3].event.command == "git push --force")
    }

    @Test func parseSkipsBlankLines() throws {
        let events = try Replay.parse(jsonl: "\n\n" + jsonl + "\n\n")
        #expect(events.count == 4)
    }

    @Test func summarisesADay() throws {
        let events = try Replay.parse(jsonl: jsonl)
        let (summary, records) = Replay.run(events: events, config: .default)

        #expect(summary.totalEvents == 4)
        #expect(records.count == 4)
        #expect(summary.blocking == 1)   // the force push
        #expect(summary.silent == 3)     // lifecycle x2 + the allowed build
    }

    @Test func utteranceRateIsPerWallClockHour() throws {
        let events = try Replay.parse(jsonl: jsonl)
        let (summary, _) = Replay.run(events: events, config: .default)
        // Four events across three seconds; the rate is extrapolated, so it must
        // at least be finite and positive rather than dividing by zero.
        #expect(summary.utterancesPerHour > 0)
        #expect(summary.utterancesPerHour.isFinite)
    }

    @Test func emptyReplayDoesNotDivideByZero() {
        let (summary, records) = Replay.run(events: [], config: .default)
        #expect(summary.totalEvents == 0)
        #expect(summary.utterancesPerHour == 0)
        #expect(records.isEmpty)
    }

    @Test func tighterBudgetProducesFewerUtterances() throws {
        // The point of the harness: sweep the guess and see what it costs.
        let many = (0..<10).map { i in
            StampedEvent(
                event: HookEvent(kind: .elicitation, sessionID: "s1", cwd: "/p"),
                at: Date(timeIntervalSince1970: 1_000_000 + Double(i) * 30))
        }

        let loose = Replay.run(
            events: many, config: PolicyConfig(speechInterval: 30)).0
        let tight = Replay.run(
            events: many, config: PolicyConfig(speechInterval: 3600)).0

        #expect(tight.spoken < loose.spoken)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ReplayBehavior`
Expected: FAIL — `cannot find 'Replay' in scope`

- [ ] **Step 3: Write ReplaySummary and Replay**

Create `Sources/NavigatorCore/Replay/ReplaySummary.swift`:

```swift
import Foundation

public struct ReplaySummary: Sendable, Equatable {
    public let totalEvents: Int
    public let spoken: Int
    public let earcons: Int
    public let queued: Int
    public let silent: Int
    public let suppressed: Int
    public let blocking: Int
    public let utterancesPerHour: Double
}

public enum Replay {
    struct Line: Decodable {
        let at: Date
        let event: HookEvent
    }

    public static func parse(jsonl: String) throws -> [StampedEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try jsonl
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                let parsed = try decoder.decode(Line.self, from: Data(line.utf8))
                return StampedEvent(event: parsed.event, at: parsed.at)
            }
    }

    public static func run(
        events: [StampedEvent], config: PolicyConfig = .default
    ) -> (ReplaySummary, [DecisionRecord]) {
        guard let first = events.first else {
            return (ReplaySummary(
                totalEvents: 0, spoken: 0, earcons: 0, queued: 0,
                silent: 0, suppressed: 0, blocking: 0, utterancesPerHour: 0), [])
        }

        var engine = PolicyEngine(config: config, startingAt: first.at)
        for event in events {
            let decision = engine.decide(event)
            // The harness answers instantly; a real user does not, but modelling
            // answer latency would make the concurrency gate the dominant effect
            // and drown out the budget, which is what we are here to measure.
            if decision.blocking { engine.resolveQuestion() }
        }

        let records = engine.log
        let spoken = records.count { $0.delivered.isSpeech }
        let span = events.last!.at.timeIntervalSince(first.at)
        let hours = span > 0 ? span / 3600 : 1.0 / 3600

        return (ReplaySummary(
            totalEvents: events.count,
            spoken: spoken,
            earcons: records.count { $0.delivered == .earcon },
            queued: records.count { $0.delivered == .silentQueue },
            silent: records.count { $0.delivered == .silent },
            suppressed: records.count { $0.suppressedBecause != nil },
            blocking: records.count { $0.delivered.isBlocking },
            utterancesPerHour: Double(spoken) / hours), records)
    }
}
```

- [ ] **Step 4: Write the executable and register it**

Create `Sources/ReplayHarness/main.swift`:

```swift
import Foundation
import NavigatorCore

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("""
    usage: replay <events.jsonl> [--speech-interval SECONDS] [--records]

      --speech-interval  seconds between non-blocking utterances (default 300)
      --records          print every decision record as JSON, not just the summary

    """.utf8))
    exit(2)
}

let path = arguments[1]
var config = PolicyConfig.default
if let index = arguments.firstIndex(of: "--speech-interval"),
   index + 1 < arguments.count,
   let seconds = TimeInterval(arguments[index + 1]) {
    config.speechInterval = seconds
}

guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
    FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
    exit(1)
}

let events: [StampedEvent]
do {
    events = try Replay.parse(jsonl: contents)
} catch {
    FileHandle.standardError.write(Data("cannot parse \(path): \(error)\n".utf8))
    exit(1)
}

let (summary, records) = Replay.run(events: events, config: config)

if arguments.contains("--records") {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    for record in records {
        if let data = try? encoder.encode(record),
           let line = String(data: data, encoding: .utf8) {
            print(line)
        }
    }
}

print("""
events        \(summary.totalEvents)
spoken        \(summary.spoken)
earcons       \(summary.earcons)
queued        \(summary.queued)
silent        \(summary.silent)
suppressed    \(summary.suppressed)
blocking      \(summary.blocking)
utterances/hr \(String(format: "%.2f", summary.utterancesPerHour))
""")
```

Modify `Package.swift` — replace the `targets:` array with:

```swift
    targets: [
        .target(name: "NavigatorCore"),
        .executableTarget(name: "ReplayHarness", dependencies: ["NavigatorCore"]),
        .testTarget(name: "NavigatorCoreTests", dependencies: ["NavigatorCore"]),
    ]
```

- [ ] **Step 5: Create the fixture**

Create `Fixtures/sample-day.jsonl`:

```
{"at":"2026-08-11T09:00:00Z","event":{"hook_event_name":"SessionStart","session_id":"s1","cwd":"/Users/t/Projects/app"}}
{"at":"2026-08-11T09:00:01Z","event":{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/Users/t/Projects/app","prompt":"fix the failing parser tests"}}
{"at":"2026-08-11T09:00:10Z","event":{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/Users/t/Projects/app","tool_name":"Read","tool_input":{"file_path":"/Users/t/Projects/app/src/parser.swift"}}}
{"at":"2026-08-11T09:00:20Z","event":{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/Users/t/Projects/app","tool_name":"Edit","tool_input":{"file_path":"/Users/t/Projects/app/src/parser.swift"}}}
{"at":"2026-08-11T09:00:30Z","event":{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/Users/t/Projects/app","tool_name":"Bash","tool_input":{"command":"swift test"}}}
{"at":"2026-08-11T09:00:45Z","event":{"hook_event_name":"PostToolUseFailure","session_id":"s1","cwd":"/Users/t/Projects/app","message":"cannot find 'Token' in scope at line 12"}}
{"at":"2026-08-11T09:02:00Z","event":{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/Users/t/Projects/app","tool_name":"Bash","tool_input":{"command":"swift test"}}}
{"at":"2026-08-11T09:02:20Z","event":{"hook_event_name":"PostToolUseFailure","session_id":"s1","cwd":"/Users/t/Projects/app","message":"cannot find 'Token' in scope at line 12"}}
{"at":"2026-08-11T09:05:00Z","event":{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/Users/t/Projects/app","tool_name":"Bash","tool_input":{"command":"swift test"}}}
{"at":"2026-08-11T09:05:30Z","event":{"hook_event_name":"PostToolUseFailure","session_id":"s1","cwd":"/Users/t/Projects/app","message":"cannot find 'Token' in scope at line 12"}}
{"at":"2026-08-11T09:10:00Z","event":{"hook_event_name":"SessionStart","session_id":"s2","cwd":"/Users/t/Projects/homelab"}}
{"at":"2026-08-11T09:10:05Z","event":{"hook_event_name":"UserPromptSubmit","session_id":"s2","cwd":"/Users/t/Projects/homelab","prompt":"update the caddy config"}}
{"at":"2026-08-11T09:11:00Z","event":{"hook_event_name":"PreToolUse","session_id":"s2","cwd":"/Users/t/Projects/homelab","tool_name":"Write","tool_input":{"file_path":"/Users/t/.zshrc"}}}
{"at":"2026-08-11T09:12:00Z","event":{"hook_event_name":"PreToolUse","session_id":"s2","cwd":"/Users/t/Projects/homelab","tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}}
{"at":"2026-08-11T09:15:00Z","event":{"hook_event_name":"Notification","session_id":"s1","cwd":"/Users/t/Projects/app","message":"agent_needs_input: which parser strategy?"}}
{"at":"2026-08-11T09:20:00Z","event":{"hook_event_name":"Stop","session_id":"s1","cwd":"/Users/t/Projects/app"}}
{"at":"2026-08-11T09:20:01Z","event":{"hook_event_name":"SessionEnd","session_id":"s1","cwd":"/Users/t/Projects/app"}}
```

- [ ] **Step 6: Run tests and the harness**

Run: `swift test --filter ReplayBehavior`
Expected: PASS

Run: `swift run ReplayHarness Fixtures/sample-day.jsonl`
Expected: a summary block. Sanity-check it by hand — of 17 events, only a handful should be spoken. If `spoken` is more than about 4, the budget is not doing its job and that is a finding worth recording, not a test to loosen.

Run: `swift run ReplayHarness Fixtures/sample-day.jsonl --speech-interval 3600`
Expected: `spoken` no higher than the previous run.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/NavigatorCore/Replay Sources/ReplayHarness Fixtures Tests/NavigatorCoreTests/ReplayTests.swift
git commit -m "feat: replay harness for tuning the speech budget

Counts utterances over a recorded event stream so the budget can be set
from data rather than from the guess baked into PolicyConfig."
```

---

## Known Gaps

Deliberately out of scope for this plan; each belongs to a later one.

- **Symlink escapes.** `PathNormalizer` is lexical, so a symlink inside `cwd` pointing outside it reads as on-route. Resolving it needs filesystem access, which would break engine purity. The daemon can resolve paths before handing them to the engine.
- **Host familiarity.** `WebFetch` is `.unknown` and always defers. An allowlist needs a config surface that does not exist yet.
- **`declaredDirs` is always empty.** The registry carries the field and the route classifier honours it, but nothing populates it until the daemon can read Claude Code's configuration.
- **Answer latency in replay.** The harness resolves every blocking question instantly. Real answers take seconds, during which the concurrency gate defers other questions — so replay understates deferrals. Model this once real timing data exists.
- **`FileChanged` reversibility.** The tier table handles it, but nothing produces `FileChanged` events until `watchPaths` is wired up in the daemon plan. This is open question #2 in the design doc.

---

## Verification

Before declaring the plan complete:

```bash
swift build && swift test
```

Expected: all suites pass, with `BlastRadiusInvariant` among them. That suite is the one that matters — it enumerates every event kind against both classification axes and asserts the engine can neither auto-allow something non-reversible nor auto-deny anything at all.
