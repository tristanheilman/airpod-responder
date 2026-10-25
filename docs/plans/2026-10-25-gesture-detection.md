# Gesture Detection Implementation Plan

Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `navigator motion watch` prints `nod` or `shake` once per deliberate gesture and nothing while you type, talk, look around or walk — with the thresholds chosen by replaying recorded files, not by hand.

**Architecture:** A `NavigatorMotion` module wraps `CMHeadphoneMotionManager` behind a `HeadMotionSource` protocol with a replay double, the same shape as `NavigatorAudio`. The detector is pure and lives in `NavigatorCore`: rotation-rate samples in, `nod`/`shake` events out, no clock reads. Recordings are JSONL with a header that records *when the recorder prompted* each gesture, so a replay can score hits, misses and false positives against ground truth, and a threshold sweep can pick the numbers by a stated rule.

**Tech Stack:** Swift 6, SwiftPM, CoreMotion, Swift Testing. Existing `NavigatorCore` / `NavigatorAudio` / `NavigatorIO`.

**Spec:** `docs/specs/2026-10-21-head-gestures.md`, section "Milestone 2 — a nod, measured", plus the spike results recorded in 1a.

## Global Constraints

- `swift test` stays silent and hardware-free: motion comes from `ReplayMotionSource`, sound from `RecordingSpeaker`. Nothing in the suite touches CoreMotion.
- `NavigatorCore` stays pure: no I/O, no clock reads. Time comes from the sample's `t`.
- Detector input is **rotation rate**, not attitude: nod = `rotationRate.x`, shake = `rotationRate.z` (measured: ±1.2–1.9 and ±1.3–2.3 rad/s respectively; still head < 0.05).
- Sample rate is ~50 Hz but the detector is written against timestamps, never sample counts.
- All five detector numbers live in `GestureConfig`, are readable from `config.json` under `"gesture"`, and the defaults are **marked as guesses** until Task 7 replaces them from recordings.
- AirPods stream only while routed to the Mac with audio active. Anything that records or watches must speak at least every 6 s.
- No AI attribution anywhere. Native surface added by this plan: `CoreMotion.CMHeadphoneMotionManager` and an `__info_plist` with `NSMotionUsageDescription` on the `navigator` binary. Nothing else.

## Review Focus

1. AirPods disconnect mid-recording (handover to the phone): the recorder must stop cleanly and still write a valid file with the samples it has — pinned in Task 5.
2. Out-of-order or duplicate sample timestamps from the sensor: the detector must ignore a sample whose `t` is not after the last one, never fire on it — pinned in Task 2.
3. A shake immediately followed by a nod inside the refractory period: exactly one event, the first — pinned in Task 2.
4. A label with path characters (`../x`, `nod/1`): the recorder must sanitise the filename, never write outside the motion directory — pinned in Task 5.
5. An `idle` recording has no prompts, so nothing would be spoken and the stream would die: the recorder must speak a cue at least every 6 s for every label — pinned in Task 5.

---

### Task 1: The sample and the recording format

**Files:**
- Create: `Sources/NavigatorCore/Motion/MotionSample.swift`
- Create: `Sources/NavigatorCore/Motion/MotionRecording.swift`
- Test: `Tests/NavigatorCoreTests/MotionRecordingTests.swift`

**Interfaces:**
- Produces: `struct Vector3: Codable, Sendable, Equatable { x, y, z: Double }`; `struct MotionSample: Codable, Sendable, Equatable { t: TimeInterval; rotation: Vector3; attitude: Vector3 /* pitch, yaw, roll */; acceleration: Vector3 }` with `init(t:rotation:attitude:acceleration:)` where `attitude` and `acceleration` default to `.zero`; `struct MotionRecording: Equatable { label: String; recordedAt: Date; prompts: [TimeInterval]; samples: [MotionSample] }` with `static func parse(jsonl: String) throws -> MotionRecording` and `func encodedJSONL() throws -> String`; `enum MotionRecordingError: Error { missingHeader, malformedLine(Int) }`.

