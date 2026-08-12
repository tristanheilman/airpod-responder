# AirPod Responder — Design

**Date:** 2026-08-11
**Status:** Design approved, pending spec review

## What this is

A macOS daemon that lets you keep working while Claude Code agents run, by giving
them a voice in your AirPods and a way to take your answer without you touching
the terminal.

The organizing metaphor is **turn-by-turn navigation**. GPS is the only ambient
voice interface in wide use that people don't mute, and the reason is discipline:
it is silent almost always, it speaks at decision points, it grades urgency, and
it can afford silence because it knows the route. Silence means "on track" — that
is what makes it trustworthy rather than ambiguous.

This is a personal tool. It is not aimed at a market.

## Why it's worth building

The interesting half of hands-free coding is already commoditized. Claude Code
ships `/voice` for dictation. Wispr Flow, superwhisper, and Aqua Voice all target
speaking into coding agents. Talon and Cursorless own voice-driven structural
editing. Community projects (`claude-code-notify`, `cc-hooks`, `Herald`) already
wire `Stop` hooks to `say`.

What none of them do is decide **what has earned the right to interrupt you**,
across several sessions at once. TTS is trivial; the policy is the product.

Prior art in the adjacent category is also a warning. Crystal was deprecated in
February 2026 in favour of a paid successor; Bloop, behind Vibe Kanban, shut down
in early 2026. Parallel-agent tooling is hard to monetize. Hence: personal tool,
no business case required.

## Non-goals

- **Not a dictation tool.** Claude Code's `/voice` already does that.
- **Not a visual dashboard.** Conductor, Claude Squad, and others cover it.
- **No webcam hand tracking.** Gorilla arm is a well-documented killer, and the
  answers here are one bit. The stem press is the steering-wheel button; hand
  gestures are waving at the windshield. Revisit only for continuous control.
- **No iOS app.** `CMHeadphoneMotionManager` is unavailable on macOS, so head
  gestures can't work here anyway; iOS is a separate track (see Deferred).
- **No reverse-engineered Bluetooth.** AirPods motion on macOS is reachable only
  through undocumented protocol work that breaks on firmware updates.

## Architecture

One long-running local daemon — *the navigator* — plus a small compiled hook
binary that every Claude Code session invokes.

```
Claude Code session ──PreToolUse/Stop/Notification──▶ hook binary
                                                          │
                                              Unix socket (~/.claude/navigator.sock)
                                                          ▼
                                                    navigator daemon
                                        ┌─────────────┼─────────────┐
                                  session registry  policy engine  audio I/O
                                     (route, state)    (tiering)   (TTS/STT/earcons)
                                                          │
                                                    AirPods ◀──▶ you
```

Global hooks in `~/.claude/settings.json` point every session at the daemon, so
this works for any session in any directory with no per-project setup.

### Why hooks, not the alternatives

`PreToolUse` hooks are synchronous, so the hook is simultaneously the outbound
event *and* the inbound answer channel — the daemon can speak a question and
return your verdict as the hook's result. `Stop` can return `decision: "block"`
with a reason, which is how a spoken redirect gets fed back into a conversation.

**Correction (verified against the hooks reference, 2026-08-11).** An earlier
draft of this doc claimed `permissionDecision: "allow" | "deny" | "ask" |
"defer"`. The real contract has only **`"allow"` and `"deny"`**. Deferring is
still available and still means exactly what we wanted — it is just spelled
*silence*:

> Exit code 0 with no output means the hook has no decision to report, so the
> tool call continues through the normal permission flow. The hook can deny the
> call, but staying silent doesn't approve it.

A timed-out hook behaves identically — it "doesn't block the tool call. The call
continues through the normal permission flow." So the whole failure story below
holds unchanged; `defer` is an engine-internal verdict that the wire encoder
renders as an empty result. `"ask"` has no wire representation at all and is not
modelled.

`PermissionRequest` is a separate event that fires precisely when a tool call
needs a permission decision. It is a closer fit for the voice-answer path than
`PreToolUse` and should be evaluated in the daemon plan.

Rejected alternatives:

- **tmux wrapping + terminal scraping.** Fragile, breaks whenever the UI changes,
  and strictly worse now that hooks can answer.
- **MCP server the agent calls.** Depends on the agent choosing to ask, and never
  sees permission prompts at all.

### Components

| Component | Responsibility | Depends on |
|---|---|---|
| `hook` binary | Read event JSON on stdin, round-trip to daemon, emit decision JSON. Nothing else. | Unix socket |
| Session registry | Track live sessions: id, cwd, title, declared route, state, event history. | `SessionStart`, `SessionEnd` |
| Policy engine | Classify each event into a tier. The product. | Registry, budget, mute state |
| Audio I/O | TTS, earcons, STT, ducking, one-utterance-at-a-time serialization. | AVFoundation / CoreAudio |
| Response listener | Stem press via `MPRemoteCommandCenter`; speech via `SFSpeechRecognizer`. | MediaPlayer, Speech |
| Menu bar item | Session count and daemon liveness. The only visual surface. | AppKit |

