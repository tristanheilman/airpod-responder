# airpod-responder

A macOS daemon that gives Claude Code sessions a voice in your AirPods, so you
can leave the terminal and still know what your agents are doing.

The organising idea is turn-by-turn navigation: silent almost always, speaking
at decision points, graded by urgency. Silence means on track — that is what
makes it trustworthy rather than ambiguous.

**Current state: it can answer, if you let it.** With the wire gate closed —
the default — it only talks *about* what your agents do, and your sessions
behave exactly as they would with no hook installed. With the gate open, a
permission prompt becomes a spoken question, and `navigator approve` or `deny`
from any terminal answers it. See [Answering](#answering) and
[The wire gate](#the-wire-gate).

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

## Answering

```bash
navigator gate --open        # prints what changes and what it trusts, then writes
navigator service restart
```

From then on, when a session hits a permission prompt the AirPods say
*"app wants to force push. Running git. Approve?"* and the tool call waits.

```
navigator approve           let it run
navigator deny              refuse it
navigator escalate          send it to the on-screen prompt now
```

Nobody answers for 20 seconds → the on-screen prompt appears, exactly as if
nothing were installed. Only one question is ever held; a second one arriving
while the first waits goes straight to the prompt. On a call (microphone in
use) the question is not spoken and so is not asked — prompt, immediately.

Three deadlines back each other up, strictly ordered: the daemon holds for
**20 s**, the hook gives up at **25 s**, Claude Code kills the hook at **30 s**.
Only `PermissionRequest` gets that rope; every other event keeps its 250 ms /
5 s, so a wedged daemon still costs the silent majority what it always did.

**What this trusts.** Anything that can run `navigator approve` on this
machine can answer. The session being asked cannot — its tool call is blocked —
but a process it started earlier, or a second session, could; so could an
agent that edits `config.json` and restarts the service. The classifier flags
`navigator …` commands as irreversible so an agent doing any of that is
announced, never silent, but it cannot be prevented. A head gesture is the
channel an agent cannot reach, and is the next milestone.

Opening the gate does **not** auto-allow anything. The engine's own *allow*
verdicts for reversible, on-route calls stay home unless `autoAllow` is also
set in `config.json` — a separate decision, still off.

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

`emitDecisions` is off by default. Closed, the daemon computes the real verdict
and logs it, but returns nothing to Claude Code — the encoder returns nil for
every possible input, checked exhaustively over every event and every verdict,
so blast radius is zero *by construction* rather than by argument.

It opens only when `config.json` holds **both** `"emitDecisions": true` and
`"iUnderstandThisAnswersClaudeCode": true`. Two keys so that an edit aimed at
`speechInterval` cannot open it by typo or by pasting an example. `navigator
gate --open` writes them; `navigator config --write` leaves them alone; the
daemon's startup banner says which mode it is in.

## Files

```
~/.claude/bin/navigator            the daemon and CLI
~/.claude/bin/navigator-hook       what Claude Code invokes
~/.claude/navigator/
  decisions-YYYY-MM-DD.jsonl       every decision, one file per day
  config.json                      thresholds and the gate keys (optional)
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

Head gestures (next), voice input, stem press, a menu bar item, audio ducking,
Focus/DND detection. `docs/specs/2026-10-21-head-gestures.md` is
the roadmap; the design doc records why the rest is deferred rather than
merely missing.

## Layout

```
Sources/NavigatorCore    pure policy — no I/O, no clock reads, table-testable
Sources/NavigatorAudio   speech and earcons behind a protocol
Sources/NavigatorIO      sockets, log, launchd, installers
Sources/navigator        the daemon and CLI
Sources/navigator-hook   the binary Claude Code invokes
```

`swift test` — 343 tests, and silent: every one runs against a recording fake, so
the suite can be run while wearing the thing it tests.

Design and implementation plans are in `docs/`.