File format, one JSON object per line, header first:
```
{"label":"nod","recordedAt":"2026-10-25T14:00:00Z","prompts":[2.0,5.0,8.0]}
{"t":0.000,"rotation":{"x":0.01,"y":0.0,"z":0.0},"attitude":{...},"acceleration":{...}}
```
`t` is seconds since the first sample. `prompts` are the `t` values at which the recorder said "now".

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct MotionRecordingFormat {
    @Test func roundTripsHeaderAndSamples() throws   // encode → parse == original, 3 samples, 2 prompts
    @Test func headerIsTheFirstLine() throws         // encodedJSONL().split("\n").first contains "\"label\""
    @Test func missingHeaderIsAnError() throws       // parse of a sample-only file throws .missingHeader
    @Test func aMalformedLineNamesItsNumber() throws // line 3 junk → .malformedLine(3)
    @Test func blankTrailingLinesAreIgnored() throws
    @Test func samplesStayInFileOrder() throws
}
```

- [ ] **Step 2: Run: `swift test --filter MotionRecordingFormat`** — Expected: FAIL, `cannot find 'MotionRecording' in scope`
- [ ] **Step 3: Implement.** Encoder: `JSONEncoder` with `.sortedKeys`, `.withoutEscapingSlashes`, dates `.iso8601`; header is a private `Header: Codable` struct. Parser: split on `\n`, skip blank lines, decode line 1 as `Header`, the rest as `MotionSample`, wrapping any decode failure as `.malformedLine(n)` with 1-based `n`.
- [ ] **Step 4: Run: `swift test --filter MotionRecordingFormat`** — Expected: PASS, 6 tests
- [ ] **Step 5: Commit** — `feat: a recording format that carries its own ground truth`

---

### Task 2: The detector

**Files:**
- Create: `Sources/NavigatorCore/Motion/GestureConfig.swift`
- Create: `Sources/NavigatorCore/Motion/GestureDetector.swift`
- Test: `Tests/NavigatorCoreTests/GestureDetectorTests.swift`
- Test helper: `Tests/NavigatorCoreTests/SyntheticMotion.swift`

**Interfaces:**
- Consumes: `MotionSample`, `Vector3` (Task 1).
- Produces: `enum Gesture: String, Codable, Sendable, CaseIterable { nod, shake }`; `struct GestureEvent: Sendable, Equatable { gesture: Gesture; at: TimeInterval }`; `struct GestureConfig: Codable, Sendable, Equatable { enterRate: Double; exitRate: Double; windowSeconds: TimeInterval; minimumHalfCycles: Int; refractorySeconds: TimeInterval }` with `static let `default`` = (1.0, 0.4, 0.8, 2, 1.0) — each documented as *a guess from the spike, replaced in Task 7*; `struct GestureDetector: Sendable { init(config: GestureConfig = .default); mutating func feed(_ sample: MotionSample) -> GestureEvent? }`.
- Test helper produces: `enum SyntheticMotion { static func still(seconds:rate:) -> [MotionSample]; static func burst(axis: KeyPath<Vector3, Double>, halfCycles: Int, amplitude: Double, period: TimeInterval, startingAt: TimeInterval, rate: Double = 50) -> [MotionSample] }` — a half-cycle is one sign of a sine lobe; `rate` is samples per second.

Algorithm (the one thing the signature does not determine):

- Two axes are tracked independently: `x` (nod) and `z` (shake). Per axis: an *open half-cycle* begins when `|rate| ≥ enterRate` and none is open; it carries its sign. It *closes* when `|rate| ≤ exitRate` (hysteresis: anything between the two thresholds changes nothing) and is appended to that axis's history as `(sign, closedAt)`.
- History entries older than `windowSeconds` (relative to the sample's `t`) are dropped on every sample.
- After closing a half-cycle, if the axis history holds `≥ minimumHalfCycles` entries whose signs **alternate**, the gesture for that axis is a candidate.
- **Axis exclusivity:** a candidate fires only if the *other* axis has no history entries and no open half-cycle inside the window. Otherwise both histories are cleared and nothing fires — looking around while nodding is incidental.
- **Refractory:** after a fire, every sample with `t < firedAt + refractorySeconds` is consumed without effect (no half-cycles open, histories stay empty).
- A sample whose `t` is not strictly greater than the previous sample's `t` is ignored entirely.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct GestureDetection {
    @Test func aNodFiresOnce()                           // burst(.x, 2 half-cycles, 1.5, 0.3s) → exactly [nod], at within the burst
    @Test func aShakeFiresOnce()                         // burst(.z, 2, 1.8, 0.3s) → [shake]
    @Test func aStillHeadFiresNothing()                  // still(10s, noise 0.05) → []
    @Test func aSingleHalfCycleIsNotAGesture()           // burst(.x, 1, 1.5) → []
    @Test func slowDriftBelowEnterFiresNothing()         // amplitude 0.8 < enter 1.0 → []
    @Test func jitterAroundEnterCountsOnce()             // one lobe whose rate crosses 1.0 three times before falling below 0.4 → still one half-cycle; two such lobes → one nod, not two
    @Test func twoNodsInsideTheRefractoryFireOnce()      // nod at 1s, nod at 1.5s → one event
    @Test func twoNodsOutsideTheRefractoryFireTwice()    // nod at 1s, nod at 3s → two
    @Test func aShakeThenANodInsideTheRefractoryFiresOnlyTheShake()  // review focus 3
    @Test func motionOnBothAxesFiresNothing()            // x burst and z burst overlapping → []
    @Test func halfCyclesMustAlternate()                 // two same-sign lobes (head down, pause, down again) → []
    @Test func halfCyclesOutsideTheWindowDoNotCombine()  // lobe at 1s, opposite lobe at 2.5s, window 0.8 → []
    @Test func anOutOfOrderSampleIsIgnored()             // review focus 2: feed t=1.0 then t=0.9 with huge rate → nil, and detector state unchanged
    @Test func configIsReadable()                        // GestureConfig.default.enterRate == 1.0 etc.
}
```

