# airpod-responder

A macOS daemon that gives Claude Code sessions a voice in your AirPods, so you
can leave the terminal and still know what your agents are doing.

The organising idea is turn-by-turn navigation: silent almost always, speaking
at decision points, graded by urgency. Silence means on track — that is what
makes it trustworthy rather than ambiguous.

**Current state: observer.** It talks *about* what your agents do, but never
returns a decision to Claude Code. Your sessions behave exactly as they would
with no hook installed. See [The wire gate](#the-wire-gate).

## Running it

```bash
swift build -c release
.build/release/navigator install --apply     # binaries + hooks
navigator service install --apply            # launchd job, starts at login
navigator service status
```

`install` prints what it would do and changes nothing without `--apply`. It
backs up `~/.claude/settings.json` first and preserves everything already in it.

To back out completely:

```bash
navigator uninstall --apply        # remove the hooks
navigator service uninstall        # remove the launchd job
```

## Using it

```
navigator repeat            say the last thing you were told again
navigator catch-up          everything since you last asked, including
                            what was suppressed while you were muted
navigator sessions          what every live session is doing
navigator mute / unmute     stop and start talking
navigator say <text>        speak something, to check the audio path
navigator audio [--speak]   audio devices, and whether it would be suppressed
navigator learn             commands the classifier did not recognise
navigator config            the live settings
```

`repeat` replays only what you actually heard. `catch-up` deliberately includes
what you *didn't* — that is what it is for.

## What it decides

Every tool call is classified on two axes, and most land in the quiet corner.

|  | On-route | Off-route |
|---|---|---|
| **Reversible** | silent | earcon |
| **Irreversible** | speak | speak, leading with why |

Anything the classifier does not recognise reports `unknown`, which defers to the
normal on-screen prompt. Uncertainty is never treated as safety.

**It can never widen your blast radius.** It may only ever auto-allow something
both reversible and on-route, and it never auto-denies — a denied agent fails
mysteriously. That is enforced by a test enumerating every event kind against
both axes, not by convention.

## Teaching it your commands

The built-in command table will not know your tooling. Work normally, then:

```bash
navigator learn                          # what came back unknown, last 7 days
navigator learn --safe tailscale,bun     # mark them safe
navigator service restart                # rules load at startup
```

Rules live in `~/.claude/navigator/rules.json` and can be edited by hand:

```json
{
  "safe": ["tailscale", "pnpm dlx"],
  "irreversible": { "flyctl deploy": "deploy to production" }
}
```

A user rule can always flag **more**. A user *safe* rule deliberately cannot
un-flag a built-in danger — adding to the safe list is routine housekeeping done
from a log, and letting that silently disarm `rm` or a force push would turn a
convenience into the one thing this must never do.

Commands named by a path are never offered: a path cannot promise what it will
contain next week.

## Tuning how much it talks

```bash
navigator config --write        # creates ~/.claude/navigator/config.json
```

```json
{ "speechInterval": 60 }
```

`speechInterval` is the seconds between non-blocking utterances. **60 is a guess**
— the tolerable rate is a property of you, not of the event stream, and cannot be
derived from a log of a silent day. Change it, restart, see how it feels.

Blocking questions ignore the budget entirely: the agent is already stopped, so
speaking costs nothing you were not already losing.

## The wire gate

`emitDecisions` is off, and is not settable from the config file. The daemon
computes the real verdict and logs it, but returns nothing to Claude Code.

That makes blast radius zero *by construction* rather than by argument — the
encoder returns nil for every possible input, checked exhaustively. The log still
records what it *would* have done, which is how the gate eventually gets opened
with evidence rather than optimism.

## Files

```
~/.claude/bin/navigator            the daemon and CLI
~/.claude/bin/navigator-hook       what Claude Code invokes
~/.claude/navigator/
  decisions-YYYY-MM-DD.jsonl       every decision, one file per day
  config.json                      thresholds (optional)
  rules.json                       your command rules (optional)
  daemon.log                       stdout and stderr
~/.claude/navigator.sock           the socket
~/Library/LaunchAgents/com.airpodresponder.navigator.plist
```

## Reading the log

```bash
python3 -c "
import json, glob, os, collections
rows=[json.loads(l) for f in glob.glob(os.path.expanduser('~/.claude/navigator/decisions-*.jsonl'))
      for l in open(f) if l.strip()]
print(collections.Counter(r['delivered'] for r in rows))"
```

The replay harness re-runs a recorded day through the engine at a different
budget, so a setting can be tried before it is lived with:

```bash
swift run ReplayHarness ~/.claude/navigator/decisions-2026-08-12.jsonl --speech-interval 300
```

## When it goes quiet

```bash
navigator service status     # is the job loaded, and does anything answer
navigator audio              # would it speak, or is the microphone busy
tail ~/.claude/navigator/daemon.log
```

Audio is suppressed while something else is using the microphone. That check
fails *open* — if it cannot tell, it speaks — because a daemon silenced by an
unexpected error is indistinguishable from one that has crashed.

If the daemon is not running, hooks fail to connect and exit 0. **"No daemon" is
a supported state, not an error**, and is indistinguishable from having no hook
installed.

## Not built yet

Voice input, stem press, a menu bar item, audio ducking, Focus/DND detection.
The design doc records why each is deferred rather than merely missing.

## Layout

```
Sources/NavigatorCore    pure policy — no I/O, no clock reads, table-testable
Sources/NavigatorAudio   speech and earcons behind a protocol
Sources/NavigatorIO      sockets, log, launchd, installers
Sources/navigator        the daemon and CLI
Sources/navigator-hook   the binary Claude Code invokes
```

`swift test` — 274 tests, and silent: every one runs against a recording fake, so
the suite can be run while wearing the thing it tests.

Design and implementation plans are in `docs/`.
