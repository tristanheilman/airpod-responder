# Audio and Recall Implementation Plan


**Goal:** Make it talk, and make it repeat itself on demand — so the speech budget can be tuned by wearing it rather than guessed at from a log.

**Architecture:** A `NavigatorAudio` target wrapping `AVSpeechSynthesizer` and `NSSound` behind a `Speaker` protocol, so every test runs silently against a recording fake. The daemon gains a transcript — a rolling record of what was said and what was merely queued — and the socket gains control commands so `navigator repeat` and `navigator catch-up` can reach a running daemon. Config moves to a JSON file so the budget can change without a rebuild.

**Tech Stack:** Swift 6, AVFoundation (`AVSpeechSynthesizer`), AppKit (`NSSound`), CoreAudio (input-device-in-use), Swift Testing, SwiftPM.

## Why the defaults change

The design doc's premise is protective: interruption is expensive, so stay silent. The user's stated usage is the opposite — recovery is cheap ("I may have to come back and reconvene… that's fine"), and what they want most is **recall**, the ability to ask what they missed.

That inverts two priorities:

- **The budget starts loose** — one utterance per 60s, not per 300s — because a rate limit tuned for someone who hates interruption is the wrong starting point for someone who doesn't. It is also now a config-file value, so it can be changed between putting the AirPods in and taking them out.
- **Recall is first-class**, not a footnote. `repeat`, `catch-up`, and `status` ship in this plan rather than after it.

Neither number is knowable from the decision log, because a log of a silent day cannot tell you how much speech is too much. They get set by wearing it.

## Global Constraints

- **Tests must be silent.** Every test runs against `RecordingSpeaker`. No test may construct `AVSpeechSynthesizer` or play an `NSSound`. A CI machine that beeps is a bug.
- **One utterance at a time.** Speech serializes through a single queue; a second utterance waits rather than overlapping. Earcons may overlap speech — they are punctuation, not content.
- **Audio never blocks a decision.** Speaking happens after the response is written, on the same principle as logging: nothing that touches hardware sits on the hook's critical path.
- **Mute fails open for detection, closed for intent.** If the microphone-in-use check errors (no input device, permissions, unexpected CoreAudio status) it reports *not muted* — a detector that silently mutes on failure is indistinguishable from a broken daemon. An explicit `navigator mute` always mutes.
- **The transcript is bounded.** A rolling buffer, not a growing one; a daemon left running for a week must not accumulate unbounded utterances in memory. The decision log on disk is the permanent record.
- The wire gate stays shut. This plan adds sound, not decisions. `emitDecisions` remains `false`.
- `#expect`/`#require` cannot contain `mutating` or `throws` calls — hoist into a `let` first.

---

### Task 1: Utterance and transcript

**Files:**
- Create: `Sources/NavigatorCore/Recall/Utterance.swift`
- Create: `Sources/NavigatorCore/Recall/Transcript.swift`
- Test: `Tests/NavigatorCoreTests/TranscriptTests.swift`

**Interfaces:**
- Consumes: `Tier`, `Decision`, `DecisionRecord`.
- Produces: `Utterance { at: Date, sessionName: String, text: String, tier: Tier, wasSpoken: Bool }`; `Transcript` with `init(capacity: Int = 200)`, `mutating func record(_ utterance: Utterance)`, `var lastSpoken: Utterance?`, `func digest(since: Date?) -> String`, `func statusDigest(sessions: [Session], at: Date) -> String`, `var count: Int`.

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorCoreTests/TranscriptTests.swift`:

```swift
import Foundation
import Testing
@testable import NavigatorCore

@Suite struct TranscriptBehavior {
    let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    private func utterance(
        _ text: String, spoken: Bool = true, tier: Tier = .speak, plus: TimeInterval = 0
    ) -> Utterance {
        Utterance(at: t0.addingTimeInterval(plus), sessionName: "app",
                  text: text, tier: tier, wasSpoken: spoken)
    }

    @Test func lastSpokenIgnoresSuppressedOnes() {
        // "Repeat" must replay what you actually heard, not what was suppressed
        // — otherwise it invents a memory you never had.
        var transcript = Transcript()
        transcript.record(utterance("first"))
        transcript.record(utterance("suppressed", spoken: false, plus: 10))

        #expect(transcript.lastSpoken?.text == "first")
    }

    @Test func lastSpokenIsNilOnAnEmptyTranscript() {
        let transcript = Transcript()
        #expect(transcript.lastSpoken == nil)
    }

    @Test func digestSummarisesEverythingSinceAMoment() {
        var transcript = Transcript()
        transcript.record(utterance("one", plus: 0))
        transcript.record(utterance("two", plus: 100))
        transcript.record(utterance("three", plus: 200))

        let digest = transcript.digest(since: t0.addingTimeInterval(50))

        #expect(digest.contains("two"))
        #expect(digest.contains("three"))
        #expect(!digest.contains("one"))
    }

    @Test func digestIncludesSuppressedItems() {
        // Catch-up is precisely for what you did *not* hear.
        var transcript = Transcript()
        transcript.record(utterance("spoken", plus: 0))
        transcript.record(utterance("quiet", spoken: false, plus: 10))

        let digest = transcript.digest(since: nil)
        #expect(digest.contains("quiet"))
    }

    @Test func digestOfNothingSaysSo() {
        let transcript = Transcript()
        let digest = transcript.digest(since: nil)
        #expect(digest.lowercased().contains("nothing"))
    }

    @Test func ringBufferDropsOldestBeyondCapacity() {
        var transcript = Transcript(capacity: 3)
        for i in 0..<10 {
            transcript.record(utterance("item\(i)", plus: Double(i)))
        }
        #expect(transcript.count == 3)

        let digest = transcript.digest(since: nil)
        #expect(digest.contains("item9"))
        #expect(!digest.contains("item0"))
    }

    @Test func statusDigestNamesEachActiveSession() {
        let transcript = Transcript()
        let sessions = [
            Session(id: "a", cwd: "/Users/t/Projects/app",
                    startedAt: t0, lastEventAt: t0.addingTimeInterval(60)),
            Session(id: "b", cwd: "/Users/t/Projects/homelab",
                    startedAt: t0, lastEventAt: t0.addingTimeInterval(30)),
        ]

        let status = transcript.statusDigest(
            sessions: sessions, at: t0.addingTimeInterval(120))

        #expect(status.contains("app"))
        #expect(status.contains("homelab"))
    }