- [ ] **Step 2: Run: `swift test --filter GestureDetection`** — Expected: FAIL, `cannot find 'GestureDetector' in scope`
- [ ] **Step 3: Implement** `GestureConfig`, `GestureDetector` (a private `AxisTracker` struct per axis holding `open: (sign: Int, since: TimeInterval)?` and `history: [(sign: Int, at: TimeInterval)]`), and the `SyntheticMotion` helper.
- [ ] **Step 4: Run: `swift test --filter GestureDetection`** — Expected: PASS, 14 tests
- [ ] **Step 5: Commit** — `feat: a nod detector that fires once, from rotation rate`

---

### Task 3: Scoring a recording, and choosing the numbers

**Files:**
- Create: `Sources/NavigatorCore/Motion/GestureReplay.swift`
- Test: `Tests/NavigatorCoreTests/GestureReplayTests.swift`

**Interfaces:**
- Consumes: `MotionRecording` (T1), `GestureDetector`, `GestureConfig`, `Gesture`, `GestureEvent` (T2).
- Produces: `struct ReplayScore: Equatable { label: String; expected: Int; hits: Int; misses: Int; falsePositives: Int }`; `enum GestureReplay { static let promptTolerance: TimeInterval = 1.5; static func events(in: MotionRecording, config: GestureConfig) -> [GestureEvent]; static func score(_ recording: MotionRecording, config: GestureConfig) -> ReplayScore; static func report(_ scores: [ReplayScore]) -> String; static func sweep(_ recordings: [MotionRecording], grid: [GestureConfig]) -> [(config: GestureConfig, scores: [ReplayScore])]; static func best(_ results: [(config: GestureConfig, scores: [ReplayScore])]) -> GestureConfig?; static func defaultGrid() -> [GestureConfig] }`.

