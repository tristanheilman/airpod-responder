# Head gestures — roadmap

**Date:** 2026-10-21
**Status:** Proposed, awaiting approval
**Supersedes:** the "No iOS app" non-goal and the "iOS track" deferral in
`2026-08-11-airpod-responder-design.md`. Both rested on the claim that
`CMHeadphoneMotionManager` is unavailable on macOS. It is available: a bare
executable on this Mac reports `isDeviceMotionAvailable: true`
(`spikes/head-motion/`). Head gestures therefore live in the daemon, and there
is no phone in this plan.

## What changes

The observer build narrates and never acts. This roadmap makes it act, in three
steps that each leave the tool usable:

1. **Answer with a typed command.** Prove the round trip through Claude Code
   before any sensor is involved.
2. **Detect a nod and a shake from recordings.** Pure code, tuned from real
   motion files the same way the speech budget is tuned from the decision log.
3. **Let a nod be the answer.** The gesture is one more source of
   approve/deny arriving on an already-open question.

The answering plan (`plans/2026-08-13-answering.md`) is the base for step 1
and the skeleton for step 3. Where this roadmap departs from it, the departure
is stated and reasoned below rather than silently replaced.

## Invariants that do not move

- **The wire gate stays the only way out.** `emitDecisions` governs every byte
  that reaches Claude Code: permission answers, escalations, and later
  instructions. The exhaustive "closed gate emits nothing" property grows to
  cover each new path, including a gesture-sourced answer.
- **Blast radius cannot widen.** Auto-allow only for reversible and on-route;
  the engine never auto-denies. An *answered* deny — from a keyboard or a shake
  — is a different thing and is allowed.
- **The hook exits 0 on every path**, including being made to wait and then
  having the daemon die under it.