    @Test func statusDigestOfNoSessionsSaysSo() {
        let transcript = Transcript()
        let status = transcript.statusDigest(sessions: [], at: t0)
        #expect(status.lowercased().contains("no"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TranscriptBehavior`
Expected: FAIL — `cannot find 'Transcript' in scope`

- [ ] **Step 3: Write the types**

Create `Sources/NavigatorCore/Recall/Utterance.swift`:

```swift
import Foundation

/// Something the navigator had to say, whether or not it got to say it.
public struct Utterance: Sendable, Equatable {
    public let at: Date
    public let sessionName: String
    public let text: String
    public let tier: Tier
    /// False when the budget, mute, or the concurrency gate suppressed it.
    /// Recorded either way: catch-up exists for exactly the suppressed ones.
    public let wasSpoken: Bool

    public init(
        at: Date, sessionName: String, text: String, tier: Tier, wasSpoken: Bool
    ) {
        self.at = at
        self.sessionName = sessionName
        self.text = text
        self.tier = tier
        self.wasSpoken = wasSpoken
    }
}
```

Create `Sources/NavigatorCore/Recall/Transcript.swift`:

```swift
import Foundation

/// A bounded rolling record of what the navigator said and nearly said.
///
/// Bounded because the daemon runs for days: the permanent record is the
/// decision log on disk, and this only has to answer "what did I miss?".
public struct Transcript: Sendable {
    private var items: [Utterance] = []
    private let capacity: Int

    public init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { items.count }

    public mutating func record(_ utterance: Utterance) {
        items.append(utterance)
        if items.count > capacity {
            items.removeFirst(items.count - capacity)
        }
    }

    /// The last thing you actually heard.
    ///
    /// Suppressed utterances are skipped: replaying one would tell you about a
    /// moment you have no memory of, which is worse than saying nothing.
    public var lastSpoken: Utterance? {
        items.last { $0.wasSpoken }
    }

    public func digest(since moment: Date?) -> String {
        let relevant = items.filter { moment.map { cutoff in $0.at > cutoff } ?? true }
        guard !relevant.isEmpty else { return "Nothing to catch up on." }

        return relevant
            .map { $0.wasSpoken ? $0.text : "\($0.text) (not spoken at the time)" }
            .joined(separator: " ")
    }

    public func statusDigest(sessions: [Session], at now: Date) -> String {
        guard !sessions.isEmpty else { return "No active sessions." }

        let parts = sessions.map { session -> String in
            let name = Self.name(of: session)
            let idle = Int(now.timeIntervalSince(session.lastEventAt))
            return idle > 120
                ? "\(name), quiet for \(idle / 60) minutes"
                : "\(name), working"
        }
        return "\(sessions.count) session\(sessions.count == 1 ? "" : "s"): "
            + parts.joined(separator: ". ") + "."
    }

    static func name(of session: Session) -> String {
        PathNormalizer.normalize(session.cwd)
            .split(separator: "/").last.map(String.init) ?? "a session"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TranscriptBehavior`
Expected: PASS — 8 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/NavigatorCore/Recall Tests/NavigatorCoreTests/TranscriptTests.swift
git commit -m "feat: bounded transcript so the navigator can repeat itself

repeat replays only what was actually spoken; catch-up deliberately
includes what was suppressed, since that is what you missed."
```

---

### Task 2: Config file and looser defaults

**Files:**
- Create: `Sources/NavigatorIO/ConfigFile.swift`
- Modify: `Sources/NavigatorCore/Policy/PolicyConfig.swift`
- Test: `Tests/NavigatorIOTests/ConfigFileTests.swift`

**Interfaces:**
- Consumes: `PolicyConfig`.
- Produces: `PolicyConfig` gains `Codable` conformance and a new default `speechInterval` of 60; `ConfigFile` with `static func load(from: URL) -> PolicyConfig`, `static func write(_ config: PolicyConfig, to: URL) throws`, `static func describe(_ config: PolicyConfig) -> String`.

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorIOTests/ConfigFileTests.swift`:

```swift
import Foundation
import Testing
@testable import NavigatorCore
@testable import NavigatorIO

@Suite struct ConfigFileBehavior {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("navcfg-\(UUID().uuidString).json")
    }

    @Test func missingFileYieldsDefaults() {
        let config = ConfigFile.load(from: tempURL())
        #expect(config == PolicyConfig.default)
    }

    @Test func malformedFileYieldsDefaultsRatherThanCrashing() throws {
        // A daemon that refuses to start because someone fat-fingered a comma is
        // worse than one that runs with defaults and says so.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "{ not json".write(to: url, atomically: true, encoding: .utf8)

        #expect(ConfigFile.load(from: url) == PolicyConfig.default)
    }

    @Test func roundTrips() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var config = PolicyConfig.default
        config.speechInterval = 12
        config.thrashRepeatThreshold = 7
        try ConfigFile.write(config, to: url)

        let back = ConfigFile.load(from: url)
        #expect(back.speechInterval == 12)
        #expect(back.thrashRepeatThreshold == 7)
    }

    @Test func partialFileKeepsDefaultsForOmittedKeys() throws {
        // Hand-editing one value must not reset the others.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"speechInterval": 15}"#.write(to: url, atomically: true, encoding: .utf8)

        let config = ConfigFile.load(from: url)
        #expect(config.speechInterval == 15)
        #expect(config.thrashRepeatThreshold == PolicyConfig.default.thrashRepeatThreshold)
    }

    @Test func aFileCannotOpenTheWireGate() throws {
        // The gate is a code-level decision for this build. Letting a stray
        // config file flip it would undo the guarantee the observer rests on.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"emitDecisions": true}"#.write(to: url, atomically: true, encoding: .utf8)

        #expect(ConfigFile.load(from: url).emitDecisions == false)
    }

    @Test func defaultBudgetIsDeliberatelyLoose() {
        // Starts generous: the rate that suits this user is unknown, and an
        // over-tight default reads as a broken tool rather than a quiet one.
        #expect(PolicyConfig.default.speechInterval == 60)
    }

    @Test func describeMentionsTheBudget() {
        let text = ConfigFile.describe(.default)
        #expect(text.contains("60"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ConfigFileBehavior`
Expected: FAIL — `cannot find 'ConfigFile' in scope`

- [ ] **Step 3: Make PolicyConfig Codable and loosen the default**

In `Sources/NavigatorCore/Policy/PolicyConfig.swift`, change the declaration to
`public struct PolicyConfig: Sendable, Equatable, Codable` and change the
`speechInterval` default from `300` to `60` **in the initialiser signature**.
Add above the property:

```swift
    /// Seconds between non-blocking utterances.
    ///
    /// 60 rather than 300: the right value depends on how much interruption
    /// this particular person tolerates, which cannot be learned from a log of a
    /// silent day. Starting loose and tightening by feel is the only way to find
    /// it, and a too-quiet tool reads as broken rather than as restrained.
    public var speechInterval: TimeInterval
```

- [ ] **Step 4: Write ConfigFile**

Create `Sources/NavigatorIO/ConfigFile.swift`:

```swift
import Foundation
import NavigatorCore

/// Reads `~/.claude/navigator/config.json`.
///
/// Exists so the budget can be changed between putting the AirPods in and
/// taking them out. Requiring a rebuild to try a different rate would mean the
/// rate never gets tried.
public enum ConfigFile {
    public static func load(from url: URL) -> PolicyConfig {
        guard let data = try? Data(contentsOf: url) else { return .default }

        // Decode over the defaults so a file naming one key keeps the rest.
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .default
        }

        var config = PolicyConfig.default
        if let v = raw["speechCapacity"] as? Double { config.speechCapacity = v }
        if let v = raw["speechInterval"] as? Double { config.speechInterval = v }
        if let v = raw["failureWindow"] as? Double { config.failureWindow = v }
        if let v = raw["thrashRepeatThreshold"] as? Int { config.thrashRepeatThreshold = v }
        if let v = raw["thrashMinimumDuration"] as? Double { config.thrashMinimumDuration = v }
        // emitDecisions is deliberately not readable from the file. The closed
        // gate is this build's safety guarantee and should not be reachable by
        // editing JSON.
        return config
    }

    public static func write(_ config: PolicyConfig, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url)
    }

    public static func describe(_ config: PolicyConfig) -> String {
        """
        speech budget    1 utterance per \(Int(config.speechInterval))s
        failure window   \(Int(config.failureWindow))s
        thrash           \(config.thrashRepeatThreshold) repeats over \
        \(Int(config.thrashMinimumDuration))s
        """
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ConfigFileBehavior`
Expected: PASS — 7 tests

Note: existing `SpeechBudgetBehavior` tests construct `SpeechBudget()` with its
own default of 300 and are unaffected. If any test asserts on
`PolicyConfig.default.speechInterval == 300`, update it.

- [ ] **Step 6: Commit**

```bash
git add Sources/NavigatorCore/Policy/PolicyConfig.swift Sources/NavigatorIO/ConfigFile.swift Tests/NavigatorIOTests/ConfigFileTests.swift
git commit -m "feat: config file, and a deliberately looser default budget

The tolerable interruption rate is a property of the person, not of the
event stream, so it cannot come from the log. Starting loose and letting
it be edited without a rebuild is the only way it gets tuned."
```

---

### Task 3: Speaker

**Files:**
- Create: `Sources/NavigatorAudio/Speaker.swift`
- Create: `Sources/NavigatorAudio/SystemSpeaker.swift`
- Modify: `Package.swift`
- Test: `Tests/NavigatorAudioTests/SpeakerTests.swift`

**Interfaces:**
- Consumes: `Tier`.
- Produces: `protocol Speaker: Sendable` with `func say(_ text: String)`, `func play(_ earcon: Earcon)`, `func stop()`; `enum Earcon { case offRoute, failure, acknowledged }`; `RecordingSpeaker` (test double, `var spoken: [String]`, `var played: [Earcon]`); `SystemSpeaker` (AVSpeechSynthesizer + NSSound).

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorAudioTests/SpeakerTests.swift`:

```swift
import Foundation
import Testing
@testable import NavigatorAudio

@Suite struct RecordingSpeakerBehavior {
    @Test func recordsSpeechInOrder() {
        let speaker = RecordingSpeaker()
        speaker.say("first")
        speaker.say("second")
        #expect(speaker.spoken == ["first", "second"])
    }

    @Test func recordsEarcons() {
        let speaker = RecordingSpeaker()
        speaker.play(.offRoute)
        speaker.play(.failure)
        #expect(speaker.played == [.offRoute, .failure])
    }

    @Test func stopClearsNothingButIsRecorded() {
        let speaker = RecordingSpeaker()
        speaker.say("x")
        speaker.stop()
        #expect(speaker.spoken == ["x"])
        #expect(speaker.stopCount == 1)
    }

    @Test func isSafeFromSeveralThreads() {
        // The server speaks from its connection queue; commands arrive on
        // another. A speaker that corrupts its own buffer under that is useless
        // as a test double.
        let speaker = RecordingSpeaker()
        let group = DispatchGroup()
        for i in 0..<50 {
            group.enter()
            DispatchQueue.global().async {
                speaker.say("m\(i)")
                group.leave()
            }
        }
        #expect(group.wait(timeout: .now() + 5) == .success)
        #expect(speaker.spoken.count == 50)
    }
}
```

- [ ] **Step 2: Add the target and run the test to verify it fails**

In `Package.swift`, add:

```swift
        .target(name: "NavigatorAudio", dependencies: ["NavigatorCore"]),
        .testTarget(name: "NavigatorAudioTests", dependencies: ["NavigatorAudio"]),
```

Run: `swift test --filter RecordingSpeakerBehavior`
Expected: FAIL — `cannot find 'RecordingSpeaker' in scope`

- [ ] **Step 3: Write the protocol and the test double**

Create `Sources/NavigatorAudio/Speaker.swift`:

```swift
import Foundation

/// A short non-verbal sound.
///
/// Three, not more: an earcon vocabulary you have to remember is a vocabulary
/// you will not remember.
public enum Earcon: String, Sendable, Equatable, CaseIterable {
    /// Something happened outside the session's project.
    case offRoute
    /// Something failed.
    case failure
    /// A command was heard and acted on.
    case acknowledged
}

public protocol Speaker: Sendable {
    func say(_ text: String)
    func play(_ earcon: Earcon)
    /// Abandon anything queued — used when you ask it to be quiet.
    func stop()
}

/// The test double. Every test in this package uses it, because a test suite
/// that makes noise cannot be run while wearing the thing it is testing.
public final class RecordingSpeaker: Speaker, @unchecked Sendable {
    private let lock = NSLock()
    private var _spoken: [String] = []
    private var _played: [Earcon] = []
    private var _stopCount = 0

    public init() {}

    public var spoken: [String] { lock.lock(); defer { lock.unlock() }; return _spoken }
    public var played: [Earcon] { lock.lock(); defer { lock.unlock() }; return _played }
    public var stopCount: Int { lock.lock(); defer { lock.unlock() }; return _stopCount }

    public func say(_ text: String) {
        lock.lock(); _spoken.append(text); lock.unlock()
    }

    public func play(_ earcon: Earcon) {
        lock.lock(); _played.append(earcon); lock.unlock()
    }

    public func stop() {
        lock.lock(); _stopCount += 1; lock.unlock()
    }
}
```

- [ ] **Step 4: Write the real speaker**

Create `Sources/NavigatorAudio/SystemSpeaker.swift`:

```swift
import AVFoundation
import AppKit
import Foundation

/// Speaks through `AVSpeechSynthesizer` and plays system sounds as earcons.
///
/// Verified to work from a plain command-line daemon with no `NSApplication`;
/// the delegate callbacks need a run loop, which `dispatchMain()` provides.
public final class SystemSpeaker: NSObject, Speaker, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    private let rate: Float

    /// System sounds rather than bundled assets: no files to ship, and they are
    /// already distinct from one another by design.
    private static let sounds: [Earcon: String] = [
        .offRoute: "Tink",
        .failure: "Basso",
        .acknowledged: "Pop",
    ]

    public init(voiceIdentifier: String? = nil, rate: Float = AVSpeechUtteranceDefaultSpeechRate) {
        if let voiceIdentifier {
            self.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
                ?? AVSpeechSynthesisVoice(language: "en-US")
        } else {
            self.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        self.rate = rate
        super.init()
    }

    public func say(_ text: String) {
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        // AVSpeechSynthesizer already queues rather than overlapping, which is
        // exactly the one-utterance-at-a-time behaviour wanted here.
        synthesizer.speak(utterance)
    }

    public func play(_ earcon: Earcon) {
        guard let name = Self.sounds[earcon], let sound = NSSound(named: name) else { return }
        sound.play()
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter RecordingSpeakerBehavior`
Expected: PASS — 4 tests

Then confirm the real one works, once, by hand — this is the only step in the plan that makes noise:

```bash
swift run navigator say "navigator audio check"
```

(That subcommand arrives in Task 7; run this step after it, or skip to the Task 7 verification.)

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/NavigatorAudio Tests/NavigatorAudioTests
git commit -m "feat: speaker behind a protocol, with a silent test double

Every test runs against RecordingSpeaker. A suite that makes noise cannot
be run while wearing the thing it tests."
```

---

### Task 4: Tier to sound

**Files:**
- Create: `Sources/NavigatorAudio/Announcer.swift`
- Test: `Tests/NavigatorAudioTests/AnnouncerTests.swift`

**Interfaces:**
- Consumes: `Speaker`, `Earcon`, `Decision`, `Tier`, `Utterance`, `Transcript`.
- Produces: `Announcer` with `init(speaker: any Speaker)`, `func announce(_ decision: Decision, sessionName: String, at: Date) -> Utterance?`.

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorAudioTests/AnnouncerTests.swift`:

```swift
import Foundation
import Testing
@testable import NavigatorAudio
@testable import NavigatorCore

@Suite struct AnnouncerBehavior {
    let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    private func decision(
        _ tier: Tier, utterance: String? = "something happened"
    ) -> Decision {
        Decision(tier: tier, permission: nil, utterance: utterance,
                 reason: "r", blocking: tier.isBlocking)
    }

    @Test func speechTiersSpeak() {
        for tier in [Tier.decisionPoint, .needsInput, .speak] {
            let speaker = RecordingSpeaker()
            let announcer = Announcer(speaker: speaker)
            _ = announcer.announce(decision(tier), sessionName: "app", at: t0)
            #expect(speaker.spoken.count == 1, "\(tier) did not speak")
        }
    }

    @Test func earconTierPlaysAndDoesNotSpeak() {
        let speaker = RecordingSpeaker()
        let announcer = Announcer(speaker: speaker)
        _ = announcer.announce(decision(.earcon), sessionName: "app", at: t0)

        #expect(speaker.spoken.isEmpty)
        #expect(speaker.played == [.offRoute])
    }

    @Test func silentTiersMakeNoSound() {
        for tier in [Tier.silent, .silentQueue] {
            let speaker = RecordingSpeaker()
            let announcer = Announcer(speaker: speaker)
            _ = announcer.announce(decision(tier), sessionName: "app", at: t0)
            #expect(speaker.spoken.isEmpty)
            #expect(speaker.played.isEmpty)
        }
    }

    @Test func silentQueueStillReturnsAnUtteranceForCatchUp() {
        // Queued items are the entire point of catch-up: unheard, not unrecorded.
        let speaker = RecordingSpeaker()
        let announcer = Announcer(speaker: speaker)
        let recorded = announcer.announce(
            decision(.silentQueue, utterance: nil), sessionName: "app", at: t0)

        #expect(recorded != nil)
        #expect(recorded?.wasSpoken == false)
    }

    @Test func fullySilentDecisionsAreNotRecorded() {
        // Routine allowed tool calls would otherwise flood the transcript and
        // push everything worth recalling out of the ring buffer.
        let speaker = RecordingSpeaker()
        let announcer = Announcer(speaker: speaker)
        let recorded = announcer.announce(
            decision(.silent, utterance: nil), sessionName: "app", at: t0)

        #expect(recorded == nil)
    }

    @Test func recordedUtteranceCarriesTheSpokenText() {
        let speaker = RecordingSpeaker()
        let announcer = Announcer(speaker: speaker)
        let recorded = announcer.announce(
            decision(.speak, utterance: "app is stuck"), sessionName: "app", at: t0)

        #expect(recorded?.text == "app is stuck")
        #expect(recorded?.wasSpoken == true)
        #expect(speaker.spoken == ["app is stuck"])
    }

    @Test func speechTierWithNoTextFallsBackToAnEarcon() {
        // A tier that wants words but has none must not produce silence — that
        // would look identical to the tool being asleep.
        let speaker = RecordingSpeaker()
        let announcer = Announcer(speaker: speaker)
        _ = announcer.announce(decision(.speak, utterance: nil), sessionName: "app", at: t0)

        #expect(speaker.spoken.isEmpty)
        #expect(speaker.played.count == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AnnouncerBehavior`
Expected: FAIL — `cannot find 'Announcer' in scope`

- [ ] **Step 3: Write the announcer**

Create `Sources/NavigatorAudio/Announcer.swift`:

```swift
import Foundation
import NavigatorCore

/// Turns a decision into sound, and reports what should go in the transcript.
public struct Announcer: Sendable {
    private let speaker: any Speaker

    public init(speaker: any Speaker) {
        self.speaker = speaker
    }

    /// Returns the transcript entry, or nil for decisions not worth recalling.
    @discardableResult
    public func announce(
        _ decision: Decision, sessionName: String, at now: Date
    ) -> Utterance? {
        switch decision.tier {
        case .decisionPoint, .needsInput, .speak:
            guard let text = decision.utterance, !text.isEmpty else {
                // Wanted words, has none. An earcon at least says "look at me";
                // silence would be indistinguishable from a dead daemon.
                speaker.play(.failure)
                return Utterance(
                    at: now, sessionName: sessionName, text: decision.reason,
                    tier: decision.tier, wasSpoken: false)
            }
            speaker.say(text)
            return Utterance(
                at: now, sessionName: sessionName, text: text,
                tier: decision.tier, wasSpoken: true)

        case .earcon:
            speaker.play(.offRoute)
            return Utterance(
                at: now, sessionName: sessionName,
                text: decision.utterance ?? "\(sessionName): \(decision.reason)",
                tier: .earcon, wasSpoken: false)

        case .silentQueue:
            return Utterance(
                at: now, sessionName: sessionName,
                text: decision.utterance ?? "\(sessionName): \(decision.reason)",
                tier: .silentQueue, wasSpoken: false)

        case .silent:
            // Routine allowed calls. Recording these would flood the ring buffer
            // and evict everything actually worth recalling.
            return nil
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AnnouncerBehavior`
Expected: PASS — 7 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/NavigatorAudio/Announcer.swift Tests/NavigatorAudioTests/AnnouncerTests.swift
git commit -m "feat: tier to sound, and what belongs in the transcript

Silent tiers are not recorded: routine allowed calls would evict
everything worth recalling from a bounded buffer."
```

---

### Task 5: Control commands on the wire

**Files:**
- Modify: `Sources/NavigatorCore/Protocol/NavigatorMessage.swift`
- Test: `Tests/NavigatorCoreTests/NavigatorMessageTests.swift`

**Interfaces:**
- Consumes: existing `NavigatorRequest`, `NavigatorResponse`.
- Produces: `NavigatorCommand: String` (`repeatLast`, `status`, `catchUp`, `mute`, `unmute`, `say`); `NavigatorRequest` gains `command: NavigatorCommand?` and `argument: String?`, both optional and defaulted, plus `static func control(_:argument:at:)`; `NavigatorResponse` gains `message: String?`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/NavigatorCoreTests/NavigatorMessageTests.swift`:

```swift
@Suite struct ControlMessaging {
    @Test func controlRequestRoundTrips() throws {
        let request = NavigatorRequest.control(
            .catchUp, at: Date(timeIntervalSince1970: 5))
        let line = try NavigatorMessage.encodeLine(request)
        let back: NavigatorRequest = try NavigatorMessage.decode(line, as: NavigatorRequest.self)

        #expect(back.command == .catchUp)
        #expect(back.event == nil)
    }

    @Test func controlRequestCarriesAnArgument() throws {
        let request = NavigatorRequest.control(
            .say, argument: "hello there", at: Date(timeIntervalSince1970: 5))
        let line = try NavigatorMessage.encodeLine(request)
        let back: NavigatorRequest = try NavigatorMessage.decode(line, as: NavigatorRequest.self)

        #expect(back.argument == "hello there")
    }

    @Test func hookRequestsStillDecodeWithNoCommand() throws {
        // The installed hook binary predates control messages; its payloads must
        // keep working without a reinstall.
        let event = HookEvent(kind: .stop, sessionID: "s", cwd: "/p")
        let request = NavigatorRequest(event: event, at: Date(timeIntervalSince1970: 5))
        let line = try NavigatorMessage.encodeLine(request)
        let back: NavigatorRequest = try NavigatorMessage.decode(line, as: NavigatorRequest.self)

        #expect(back.command == nil)
        #expect(back.event?.kind == .stop)
    }

    @Test func responseCarriesAMessageForTheTerminal() throws {
        let response = NavigatorResponse(output: nil, message: "2 sessions: app, homelab.")
        let line = try NavigatorMessage.encodeLine(response)
        let back: NavigatorResponse = try NavigatorMessage.decode(line, as: NavigatorResponse.self)

        #expect(back.message == "2 sessions: app, homelab.")
        #expect(back.output == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ControlMessaging`
Expected: FAIL — `cannot find 'NavigatorCommand' in scope`

- [ ] **Step 3: Extend the protocol**

In `Sources/NavigatorCore/Protocol/NavigatorMessage.swift`, add above `NavigatorRequest`:

```swift
/// Something the user asked for directly, rather than something an agent did.
public enum NavigatorCommand: String, Codable, Sendable, Equatable, CaseIterable {
    case repeatLast
    case status
    case catchUp
    case mute
    case unmute
    /// Speak an arbitrary string. Exists to check the audio path without
    /// waiting for an agent to do something interesting.
    case say
}
```

Replace `NavigatorRequest` with:

```swift
public struct NavigatorRequest: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public let protocolVersion: Int
    /// Present for hook traffic, absent for control traffic.
    public let event: HookEvent?
    public let at: Date
    public let command: NavigatorCommand?
    public let argument: String?

    public init(
        event: HookEvent, at: Date, protocolVersion: Int = currentVersion
    ) {
        self.event = event
        self.at = at
        self.command = nil
        self.argument = nil
        self.protocolVersion = protocolVersion
    }

    private init(
        command: NavigatorCommand, argument: String?, at: Date
    ) {
        self.event = nil
        self.at = at
        self.command = command
        self.argument = argument
        self.protocolVersion = Self.currentVersion
    }

    public static func control(
        _ command: NavigatorCommand, argument: String? = nil, at: Date
    ) -> NavigatorRequest {
        NavigatorRequest(command: command, argument: argument, at: at)
    }

    /// Nil for control traffic, which has no event to decide about.
    public var stamped: StampedEvent? {
        event.map { StampedEvent(event: $0, at: at) }
    }
}
```

Replace `NavigatorResponse` with:

```swift
public struct NavigatorResponse: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    /// What the hook should print on stdout. Nil means print nothing.
    public let output: String?
    /// Human-readable text for a terminal — never sent to Claude Code.
    public let message: String?

    public init(
        output: String?, message: String? = nil,
        protocolVersion: Int = NavigatorRequest.currentVersion
    ) {
        self.output = output
        self.message = message
        self.protocolVersion = protocolVersion
    }

    public static let empty = NavigatorResponse(output: nil)
}
```

Fix the one call site in `NavigatorServer.handleOnce` that uses `request.stamped`
— it is now optional. That is done properly in Task 6.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "ControlMessaging|NavigatorMessaging"`
Expected: PASS — 10 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/NavigatorCore/Protocol Tests/NavigatorCoreTests/NavigatorMessageTests.swift
git commit -m "feat: control commands share the hook socket

repeat and catch-up need to reach a running daemon, and it already has a
socket. Hook payloads keep decoding unchanged so the installed binary
does not need reinstalling."
```

---

### Task 6: Wire audio and commands into the server

**Files:**
- Modify: `Sources/NavigatorIO/NavigatorServer.swift`
- Modify: `Package.swift` (NavigatorIO depends on NavigatorAudio)
- Test: `Tests/NavigatorIOTests/ServerAudioTests.swift`

**Interfaces:**
- Consumes: `Announcer`, `Speaker`, `Transcript`, `NavigatorCommand`.
- Produces: `NavigatorServer.init(socketPath:log:config:speaker:startingAt:)`; `var transcript: Transcript`; command handling for all six commands.

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorIOTests/ServerAudioTests.swift`:

```swift
import Foundation
import Testing
@testable import NavigatorAudio
@testable import NavigatorCore
@testable import NavigatorIO

@Suite struct ServerAudio {
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
        let client = try UnixSocket.connect(to: path, timeout: 2)
        defer { client.close() }
        try client.write(try NavigatorMessage.encodeLine(request))
        return try NavigatorMessage.decode(
            try client.readLine(deadline: 2), as: NavigatorResponse.self)
    }

    private func bash(_ command: String, at: Date) -> NavigatorRequest {
        NavigatorRequest(
            event: HookEvent(
                kind: .preToolUse, sessionID: "s1", cwd: "/Users/t/Projects/app",
                toolName: "Bash", toolInput: ["command": .string(command)]),
            at: at)
    }

    @Test func speaksABlockingDecision() throws {
        let path = tempPath(), speaker = RecordingSpeaker()
        let server = try makeServer(path, speaker: speaker)
        defer { server.stop() }

        _ = try send(path, bash("git push --force", at: Date(timeIntervalSince1970: 1_770_000_000)))

        // Audio happens after the response, so allow it to land.
        var spoken: [String] = []
        for _ in 0..<50 {
            spoken = speaker.spoken
            if !spoken.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(spoken.count == 1)
        #expect(spoken.first?.contains("force push") == true)
    }

    @Test func staysSilentOnRoutineCalls() throws {
        let path = tempPath(), speaker = RecordingSpeaker()
        let server = try makeServer(path, speaker: speaker)
        defer { server.stop() }

        _ = try send(path, bash("swift build", at: Date(timeIntervalSince1970: 1_770_000_000)))
        Thread.sleep(forTimeInterval: 0.2)

        #expect(speaker.spoken.isEmpty)
        #expect(speaker.played.isEmpty)
    }

    @Test func repeatReplaysTheLastSpokenLine() throws {
        let path = tempPath(), speaker = RecordingSpeaker()
        let server = try makeServer(path, speaker: speaker)
        defer { server.stop() }

        let t0 = Date(timeIntervalSince1970: 1_770_000_000)
        _ = try send(path, bash("git push --force", at: t0))
        Thread.sleep(forTimeInterval: 0.2)

        let before = speaker.spoken.count
        let response = try send(path, .control(.repeatLast, at: t0.addingTimeInterval(30)))
        Thread.sleep(forTimeInterval: 0.2)

        #expect(speaker.spoken.count == before + 1)
        #expect(speaker.spoken.last == speaker.spoken[before - 1])
        #expect(response.message?.isEmpty == false)
    }

    @Test func repeatWithNothingToSayIsGraceful() throws {
        let path = tempPath(), speaker = RecordingSpeaker()
        let server = try makeServer(path, speaker: speaker)
        defer { server.stop() }

        let response = try send(
            path, .control(.repeatLast, at: Date(timeIntervalSince1970: 1_770_000_000)))
        #expect(response.message?.isEmpty == false)
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
        Thread.sleep(forTimeInterval: 0.3)
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

    @Test func sayCommandSpeaksItsArgument() throws {
        let path = tempPath(), speaker = RecordingSpeaker()
        let server = try makeServer(path, speaker: speaker)
        defer { server.stop() }

        _ = try send(path, .control(
            .say, argument: "audio check",
            at: Date(timeIntervalSince1970: 1_770_000_000)))
        Thread.sleep(forTimeInterval: 0.2)

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
```

- [ ] **Step 2: Run test to verify it fails**

In `Package.swift`, change the `NavigatorIO` target to
`.target(name: "NavigatorIO", dependencies: ["NavigatorCore", "NavigatorAudio"])`
and add `"NavigatorAudio"` to `NavigatorIOTests`.

Run: `swift test --filter ServerAudio`
Expected: FAIL — `extra argument 'speaker' in call`

- [ ] **Step 3: Wire it in**

In `Sources/NavigatorIO/NavigatorServer.swift`: add `import NavigatorAudio`; add
stored properties `private let announcer: Announcer`, `private var transcript =
Transcript()`, `private var lastCatchUp: Date?`; add a `speaker: any Speaker =
RecordingSpeaker()` parameter to `init` before `startingAt` and set
`self.announcer = Announcer(speaker: speaker)`; keep a `private let speaker: any
Speaker` too. Add a public accessor:

```swift
    public var transcript: Transcript {
        lock.lock(); defer { lock.unlock() }
        return _transcript
    }
```

(renaming the stored property to `_transcript`). Then replace `handleOnce`'s
body after decoding with:

```swift
        if let command = request.command {
            let message = handle(command, argument: request.argument, at: request.at)
            if let reply = try? NavigatorMessage.encodeLine(
                NavigatorResponse(output: nil, message: message)) {
                try? connection.write(reply)
            }
            return
        }

        guard let stamped = request.stamped else {
            let empty = (try? NavigatorMessage.encodeLine(NavigatorResponse.empty))
                ?? Data("{}\n".utf8)
            try? connection.write(empty)
            return
        }

        lock.lock()
        let decision = engine.decide(stamped)
        let record = engine.log.last
        let sessionName = engine.registry.session(id: stamped.event.sessionID)
            .map(Transcript.name(of:)) ?? "a session"
        count += 1
        lock.unlock()

        let output = try? HookOutput.encode(
            decision, for: stamped.event.kind, emitDecisions: config.emitDecisions)

        // Respond first. Neither disk nor audio sits on the hook's critical path.
        if let reply = try? NavigatorMessage.encodeLine(
            NavigatorResponse(output: output ?? nil)) {
            try? connection.write(reply)
        }

        audio.async { [self] in
            let utterance = announcer.announce(
                decision, sessionName: sessionName, at: stamped.at)
            if let utterance {
                lock.lock(); _transcript.record(utterance); lock.unlock()
            }
        }

        if let log, let record {
            logging.async { ... }   // unchanged
        }
```

Add `private let audio = DispatchQueue(label: "navigator.audio")` beside the
other queues, and drain it in `stop()` alongside `logging`:

```swift
        logging.sync {}
        audio.sync {}
```

Add the command handler:

```swift
    /// Returns text for the terminal. Speaking is a side effect where it makes
    /// sense — you may be asking from a keyboard or from across the room.
    private func handle(
        _ command: NavigatorCommand, argument: String?, at now: Date
    ) -> String {
        switch command {
        case .repeatLast:
            lock.lock()
            let last = _transcript.lastSpoken
            lock.unlock()

            guard let last else { return "Nothing has been said yet." }
            speaker.say(last.text)
            return last.text

        case .status:
            lock.lock()
            let sessions = engine.registry.activeSessions
            let text = _transcript.statusDigest(sessions: sessions, at: now)
            lock.unlock()

            speaker.say(text)
            return text

        case .catchUp:
            lock.lock()
            let since = lastCatchUp
            let text = _transcript.digest(since: since)
            lastCatchUp = now
            lock.unlock()

            speaker.say(text)
            return text

        case .mute:
            lock.lock(); engine.setMuted(true); lock.unlock()
            speaker.stop()
            speaker.play(.acknowledged)
            return "Muted."

        case .unmute:
            lock.lock(); engine.setMuted(false); lock.unlock()
            speaker.play(.acknowledged)
            return "Unmuted."

        case .say:
            let text = argument ?? ""
            speaker.say(text)
            return text.isEmpty ? "Nothing to say." : text
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ServerAudio`
Expected: PASS — 9 tests

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS — every suite. Existing `NavigatorServing` tests must be updated
to pass a `RecordingSpeaker`.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/NavigatorIO Tests/NavigatorIOTests
git commit -m "feat: the daemon speaks, and answers repeat/status/catch-up

Audio is dispatched after the response on the same principle as logging:
nothing touching hardware belongs on the hook's critical path."
```

---

### Task 7: Terminal commands

**Files:**
- Modify: `Sources/navigator/main.swift`
- Test: manual (covered by Task 6's server tests)

**Interfaces:**
- Consumes: `NavigatorCommand`, `UnixSocket`, `NavigatorMessage`.
- Produces: `navigator repeat|status|catch-up|mute|unmute|say <text>|config`.

- [ ] **Step 1: Add a command dispatcher**

In `Sources/navigator/main.swift`, add before the `switch`:

```swift
/// Sends a control command to a running daemon and prints its reply.
func sendControl(_ command: NavigatorCommand, argument: String? = nil) -> Never {
    let socketPath = ProcessInfo.processInfo.environment["NAVIGATOR_SOCKET"] ?? defaultSocket

    guard let socket = try? UnixSocket.connect(to: socketPath, timeout: 0.5) else {
        print("no daemon on \(socketPath) — start it with: navigator run")
        exit(1)
    }
    defer { socket.close() }

    let request = NavigatorRequest.control(command, argument: argument, at: Date())
    guard let line = try? NavigatorMessage.encodeLine(request),
          (try? socket.write(line)) != nil,
          let reply = try? socket.readLine(deadline: 5),
          let response = try? NavigatorMessage.decode(reply, as: NavigatorResponse.self)
    else {
        print("daemon did not answer")
        exit(1)
    }

    print(response.message ?? "")
    exit(0)
}
```

Add cases to the `switch`:

```swift
case "repeat":   sendControl(.repeatLast)
case "status" where arguments.contains("--speak"): sendControl(.status)
case "catch-up": sendControl(.catchUp)
case "mute":     sendControl(.mute)
case "unmute":   sendControl(.unmute)
case "say":      sendControl(.say, argument: arguments.dropFirst(2).joined(separator: " "))

case "config":
    let url = defaultLogDir.appendingPathComponent("config.json")
    let config = ConfigFile.load(from: url)
    print("config: \(url.path)")
    print(FileManager.default.fileExists(atPath: url.path) ? "" : "  (not present — using defaults)")
    print(ConfigFile.describe(config))
    if arguments.contains("--write") {
        try ConfigFile.write(config, to: url)
        print("\nwrote defaults to \(url.path) — edit and restart the daemon")
    }
```

Note the existing `status` case stays as the liveness check; `status --speak`
asks the daemon for a spoken session digest. Update `usage()` accordingly.

- [ ] **Step 2: Load config in `run`**

In the `run` case, replace `config: .default` with:

```swift
    let configURL = defaultLogDir.appendingPathComponent("config.json")
    let config = ConfigFile.load(from: configURL)
```

and pass `config: config, speaker: SystemSpeaker()`. Add `import NavigatorAudio`.
Print the loaded config at startup so it is obvious which numbers are live:

```swift
    print(ConfigFile.describe(config))
```

- [ ] **Step 3: Build and check by hand**

Run: `swift build`

Then, with sound on:

```bash
swift run navigator run &
sleep 1
swift run navigator say "navigator audio check"
swift run navigator status --speak
swift run navigator repeat
swift run navigator mute
swift run navigator unmute
swift run navigator config
kill %1
```

Expected: the machine speaks "navigator audio check", then a session digest,
then repeats it; mute and unmute each play a short sound; `config` prints the
live budget.

- [ ] **Step 4: Commit**

```bash
git add Sources/navigator/main.swift
git commit -m "feat: terminal commands for repeat, catch-up, mute and say

say exists to check the audio path without waiting for an agent to do
something interesting."
```

---

### Task 8: Do not talk over a call

**Files:**
- Create: `Sources/NavigatorAudio/InputDeviceMonitor.swift`
- Modify: `Sources/NavigatorIO/NavigatorServer.swift`
- Test: `Tests/NavigatorAudioTests/InputDeviceMonitorTests.swift`

**Interfaces:**
- Consumes: CoreAudio.
- Produces: `InputDeviceMonitor` with `static func isInputInUse() -> Bool?` (nil = cannot tell) and `static func shouldSuppressAudio() -> Bool`.

- [ ] **Step 1: Write the failing test**

Create `Tests/NavigatorAudioTests/InputDeviceMonitorTests.swift`:

```swift
import Foundation
import Testing
@testable import NavigatorAudio

@Suite struct InputDeviceMonitoring {
    @Test func neverThrowsAndAlwaysAnswers() {
        // Whatever the machine's audio configuration, this must return rather
        // than trap. Probed on a machine with no default input device, where the
        // CoreAudio query errors.
        let result = InputDeviceMonitor.isInputInUse()
        #expect(result == nil || result == true || result == false)
    }

    @Test func failsOpenWhenItCannotTell() {
        // A detector that mutes on failure is indistinguishable from a broken
        // daemon: you would hear nothing and have no way to know why.
        #expect(InputDeviceMonitor.suppress(given: nil) == false)
    }

    @Test func suppressesOnlyWhenDefinitelyInUse() {
        #expect(InputDeviceMonitor.suppress(given: true) == true)
        #expect(InputDeviceMonitor.suppress(given: false) == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter InputDeviceMonitoring`
Expected: FAIL — `cannot find 'InputDeviceMonitor' in scope`

- [ ] **Step 3: Write the monitor**

Create `Sources/NavigatorAudio/InputDeviceMonitor.swift`:

```swift
import CoreAudio
import Foundation

/// Detects whether something else is using the microphone — a call, most likely.
///
/// Uses CoreAudio property queries rather than `AVCaptureDevice`, which can
/// trigger a microphone permission prompt. A background daemon asking for mic
/// access on first run would be alarming and unnecessary: nothing here records.
public enum InputDeviceMonitor {
    /// `nil` means the question could not be answered. That is a real and
    /// ordinary outcome — a machine with no default input device returns it.
    public static func isInputInUse() -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let found = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)

        guard found == noErr, device != AudioDeviceID(0) else { return nil }

        var running: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        let queried = AudioObjectGetPropertyData(
            device, &runningAddress, 0, nil, &runningSize, &running)

        guard queried == noErr else { return nil }
        return running != 0
    }

    /// Fails open by design: an undetectable state must not silence the tool.
    public static func suppress(given inUse: Bool?) -> Bool {
        inUse ?? false
    }

    public static func shouldSuppressAudio() -> Bool {
        suppress(given: isInputInUse())
    }
}
```

- [ ] **Step 4: Consult it before speaking**

In `NavigatorServer`, inside the `audio.async` block, skip audio when the mic is
busy but still record the utterance as unspoken:

```swift
        audio.async { [self] in
            let onACall = InputDeviceMonitor.shouldSuppressAudio()
            let utterance = onACall
                ? Announcer(speaker: SilentSpeaker()).announce(
                    decision, sessionName: sessionName, at: stamped.at)
                : announcer.announce(decision, sessionName: sessionName, at: stamped.at)
            if let utterance {
                lock.lock()
                _transcript.record(Utterance(
                    at: utterance.at, sessionName: utterance.sessionName,
                    text: utterance.text, tier: utterance.tier,
                    wasSpoken: utterance.wasSpoken && !onACall))
                lock.unlock()
            }
        }
```

Add to `Sources/NavigatorAudio/Speaker.swift`:

```swift
/// Discards everything. Used when the microphone is busy: the decision still
/// reaches the transcript, so catch-up can tell you what happened during a call.
public struct SilentSpeaker: Speaker {
    public init() {}
    public func say(_ text: String) {}
    public func play(_ earcon: Earcon) {}
    public func stop() {}
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test`
Expected: PASS — every suite

- [ ] **Step 6: Verify with AirPods connected**

The probe that motivated the fail-open behaviour ran on a machine with **no
default input device**, where the query errors. With AirPods connected there is
an input device, so confirm the real path:

```bash
swift run navigator run &
# with AirPods connected and nothing else using the mic:
swift run navigator say "microphone idle, you should hear this"
# then start a Photo Booth or Voice Memos recording and:
swift run navigator say "microphone busy, you should not hear this"
kill %1
```

Expected: the first is spoken, the second is not. If the second is also spoken,
`isInputInUse()` is returning nil or false on this hardware — record what it
actually returns before changing anything, because failing open is the correct
behaviour and a wrong "fix" here silences the tool.

- [ ] **Step 7: Commit**

```bash
git add Sources/NavigatorAudio Sources/NavigatorIO/NavigatorServer.swift Tests/NavigatorAudioTests/InputDeviceMonitorTests.swift
git commit -m "feat: stay quiet while the microphone is in use

CoreAudio property queries rather than AVCaptureDevice, which can prompt
for mic permission — a daemon asking for that on first run would be
alarming and it records nothing. Fails open: an undetectable state must
not silence the tool, since that is indistinguishable from a crash."
```

---

## Known Gaps

- **No voice input.** Every command is typed. `SFSpeechRecognizer` and a wake word are a later plan; the user said they are happy to reach for a keyboard.
- **No stem press.** Still blocked on Now Playing contention, as decided earlier.
- **No global hotkey.** Would need an event tap and accessibility permission. Terminal commands first; add one if reaching for a terminal turns out to be the friction.
- **No Focus/DND detection.** macOS has no clean public API for it. Explicit `mute` plus microphone detection covers the two cases that matter most.
- **No audio ducking.** Music will play over the top. `AVAudioSession` is iOS-only; doing this properly on macOS needs more than this plan warrants until it is a real annoyance.
- **No menu bar item.** Still the only planned visual surface, still deferred.
- **The wire gate stays shut.** This plan adds sound, not decisions.

## Verification

```bash
swift build && swift test
```

Every suite green and **silent** — no test may construct `SystemSpeaker`. Then
the one manual check that matters, because the entire point of this plan is that
the answer cannot come from a test:

```bash
swift run navigator run &
swift run navigator say "if you can hear this, the audio path works"
```

Then wear it for an afternoon and change `speechInterval` in
`~/.claude/navigator/config.json` until the rate feels right.