Scoring rules:
- A recording's label names the expected gesture when it is `nod` or `shake`; any other label expects nothing (`expected = 0`).
- Each prompt at time `p` is a **hit** if an event of the expected gesture occurs in `[p, p + promptTolerance]`; one event satisfies at most one prompt. Prompts without one are **misses**.
- Every event not consumed as a hit — the wrong gesture, or a right one outside any prompt window — is a **false positive**.
- `best`: among configs with **zero false positives over all recordings**, the most hits; ties to the larger `refractorySeconds`, then the larger `enterRate`. `nil` if no config is FP-free.
- `defaultGrid()`: `enterRate ∈ {0.8, 1.0, 1.2, 1.5}` × `exitRate ∈ {0.3, 0.5}` × `windowSeconds ∈ {0.6, 0.8, 1.0}` × `refractorySeconds ∈ {0.8, 1.0, 1.5}`, `minimumHalfCycles = 2` throughout (72 configs).
- `report`: one line per label — `label  expected N  hits N  misses N  false+ N` — and a totals line.

- [ ] **Step 1: Write the failing tests** (build recordings from `SyntheticMotion`, prompts placed 0.2 s before each burst)

```swift
@Suite struct GestureReplayScoring {
    @Test func everyPromptedNodIsAHit()                 // 3 prompted nods → expected 3, hits 3, fp 0
    @Test func aMissedPromptIsAMiss()                    // 3 prompts, 2 bursts → misses 1
    @Test func anUnpromptedNodIsAFalsePositive()         // nod label, burst with no prompt → fp 1
    @Test func theWrongGestureIsAFalsePositive()         // nod label, z burst at a prompt → miss 1, fp 1
    @Test func anIncidentalLabelExpectsNothing()         // "typing" label, still → expected 0, fp 0
    @Test func aDetectionOutsideToleranceIsNotAHit()     // burst 2s after the prompt → miss + fp
    @Test func bestPrefersZeroFalsePositivesOverRecall() // config A: 3 hits 1 fp; config B: 2 hits 0 fp → B
    @Test func bestBreaksTiesTowardTheLongerRefractory()
    @Test func bestIsNilWhenNothingIsClean()
    @Test func reportHasOneLinePerLabelAndATotal()
    @Test func theGridHasSeventyTwoConfigs()
}
```

- [ ] **Step 2: Run: `swift test --filter GestureReplayScoring`** — Expected: FAIL, `cannot find 'GestureReplay' in scope`
- [ ] **Step 3: Implement** in `GestureReplay.swift`.
- [ ] **Step 4: Run: `swift test --filter GestureReplayScoring`** — Expected: PASS, 11 tests
- [ ] **Step 5: Commit** — `feat: score a recording against when it was prompted, and sweep`

---

### Task 4: The motion module and the binary's permission string

**Files:**
- Modify: `Package.swift`
- Create: `Sources/NavigatorMotion/HeadMotionSource.swift`
- Create: `Sources/NavigatorMotion/CoreMotionSource.swift`
- Create: `Sources/navigator/Info.plist`
- Test: `Tests/NavigatorMotionTests/ReplayMotionSourceTests.swift`
- Test: `Tests/NavigatorIOTests/BinaryInstallerTests.swift` (append)