- **Every parked question releases.** Three independent deadlines
  (daemon < hook < Claude Code's `timeout`). Unanswered resolves to
  `escalate` — the on-screen prompt — never to `allow`.
- **One question in flight.** A second is escalated immediately, not queued.
- **Mute, mic-in-use and disconnected AirPods all mean "do not act."** A nod
  during a call does nothing; the question escalates at its deadline exactly
  as if nobody had nodded.
- **`swift test` stays silent and hardware-free.** Motion comes from
  `ReplayMotionSource` in tests; sound from `RecordingSpeaker`.

## Milestone 1 — the round trip

**Done when:** with the gate open, a real session hits a permission prompt,
the AirPods say "Approve?", `navigator approve` in another terminal lets the
tool run, and the decision log shows `answer: allow, source: terminal`. With
no answer, the on-screen prompt appears after ~20 s. Plus: the motion spike
has been run with AirPods in and its output recorded in this doc.

### 1a. The spike (already written, needs your hardware)

`spikes/head-motion/run.sh`. Record here: whether the permission prompt
appears, what `authorizationStatus` becomes, the sample rate it delivers, and
whether `pitch`/`yaw` visibly track a nod and a shake. Also whether updates
still arrive when the binary is launched by launchd rather than Terminal —
TCC attributes an unbundled binary to its responsible process, and a daemon
that only has motion access when started from a terminal is not a daemon.

**Native surface it adds:** `CoreMotion.CMHeadphoneMotionManager`, and an
`NSMotionUsageDescription` embedded in the `navigator` binary via
`__TEXT,__info_plist` (SwiftPM `linkerSettings` on the executable target). No
entitlement; no app bundle.

### 1b. Answering plan, Tasks 1, 2, 3, 5, 6, 7 — with two departures

- **Park on `PermissionRequest`, not `PreToolUse`.** The plan parks
  `PreToolUse`. Now that `PermissionRequest` is being handled in the same
  milestone, parking both would ask you the same question twice for one tool
  call, and a timed-out `PreToolUse` has no way to say "show the prompt" except
  silence. `PermissionRequest` has `escalate`, which says exactly that.
  `PreToolUse` stays an instant observer: it announces, logs, and returns
  nothing. Cost: in `auto` mode nothing needs permission, so nothing is asked —
  that is the mode's contract, and the heads-up announcement still fires.
- **Task 4 (`tell` via `Stop` block) is deferred to the voice milestone.** A
  nod cannot carry an instruction, and the two gesture milestones do not need
  it. It stays in the plan unchanged.

Concretely:

- `HookEventKind.permissionRequest`; `HookOutput.escalation`; `encode` spells
  `decision` (not `permissionDecision`) for this kind. Gate test extended.
- `ParkedQuestion` in `NavigatorCore`: id, session, event, parked-at, deadline.
  `Answer { verdict: allow|deny, source: terminal|gesture|voice, at }`.
  `DecisionRecord` gains `answer` and `answerSource`, so the log can later say
  how often a nod was the answer and how often it timed out.
- `NavigatorServer`: a `PermissionRequest` decision point holds its connection
  open on the worker thread, waits on a condition for an answer, and replies
  with allow/deny/escalate. `NavigatorCommand.approve` / `.deny` arrive on a
  separate connection and resolve it. Deadline `questionDeadline` (20 s).
- Hook: `NAVIGATOR_DEADLINE_MS` default stays 250 for every event kind except
  `PermissionRequest`, which uses 25 000. The installer writes `timeout: 30`
  on that matcher only. The silent majority pays nothing.
- `canAcceptAnswers` becomes derived (`emitDecisions && an answer source is
  registered`) rather than a hand-set flag, so phrasing cannot drift from
  capability again.
- Opening the gate: `emitDecisions: true` in `config.json` is honoured only
  when a second key, `iUnderstandThisAnswersClaudeCode: true`, is also set,
  and the daemon logs `wire gate OPEN` at startup. Two keys because a config
  edit meant to change `speechInterval` must not be able to open it by typo.
- End-to-end test against the real socket and real hook binary: parked, still
  waiting after 1 s, answered from another connection, hook prints `allow`,
  exits 0. Then unanswered: prints `escalate`, exits 0, takes ~deadline. Then
  daemon killed mid-question: exits 0.

## Milestone 2 — a nod, measured

**Done when:** `navigator motion watch` with AirPods in prints `nod` or
`shake` once per deliberate gesture, prints nothing while you type, look
around, talk, and walk, and the thresholds that make that true were chosen by
replaying recorded files, not by hand. That is the first thing you put on and
feel.

### 2a. Recording

`navigator motion record <label> [--seconds 30]` writes
`~/.claude/navigator/motion/<label>-<timestamp>.jsonl`, one sample per line:
`t`, `pitch`, `yaw`, `roll`, `rotationRate.{x,y,z}`, `userAcceleration.{x,y,z}`.
Labels for the first corpus: `nod`, `shake`, `idle`, `typing`, `look-around`,
`talking`, `walking`. Several files per label, from more than one sitting.

A trimmed subset is committed under `Fixtures/motion/` so the detector tests
are reproducible on a machine with no AirPods.

**Module:** new `NavigatorMotion` target wrapping CoreMotion behind
`HeadMotionSource` (`start`, `stop`, `samples` stream), with
`ReplayMotionSource` reading the JSONL. Same shape as `NavigatorAudio`:
hardware behind a protocol, test double in the module.

### 2b. Detector

`GestureDetector` in `NavigatorCore`. Pure: samples in, `Gesture.nod` /
`.shake` events out, no clock reads (time comes from the sample).

Design, to be confirmed by the recordings:

- Use **rotation rate** (gyro), not attitude. A nod is pitch-rate oscillation,
  a shake is yaw-rate oscillation; attitude's yaw reference drifts and depends
  on where you were facing when updates started.
- A gesture is **at least two opposite-sign half-cycles** on one axis within a
  window (~0.8 s), each exceeding an *enter* threshold.
- **Hysteresis:** a half-cycle ends only when the rate falls below a lower
  *exit* threshold, so jitter at the peak cannot double-count.
- **Refractory period** (~1 s) after a fire; samples during it are consumed and
  cannot start a new gesture. One nod fires once.
- **Axis exclusivity:** if both axes are energised in the window, fire nothing.
  Looking around while nodding is incidental movement, not an answer.

All five numbers live in `GestureConfig` and are read from `config.json` like
the policy numbers.

### 2c. Choosing the numbers

`navigator motion replay <dir> [--sweep]`, in the mould of `ReplayHarness`:
run every file through the detector, print per label the gestures detected
against the gestures expected (one per `nod`/`shake` file, zero otherwise),
and under `--sweep` print the same for a grid of thresholds. Selection rule,
in this order: zero false positives on the incidental labels; then the
highest recall on `nod` and `shake`; ties broken toward the larger refractory.

Tests are table-driven over `Fixtures/motion/`: every `nod` fixture yields
exactly one `.nod`, every `shake` exactly one `.shake`, every incidental
fixture yields nothing, and a fixture of two nods 0.5 s apart yields one.

### 2d. Live check

`navigator motion watch` runs the real source through the real detector and
prints each event with its timestamp, playing `.acknowledged` so you can feel
it without looking. Also reports the measured startup latency of motion
updates, which decides a milestone-3 question below.

## Milestone 3 — a nod is the answer

**Done when:** a real session asks "Approve?", you nod, the tool runs, and the
log shows `source: gesture`. Shake → `deny`. Nod on a call → nothing, prompt
appears at the deadline. Nod with no question parked → nothing. Gate closed →
nothing reaches the wire even with a nod, and the gate property test proves it.

- `GestureAnswerer` in `NavigatorIO`: subscribes to `GestureDetector` events,
  and when a question is parked and answers are accepted, resolves it with
  `.allow` for nod, `.deny` for shake, source `.gesture`. Every other
  condition — muted, `microphoneIsBusy()`, no question, AirPods not connected
  (`headphoneMotionManagerDidDisconnect`) — drops the gesture and logs why.
- **Motion runs only while a question is parked**, started on park and stopped
  on resolve, if 2d measured startup under ~500 ms (the question is spoken
  first, which takes longer than that). Otherwise always-on while AirPods are
  connected. Start-on-park is preferred: it saves battery and makes a stray
  nod with no question structurally impossible, not merely ignored.
- Feedback: `.acknowledged` on a recognised answer, then "Approved" / "Denied"
  spoken, so you know it landed without looking.
- Phrasing flips to a question automatically via the derived
  `canAcceptAnswers` once a gesture source is registered.
- Server tests with a fake gesture source cover each bullet of the done
  criteria; the end-to-end test from milestone 1 gains a gesture-answered run.

## After this

- **Voice** — answering plan Task 4 (`tell` → `Stop` block) plus
  `SFSpeechRecognizer`. Gestures cover the one-bit answers; voice carries
  content. Out of scope here so it does not gate the milestones above.
- **Confirming irreversible approvals** — whether a single nod should be
  enough to approve a force push, or whether the daemon should say "Nod again
  to confirm." Decide from the milestone-2 false-positive rate, not up front.
- Update `README.md` and the design doc's non-goals once milestone 1 lands.

## Native surface, in total

| API | Module | Since |
|---|---|---|
| `CoreMotion.CMHeadphoneMotionManager` | `NavigatorMotion` | this roadmap |
| `__info_plist` with `NSMotionUsageDescription` | `navigator` target | this roadmap |
| `CoreAudio` default-input "running somewhere" query | `NavigatorAudio` | existing |
| `AVSpeechSynthesizer` / `NSSound` | `NavigatorAudio` | existing |
| `launchd` LaunchAgent, `AF_UNIX` socket | `NavigatorIO` | existing |

Nothing else. No app bundle, no entitlements, no Bluetooth protocol work.

## Risks

- **TCC and launchd.** If motion access cannot be granted to a launchd-started
  unbundled binary, the daemon needs a minimal `.app` wrapper. The spike
  answers this before any code is written against it.
- **Sample rate and latency** are unknown until the spike runs. The detector
  is written against timestamps, not sample counts, so a different rate
  changes thresholds, not design.
- **False positives are the whole product.** A nod detector that fires while
  you talk approves things you did not see. Hence the selection rule puts zero
  incidental false positives ahead of recall, and the question escalates
  rather than auto-allows when in doubt.
