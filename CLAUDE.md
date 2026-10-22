# airpod-responder

Read `README.md` first; it is the current description of what runs. The design
and the implementation plans are in `docs/`.

## Rules

- **No AI attribution in anything committed.** No `Co-Authored-By`, no
  `Claude-Session:` trailer, no "Generated with" line — in commit messages, PR
  bodies, code comments, or docs. The history before 2026-10-21 has these and is
  being left alone; nothing after it may.
- Tests first. Every suite runs silent, against `RecordingSpeaker`; nothing in
  `swift test` may make a sound or need hardware.
- `NavigatorCore` stays pure: no I/O, no clock reads. Anything that touches a
  device goes in `NavigatorAudio` or a sibling module behind a protocol.
- The wire gate (`emitDecisions`) is the blast-radius guarantee. Opening it is a
  deliberate, logged act, never a side effect of another change.

## Build and test

```bash
swift build
swift test
```