**Interfaces:**
- Consumes: `MotionSample` (T1).
- Produces: `protocol HeadMotionSource: Sendable { func start(onSample: @escaping @Sendable (MotionSample) -> Void, onConnection: @escaping @Sendable (Bool) -> Void) throws; func stop() }`; `final class ReplayMotionSource: HeadMotionSource` with `init(samples: [MotionSample], connected: Bool = true)` that calls `onConnection(connected)` then delivers every sample synchronously on `start`, and records `stopCount`; `enum HeadMotionError: Error { unavailable, unauthorized(Int) }`; `final class CoreMotionSource: HeadMotionSource` wrapping `CMHeadphoneMotionManager`: calls `startConnectionStatusUpdates()` (macOS 15+), maps `CMDeviceMotion` to `MotionSample(t: motion.timestamp, rotation: rotationRate, attitude: (pitch, yaw, roll), acceleration: userAcceleration)` — `t` is *raw* here (seconds since boot); the recorder normalises — throws `.unavailable` when `isDeviceMotionAvailable` is false.
- Package: new `.target(name: "NavigatorMotion", dependencies: ["NavigatorCore"])`, `.testTarget(name: "NavigatorMotionTests", dependencies: ["NavigatorMotion"])`; `navigator` gains the dependency and `linkerSettings: [.unsafeFlags(["-Xlinker","-sectcreate","-Xlinker","__TEXT","-Xlinker","__info_plist","-Xlinker","Sources/navigator/Info.plist"])]` with `exclude: ["Info.plist"]`. `Info.plist` carries `CFBundleIdentifier com.airpodresponder.navigator` and `NSMotionUsageDescription` = *"Reads AirPods head motion so a nod can answer a question."*

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/NavigatorMotionTests/ReplayMotionSourceTests.swift
@Suite struct ReplaySource {
    @Test func deliversEverySampleInOrder() throws
    @Test func reportsConnectionBeforeTheFirstSample() throws
    @Test func stopIsCounted() throws
}
// Tests/NavigatorIOTests/BinaryInstallerTests.swift — append to the existing suite
@Test func theDaemonCarriesItsMotionUsageDescription() throws
    // otool -s __TEXT __info_plist .build/debug/navigator | xxd -r (or `otool -X -s` + hex decode) contains "NSMotionUsageDescription"
```

- [ ] **Step 2: Run: `swift build --build-tests`** — Expected: FAIL, `no such module 'NavigatorMotion'`
- [ ] **Step 3: Implement** Package.swift, the protocol, `ReplayMotionSource`, `CoreMotionSource`, `Info.plist`. `CoreMotionSource` is hardware and is verified by Task 6's `watch`, not by the suite.
- [ ] **Step 4: Run: `swift build && swift test --filter "ReplaySource|theDaemonCarriesItsMotionUsageDescription"`** — Expected: PASS, 4 tests
- [ ] **Step 5: Commit** — `feat: head motion behind a protocol, and the daemon's permission string`

---

### Task 5: Recording

**Files:**
- Create: `Sources/NavigatorMotion/MotionRecorder.swift`
- Modify: `Sources/navigator/main.swift` (add `case "motion":` dispatching `record`; `replay` and `watch` come in Task 6)
- Test: `Tests/NavigatorMotionTests/MotionRecorderTests.swift`

**Interfaces:**
- Consumes: `HeadMotionSource`, `ReplayMotionSource` (T4); `MotionRecording` (T1); `Speaker`, `RecordingSpeaker` (NavigatorAudio).
- Produces: `struct RecorderPlan { label: String; seconds: TimeInterval; promptEvery: TimeInterval = 3; cueEvery: TimeInterval = 5; static func filename(label: String, at: Date) -> String }` — filename is `<sanitised-label>-<yyyyMMdd-HHmmss>.jsonl` where the label is lowercased and every character outside `[a-z0-9-]` becomes `-`; `final class MotionRecorder { init(source: HeadMotionSource, speaker: Speaker, plan: RecorderPlan, now: @escaping () -> Date = Date.init); func run(until deadline: @escaping (TimeInterval) -> Bool) -> MotionRecording }`.

Behaviour:
- `t` of every stored sample is `raw t − first raw t`.
- For labels `nod` and `shake`, the recorder says `"<label> now"` every `promptEvery` seconds starting at `t = 2`, and appends the current `t` to `prompts`. Prompts are driven by sample time, not a timer, so the double can drive them.
- For every other label it says `"still"` every `cueEvery` seconds (review focus 5: the stream dies without audio) and records no prompts.
- `onConnection(false)` ends the recording; whatever was captured is returned (review focus 1).
- `run` returns when `deadline(t)` is true, when the source disconnects, or when the source's `start` throws (empty recording with the label set).
- `navigator motion record <label> [--seconds N]` (default 30) writes to `~/.claude/navigator/motion/<filename>` and prints the path, the sample count, the measured mean sample rate, and the number of prompts.

