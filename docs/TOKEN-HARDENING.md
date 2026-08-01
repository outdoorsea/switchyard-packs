# Token hardening: don't pay to idle

*Operating guidance for any city consuming these packs. Companion: `OPERATING-MODEL.md`.*

## The one thing to understand

Agents here run `wake_mode = "fresh"`. **Each time a session is (re)spawned, its
entire system prompt + template fragments are re-billed as input tokens.** So the
dominant cost of a *quiet* city is not the work it does — it is how often
resident agents wake or respawn to discover there is nothing to do.

Optimize **wake/respawn frequency first.** Everything below is a corollary.

Complementary lever, in [`OPERATING-MODEL.md`](OPERATING-MODEL.md#token-economy):
pin a cheaper `model` on the mechanical tier. That cuts the *price* of each wake;
this doc cuts the *count*. Do both.

> **Most of this document used to be longer.** On the gastown lane the always-on
> tier — a `witness` per rig, plus `deacon` and `boot` city-wide — dominated an
> idle city's bill, and the top three levers here were all about calming it down.
> gascity ships no always-on crew at all, so that entire cost class is gone
> structurally rather than by tuning.
>
> That is not free. See
> [What you give up](OPERATING-MODEL.md#what-you-give-up): the cheapest watcher
> is the one that isn't running, and it also isn't watching. A gascity city is
> much cheaper to idle and notices less.

## The levers, ranked

What is left to tune is what you chose to make resident: the mayor, one
coordinator per rig, and the worker pools.

### 1. Coordinator idle heartbeats
A pinned coordinator defaults to `idle_timeout = "1h"`, so an idle city pays a
fresh LLM turn per coordinator per hour to find an empty queue. This is now the
largest idle line item. Raise it on the non-interactive ones:

```toml
[[patches.agent]]
  name = "<rig>/<coordinator>"
  idle_timeout = "168h"      # switchyard-ops nudges it on a real cadence anyway
```

The sweeps (`intake-sweep`, `answer-sweep`, `judge-sweep`) are what actually
drive a coordinator's work, and those run on their own timers. A short
`idle_timeout` on top of them buys nothing but no-op wakes.

Leave the **mayor** hot if a human talks to it.

### 2. Worker pool blast radius
The `brakeman` pool defaults to `max_active_sessions = 4`. Under a drain-churn
storm (the controller drains a mid-build worker that emitted no output for a few
minutes → reconciler respawns it → repeat), that is several parallel full-prompt
reloads shipping nothing. Cap it per rig:

```toml
[[patches.agent]]
  name = "<rig>/switchyard-ops.brakeman"
  max_active_sessions = 2
```

The same applies to `answerer` and `judge`, whose sweeps can otherwise fan out
adhoc sessions faster than they drain.

### 4. `intake-sweep` cadence
`intake-sweep` (default `interval = "4h"`) nudges **every** coordinator into a
triage pass — a forced LLM turn — even when its switchyard intake is empty (6
no-op wakes/day/coordinator). The *right* fix is a mechanical emptiness gate
(skip the nudge when the queue is empty). Today that read is available only over
MCP, from inside a session — the shell-side `switchyard-gt` CLI has the token +
switchyard.work API plumbing but is push-only (`patrol`), with no read
subcommand. So until a `switchyard-gt intake --count`-style read exists (see
"Future work"), the only shell-level lever is cadence: raise `intake-sweep.toml`'s
`interval` to `8h`/`12h` for a low-throughput city.

### 5. `mol-idea-to-plan` fan-out
One run dispatches ~24 `mol-review-leg` sessions (6 PRD-review + 6 design + 3+3
alignment rounds ×2), each a fresh worker. Human-triggered, so not a 24/7 drip —
but the most expensive single operation in the stack. For a cost-sensitive city,
trim the two big legs 6→3 and collapse the 3+3 rounds to 1–2.

## Already cheap — do NOT "optimize" these

These orders run mechanical `exec` scripts with **no LLM**; leaving them frequent
is correct:

- `pool-spawn` (1 min) — the pack's most frequent order at 1440 runs/day. The
  order body is itself zero-LLM: a handful of `gc rig`/`agent`/`bd`/`session
  list` reads, a `jq` classification, then a `gc session new` and a `gc bd
  update`. Note the asymmetry with the rest of this list, though — what it spawns
  *is* a paid worker. What keeps that honest is that it spawns one only when a
  rig has demand a worker could actually claim **and** a free WIP slot, so the
  spend tracks real queued work and is capped by the pool's
  `max_active_sessions`. Do not stretch the cadence to save tokens: it buys
  nothing (an idle city spawns nothing at 1m either) and costs the guarantee that
  a slung bead gets a worker within an order cycle.
- `publish-gate` (5 min) — reads closed worker beads, mails the mayor about any
  with no PR. 288 runs/day, zero LLM, and it reports each bead once, so a
  standing problem does not become a standing bill.
- `config-drift`, `stray-reaper` (6 h) — diff/detect + mail only.
- `loop-health` (30 min) — process/probe checks; only nudges sessions that are
  *missing* (normally none), so normally zero LLM.

Pinned coordinators at `idle_timeout = "168h"` are also already efficient — they
wake ~weekly, not hourly. Don't "fix" them down.

## Patch naming (the gotcha that will waste an afternoon)

`gc` matches `[[patches.agent]]` on the **fully-qualified** instance name:

- city-scoped agent → `mayor`
- rig-scoped agent  → `<rig>/switchyard-ops.brakeman`, **one entry per rig**

A bare leaf name (`brakeman`) or a pack-def name without a rig
(`switchyard-ops.brakeman`)
fails with `agent "…" not found in merged config` and makes **`gc config show`
exit 1 — the whole config is rejected.** There is no def-level fan-out; a
rig-scoped agent needs an entry for every rig that runs it.

Verify a patch actually landed:

```sh
gc config show | grep -A12 'name = "brakeman"'   # shows the resolved idle_timeout / max_active_sessions
```

## Copy-paste starter

Put in `city.toml` under `[patches]`. Repeat both blocks for each rig.

```toml
[[patches.agent]]
  name = "<rig>/<coordinator>"
  min_active_sessions = 1
  max_active_sessions = 1
  idle_timeout = "168h"

[[patches.agent]]
  name = "<rig>/switchyard-ops.brakeman"
  max_active_sessions = 2
```

## Future work

- **Mechanical intake gate for `intake-sweep`.** `switchyard-gt` already resolves
  the token and speaks the `switchyard.work` API, so
  the missing piece is small: a read endpoint + a `switchyard-gt intake --count`
  (or `--json`) subcommand. With it, the sweep skips the nudge for any coordinator
  whose queue is empty — turning a fixed 6×/day drip into "wake only when there is
  real triage." (Spans the switchyard cloud + the `gt` plugin, not these packs.)
- **Re-home the supervision gastown used to provide.** Dropping `witness`/`deacon`
  removed a real cost centre and a real safety net. If stuck beads or expired
  leases start going unnoticed, the cheap answer is an `exec` order that mails on
  breach — a mechanical threshold check, not a new always-on agent. That keeps the
  saving and buys back the watching.
- **Deterministic escalation.** The `oversight-rig` pack (gascity-packs) escalates
  via a condition-triggered order → mechanical rollup script, with no second agent
  re-judging the first. That pattern — not the pack — is worth adopting here.
- **Cut the coordinator first-turn.** A pinned coordinator's fresh wake re-derives
  the whole rig from `gc prime` at max effort — ~12k tokens and several minutes
  observed. Feed it a *smallest-useful context pack* (switchyard's Context-Assembly
  work) and/or drop its effort tier, so a routine triage turn is cheap.
- **Event-driven coordinator wakes.** Coordinators poll on a timer even when their
  project has no new work. A companion SSE → wake bridge (switchyard's town-event
  bridge) would wake a coordinator only when real work arrives — idle rigs cost
  ~nothing instead of a full LLM turn per interval.
- **One dispatch source per rig.** If both the companion (`local_dispatch`) and a
  coordinator triage-and-sling, work is handled twice. Pick one path per rig.
- **Cap the worker pools.** `brakeman` defaults to `max_active_sessions = 4`;
  capping to 2 per rig bounds concurrent build churn — token spend *and* the
  #191 drain-churn blast radius — without starving throughput.