The hook binary must be **compiled**, not a shell script, and is written in
**Swift with Foundation**, sharing its wire-format types with the daemon.

Measured on this machine (macOS 26.6, M2 Max, 300 warm runs each):

| Implementation | Startup |
|---|---|
| `sh` + `jq` | 5.86 ms |
| Swift + Foundation + `Codable` | 3.34 ms |
| Swift, stdlib only | 2.36 ms |
| Rust | 2.08 ms |

The compile decision holds — `sh`+`jq` is 2.8× the Swift figure, and that was a
single trivial `jq` call where a real hook would make several. But an earlier
draft of this doc put the shell cost at 20–50ms, which is wrong by 4–8×, and the
same overestimate wrongly ruled out Foundation. Foundation costs ~1ms, not the
15–30ms assumed; on current macOS it is in the dyld shared cache.

So the choice is made on correctness, not speed. Foundation-free Swift would mean
hand-rolling a JSON parser on the critical path of every matched tool call, where
bash commands with embedded quotes and newlines are routine input — a bad trade
for 1ms. Rust is genuinely faster, but by 1.3ms against a hook whose own budget is
a ~5ms socket-connect timeout and a 20s decision deadline; the cost is defining
the wire format twice and keeping two languages in sync by hand. Swift on both
sides means one set of `Codable` structs, so the contract cannot drift.

## Event → tier mapping

| Tier | Delivery | Hook events |
|---|---|---|
| Decision point | **Speech**, blocking | `PreToolUse` |
| Needs input | **Speech** | `Notification` matched on `notification_type` ∈ {`agent_needs_input`, `permission_prompt`}; `Elicitation` |
| Off-route, irreversible | **Speech** | `PreToolUse` args; `FileChanged` |
| Off-route, reversible | **Earcon** | same |
| Failure | **Earcon**, coalesced | `PostToolUseFailure`, `StopFailure` |
| Completion | **Silent queue** | `Stop`, `TaskCompleted`, `SubagentStop` |
| Idle | Silent queue | `TeammateIdle` |

## Policy engine

### Invariant

**The navigator can never widen your blast radius.** It sits inside the permission
path, so it may auto-*allow* only reversible actions. On any uncertainty it returns
`defer` and the normal on-screen prompt appears. It never auto-denies — that makes
agents fail mysteriously.

### Classifier

Two axes:

| | On-route | Off-route |
|---|---|---|
| **Reversible** | silent, auto-allow | earcon |
| **Irreversible** | speak | speak, lead with the reason |

**Reversible:** editing a tracked file, creating a branch, running tests, reading.

**Irreversible** (more precisely: irreversible *or externally visible* — anything
you cannot quietly undo on this machine): force push, `git reset --hard`, history
rewrites, `rm -rf`, `migrate reset`, `DROP`, package publishing, sending anything,
network egress to an unfamiliar host, dependency installs.

Most tool calls are reversible and on-route, so most are silent. That is what makes
an all-day tool viable.

### Route model (v1: deliberately boring)

The route is captured from the session's first `UserPromptSubmit` — no new
ceremony. Off-route is then evaluated by an **explicit, predictable classifier**:

1. Does this write outside the session's `cwd` and any declared additional dirs?
2. Is the command on the irreversible list?

That is the whole v1 rule. Model-based route reasoning is deferred. Rationale: if
off-route detection is fuzzy and occasionally wrong, you stop trusting the silence,
and the tool degrades into a noisy pager. Predictable beats smart for the component
that decides whether to interrupt you.

### Speech budget

- **Hard blocks are free.** The agent is already stopped; speaking costs nothing
  you weren't already losing and buys back the context switch. No budget applies.
- **Everything else is rationed** by a token bucket, initially **one non-blocking
  utterance per 5 minutes**. On an empty bucket, degrade to earcon, then to queue.

### Patterns, not events

One failing test is noise; a session failing the same test five times is signal.
Failures coalesce into a single earcon. A **thrash detector** — same error
signature repeating with no file changes between attempts — promotes to speech:
*"Tests session has been stuck on the same error for six minutes."* Rare,
valuable, and otherwise discovered forty minutes late.

### Mute and flow detection