- [ ] **Step 1: Write the failing tests** (ReplayMotionSource with synthetic samples; RecordingSpeaker)

```swift
@Suite struct Recording {
    @Test func timestampsAreRelativeToTheFirstSample()
    @Test func nodLabelPromptsEveryThreeSecondsFromTwo()      // 11 s of samples → prompts [2,5,8,11] ± one sample; spoken "nod now" ×4
    @Test func anIncidentalLabelSpeaksACueButRecordsNoPrompts() // "typing", 12 s → spoken ≥ 2 cues, prompts == []
    @Test func somethingIsSpokenAtLeastEverySixSeconds()        // review focus 5, for both label kinds
    @Test func disconnectEndsTheRecordingAndKeepsTheSamples()   // review focus 1
    @Test func aThrowingSourceYieldsAnEmptyRecordingWithTheLabel()
    @Test func filenamesAreSanitised()                          // "../x" → "---x-<stamp>.jsonl"; "Nod/1" → "nod-1-..."  (review focus 4)
    @Test func theDeadlineEndsIt()
}
```

- [ ] **Step 2: Run: `swift test --filter Recording`** — Expected: FAIL, `cannot find 'MotionRecorder' in scope`
- [ ] **Step 3: Implement** `MotionRecorder`, `RecorderPlan`, and the `record` subcommand. The CLI builds `CoreMotionSource()` and `SystemSpeaker()`, creates the directory, writes `recording.encodedJSONL()`.
- [ ] **Step 4: Run: `swift test`** — Expected: PASS, every suite
- [ ] **Step 5: Commit** — `feat: navigator motion record, with the prompts written into the file`

---

### Task 6: Replay, sweep, watch, and the config block

**Files:**
- Modify: `Sources/navigator/main.swift` (`motion replay`, `motion watch`)
- Create: `Sources/NavigatorMotion/GestureWatcher.swift`
- Modify: `Sources/NavigatorCore/Policy/PolicyConfig.swift` (add `gesture: GestureConfig = .default`)
- Modify: `Sources/NavigatorIO/ConfigFile.swift` (read/write the `"gesture"` block)
- Test: `Tests/NavigatorIOTests/ConfigFileTests.swift` (append), `Tests/NavigatorMotionTests/GestureWatcherTests.swift`

**Interfaces:**
- Consumes: `GestureReplay` (T3), `HeadMotionSource` (T4), `GestureDetector` (T2), `Speaker`.
- Produces: `PolicyConfig.gesture: GestureConfig`; `ConfigFile.load` reads `raw["gesture"]` as a dictionary of the five keys (each optional, over `.default`); `ConfigFile.write` writes the block; `final class GestureWatcher { init(source: HeadMotionSource, speaker: Speaker, config: GestureConfig, onEvent: @escaping @Sendable (GestureEvent) -> Void); func run(until deadline: @escaping (TimeInterval) -> Bool) -> WatchSummary }`; `struct WatchSummary { samples: Int; events: [GestureEvent]; secondsToFirstSample: TimeInterval? }`.

Behaviour:
- `navigator motion replay <path…> [--sweep]`: each path is a file or a directory (all `*.jsonl` inside). Without `--sweep`, prints `GestureReplay.report` at the config from `config.json`. With `--sweep`, runs `defaultGrid()`, prints the report for `best`, and prints the five numbers as a ready-to-paste `"gesture": {…}` block; if `best` is nil, says so and prints the three configs with the fewest false positives.
- `navigator motion watch [--seconds N]` (default 60): runs `GestureWatcher` on `CoreMotionSource` with `SystemSpeaker`; on each event prints `t=… nod|shake` and plays `.acknowledged`; says `"watching"` every 5 s to keep the stream alive; at the end prints `WatchSummary` including seconds to first sample — the startup-latency number milestone 3 needs.

- [ ] **Step 1: Write the failing tests**

