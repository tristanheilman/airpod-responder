# Roadmap

## Goal
Navigator gives Claude Code sessions a voice in the owner's AirPods: silent
almost always, speaking at decision points, graded by urgency, and able to
take an answer without the keyboard. Done means the owner can step away from
the desk, hear what needs them, and answer a permission prompt with a nod,
safely, with every behaviour tested without hardware.

## Phases
### Phase 1 — Round trip [done]
Evidence: M1 merged to main: the daemon, hook binary, policy engine, TTS, CLI and the closed-by-default wire gate, with `navigator approve/deny/escalate` answering prompts.
### Phase 2 — A nod, measured [current]
Exit when: `GestureConfig` defaults are tuned from real recordings committed under `Fixtures/motion/`, the replay sweep in `swift test` scores them above the plan's thresholds, and the README documents `navigator motion record` and `watch` (Tasks 7 and 8 of `docs/plans/2026-10-25-gesture-detection.md`).
### Phase 3 — A nod is the answer [next]
Exit when: a `GestureAnswerer` turns a detected nod or shake into approve or deny for the parked permission prompt, only while the wire gate is open; tests drive it end to end with `ReplayMotionSource` and `RecordingSpeaker`.
### Phase 4 — Everyday polish
Exit when: speech ducks other audio, Focus / Do Not Disturb mutes it, and a menu bar item shows state and mute; each has a hardware-free test.

## Side quests
- A `navigator doctor` command that checks hooks, the launchd service, permissions and the wire gate, and says what to fix.
- Replay corpus tooling: label and trim recordings so new gesture fixtures are cheap to add.
- A transcript of what was spoken and answered, for `catch-up` across days.
- CI coverage notes: which behaviours only real AirPods can exercise, kept current in the README.

## Reserved for the owner
- Opening the wire gate (`emitDecisions`, `iUnderstandThisAnswersClaudeCode`) or changing its defaults.
- Anything that edits `~/.claude/settings.json`, installs hooks or changes the launchd service.
- Recording motion data and tuning thresholds against real AirPods (needs the owner wearing them).
- Permission prompts and privacy surfaces: `NSMotionUsageDescription`, microphone use, `Info.plist`.
- Confirming irreversible approvals by gesture (double nod) — a safety decision, not a feature.

## Settled
- No iOS app: CoreMotion works on macOS directly.
- No webcam hand tracking (arm fatigue).
- No reverse-engineered Bluetooth protocol.
- No spoken approval codes such as `navigator approve 47` (declined 2026-10-21).
- Park on `PermissionRequest` only, not `PreToolUse`: Claude Code has no `escalate` decision.