Use the OS signals that already exist rather than inventing a competing one:
macOS Focus / Do Not Disturb, full-screen state, and whether another app holds the
mic (you're on a call). Plus explicit `"mute for an hour"`.

When muted, speech suppresses entirely and everything defers to screen — the same
code path as the daemon being dead, so it is exercised constantly.

### Concurrency

**Only one question is ever in flight.** A second decision point arriving while one
is live returns `defer` immediately rather than queueing. Silently stalling an agent
behind another agent's ten-second exchange is worse than showing you a prompt.

## Response channel

- **Stem press** via `MPRemoteCommandCenter` for one-bit answers: single = approve,
  double = deny, triple = "tell me more".
- **Voice** via `SFSpeechRecognizer` for anything with content, including redirects
  fed back through `Stop`'s `decision: "block"` + reason.
- **Pull commands:** `"status"` (digest of all sessions), `"what's <session>
  doing"`, `"repeat"`, `"mute for an hour"`.

The daemon must claim the Now Playing slot to receive stem presses, which contends
with Spotify and Music. Contention behaviour is an open question (see Risks).

## Failure modes

Every failure path lands on **plain Claude Code**. No state to repair, nothing to
undo. This is what makes it safe to run all day.

| Failure | Behaviour |
|---|---|
| You don't answer | 20s deadline → `defer` → normal on-screen prompt |
| Daemon not running | Socket connect fails (~5ms timeout) → hook exits 0 → normal flow. **"No daemon" is success, not error.** |
| Daemon wedged | Hook enforces its *own* read deadline rather than trusting the daemon; Claude Code's `timeout` config is a second backstop |
| Two questions at once | Second returns `defer` immediately |
| Muted / on a call | Everything defers |
| AirPods disconnected | Treated as muted |

## Observability

Every policy decision is logged: event, session, classification, tier assigned,
whether it was suppressed and why. This is the primary v1 deliverable alongside the
daemon itself — the budget and thresholds are guesses, and the log is how they get
replaced with numbers from real days.

## Testing

- **Policy engine is pure.** Events in, tier decisions out, no I/O. Table-driven
  tests over recorded event sequences; this is where most testing effort goes.
- **Hook binary:** contract tests over stdin/stdout JSON, including the no-daemon,
  wedged-daemon, and timeout paths.
- **Replay harness:** feed a recorded day of real hook events through the policy
  engine and count utterances. This is how the budget gets tuned.
- **Audio I/O:** thin by design, verified manually.

## v1 scope

**In:**
- Daemon, hook binary, session registry
- Reversibility × route classifier with the boring route model
- Speech / earcon / queue tiers, blocking decision points
- Stem press + voice response, `status` pull command
- Speech budget, failure coalescing, thrash detection
- Focus/DND-aware muting
- Menu bar liveness indicator
- Decision logging and replay harness

**Deferred:**
- Learned silence (auto-promoting repeated approvals) — riskiest piece, needs
  trust data that doesn't exist yet
- Model-based route reasoning
- Webcam hand gestures for continuous control
- iOS track (Claude client with head gestures via `CMHeadphoneMotionManager`)

## Risks

- **Critical path.** `PreToolUse` sits in front of every matched tool call. Narrow
  matchers, local socket, aggressive client-side deadlines, `defer` on doubt.
- **Now Playing contention.** Claiming the media slot fights with music apps.
  Unresolved; may force a hotkey fallback.
- **Platform risk.** Anthropic ships into this space and could absorb ambient
  notification. Acceptable for a personal tool.
- **The budget is a guess.** Mitigated by logging and the replay harness, not by
  getting the number right up front.

## Resolved questions

- **Hook language.** Swift with Foundation, sharing wire-format types with the
  daemon. See Architecture above for the measurements behind this.
- **Stem press / Now Playing contention.** Deferred out of the first build.
  Voice response plus a global hotkey ship first; claiming the media slot becomes
  its own experiment once the rest works. An unresolved platform question should
  not gate the parts that don't depend on it, and by then we'll know whether the
  stem press is actually missed.
- **Build order.** Policy engine first, as a pure library with a replay harness
  and no daemon. It is the product, it is the part with real design risk, and it
  is the part that can be exhaustively tested with no audio hardware in the loop.

## Open questions

- Should `status` read the queue in priority order or session order?

### Answered: does the thrash detector get the file-change data it needs?

Partly, and the limit is worth knowing before relying on it.

There is **no `watchPaths` configuration** — that was invented in an earlier
draft. `FileChanged` is configured with `matcher` set to *literal filenames*
(e.g. `.envrc|.env`), and its payload carries `file_path` and `change_type`
(`created|modified|deleted`).

So file-change data exists, but only for filenames enumerated up front. It cannot
tell you "some file in this project changed", which is what the thrash detector
actually wants — it wants to know whether the agent made *any* progress between
two identical failures.

The engine therefore takes its progress signal from `PreToolUse` on a writing
tool instead, which fires for every edit regardless of path and needs no
configuration. `FileChanged` remains useful for the narrower job it is good at:
noticing edits to a specific sensitive file.