```swift
// ConfigFileTests — append
@Test func gestureBlockOverridesOnlyTheKeysItNames() throws   // {"gesture":{"enterRate":1.3}} → enterRate 1.3, exitRate default
@Test func gestureBlockRoundTripsThroughWrite() throws
// GestureWatcherTests
@Suite struct Watching {
    @Test func reportsEachEventAndPlaysAnEarcon()       // replay source with 2 nods → 2 events, played == [.acknowledged, .acknowledged]
    @Test func measuresSecondsToFirstSample()
    @Test func speaksToKeepTheStreamAlive()             // ≥ 1 "watching" per 6 s of samples
}
```

- [ ] **Step 2: Run: `swift test --filter "gestureBlock|Watching"`** — Expected: FAIL (missing members)
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run: `swift test`** — Expected: PASS, every suite
- [ ] **Step 5: Commit** — `feat: navigator motion replay --sweep and motion watch`

---

### Task 7: Numbers from your head, not from the spike

This task needs the person and the AirPods. The executor prepares, the person records, the executor finishes.

**Files:**
- Create: `Fixtures/motion/*.jsonl` (trimmed real recordings, ≤ 20 s each, one per label)
- Modify: `Sources/NavigatorCore/Motion/GestureConfig.swift` (`default` becomes the swept values; the "guess" comments go)
- Test: `Tests/NavigatorCoreTests/RecordedCorpusTests.swift`

- [ ] **Step 1 (person):** AirPods connected to the Mac, `swift build -c release`, then for each label, with ~3 s of stillness before the first prompt:
  ```
  .build/release/navigator motion record nod --seconds 30       # nod on each "nod now"; twice
  .build/release/navigator motion record shake --seconds 30     # shake on each "shake now"; twice
  .build/release/navigator motion record idle --seconds 30
  .build/release/navigator motion record typing --seconds 30    # type normally
  .build/release/navigator motion record look-around --seconds 30
  .build/release/navigator motion record talking --seconds 30   # talk to someone, gesture as you normally would
  .build/release/navigator motion record walking --seconds 30
  ```
- [ ] **Step 2:** `.build/release/navigator motion replay ~/.claude/navigator/motion --sweep` — Expected: a `best` config with zero false positives and ≥ 90% hits across the nod and shake files. If `best` is nil, record the incidental label that produced false positives again, watching what the head actually did, and extend `defaultGrid()` upward in `enterRate` before concluding the design is wrong.
- [ ] **Step 3:** Copy one recording per label into `Fixtures/motion/`, trimmed to ≤ 20 s (the parser is the trimmer: parse, drop samples past 20 s and prompts past 20 s, re-encode). Set `GestureConfig.default` to the chosen values with a comment naming the date, the corpus size and the sweep result.
- [ ] **Step 4: Write the test**
  ```swift
  @Suite struct RecordedCorpus {
      // Table-driven over Fixtures/motion/*.jsonl at GestureConfig.default:
      // every file scores falsePositives == 0, and nod/shake files score hits == expected.
      @Test(arguments: fixtureURLs) func theDefaultsHoldOnTheCorpus(_ url: URL) throws
      @Test func theCorpusCoversEveryLabel()   // nod, shake, idle, typing, look-around, talking, walking all present
  }
  ```
- [ ] **Step 5: Run: `swift test`** — Expected: PASS
- [ ] **Step 6: Run `navigator motion watch --seconds 60`** on hardware: nod ×3, shake ×3, then type, talk, look around. Expected: six events, nothing else. Record `secondsToFirstSample` in the spec.
- [ ] **Step 7: Commit** — `feat: thresholds from recordings, and the recordings that chose them`

---

### Task 8: Say what runs

**Files:**
- Modify: `README.md` ("Using it" gains `motion record|replay|watch`; "Not built yet" loses head gestures' first half; "Native surface" table gains CoreMotion), `docs/specs/2026-10-21-head-gestures.md` (M2 marked done with the measured numbers and startup latency).

- [ ] **Step 1:** Edit both. **Step 2:** `swift test` green. **Step 3: Commit** — `docs: motion recording and the detector, as measured`
