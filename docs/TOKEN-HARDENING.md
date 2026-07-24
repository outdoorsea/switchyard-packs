# Token hardening: don't pay to idle

*Operating guidance for any city consuming these packs. Companion: `OPERATING-MODEL.md`.*

## The one thing to understand

Every gastown crew agent runs `wake_mode = "fresh"`. **Each time a session is
(re)spawned, its entire system prompt + template fragments are re-billed as
input tokens.** A witness prompt is ~13 KB; a mayor ~10 KB. So the dominant cost
of a *quiet* city is not the work it does — it is how often pinned agents wake or
respawn to discover there is nothing to do.

Optimize **wake/respawn frequency first.** Everything below is a corollary.

Complementary lever, in [`OPERATING-MODEL.md`](OPERATING-MODEL.md#token-economy):
pin a cheaper `model` on the mechanical tier (witness, boot, patrol). That cuts
the *price* of each wake; this doc cuts the *count*. Do both.

## The levers, ranked

### 1. `witness.max_session_age` — a Bedrock workaround you probably don't need
The gastown `witness` (rig-scoped, always-on) sets `max_session_age = "5h"`,
which force-tears-down and respawns the session every ~5 h **regardless of
activity** — reloading its ~13 KB prompt each time, per rig, forever. That knob
exists to preempt Claude-Code-on-**Bedrock**'s ~8 h STS/SSO credential-cache
wedge. **If your `[providers.claude] base` is `builtin:claude` (not Bedrock),
this respawn treadmill buys you nothing.** Relax it hard:

```toml
[[patches.agent]]
  name = "<rig>/gastown.witness"   # one entry PER RIG — see "Patch naming" below
  idle_timeout    = "3h"           # was 1h
  max_session_age = "24h"          # was 5h; drop the Bedrock-only forced respawn
```

On Bedrock, keep `max_session_age` under the ~8 h ceiling (e.g. `7h30m`) rather
than removing it.

### 2. Coordinator idle heartbeats
`gastown.deacon` (and `mayor`, `witness`) default to `idle_timeout = "1h"`, so an
idle town pays a fresh LLM turn per coordinator every hour — the deacon patrol
even preaches "back off when idle," but the 1 h floor caps the backoff. Raise the
non-interactive ones:

```toml
[[patches.agent]]
  name = "gastown.deacon"
  idle_timeout = "4h"        # ~24 idle wakes/day -> ~6
```

Leave `mayor` hot if a human talks to it; leave `boot` alone (it is the
freeze-detector).

### 3. Worker pool blast radius
`polecat`/`brakeman` pools default to `max_active_sessions = 5`. Under a
drain-churn storm (controller drains a mid-build worker that emitted no output
for a few minutes → reconciler respawns it → repeat), that is up to 5 parallel
full-prompt reloads doing zero merges. Cap the blast radius per rig:

```toml
[[patches.agent]]
  name = "<rig>/gastown.polecat"
  max_active_sessions = 2
```

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
- `merge-gate` (5 min) — stamps `merge_strategy`, mails the mayor. 288 runs/day,
  zero LLM; the tight cadence is a deliberate race-win against the refinery.
- `config-drift`, `stray-reaper` (6 h) — diff/detect + mail only.
- `loop-health` (30 min) — process/probe checks; only nudges sessions that are
  *missing* (normally none), so normally zero LLM.

Pinned coordinators at `idle_timeout = "168h"` are also already efficient — they
wake ~weekly, not hourly. Don't "fix" them down.

## Patch naming (the gotcha that will waste an afternoon)

`gc` matches `[[patches.agent]]` on the **fully-qualified** instance name:

- city-scoped agent → `gastown.deacon`
- rig-scoped agent  → `<rig>/gastown.witness`, **one entry per rig**

A bare leaf name (`witness`) or a pack-def name without a rig (`gastown.witness`)
fails with `agent "…" not found in merged config` and makes **`gc config show`
exit 1 — the whole config is rejected.** There is no def-level fan-out; a
rig-scoped agent needs an entry for every rig that runs it.

Verify a patch actually landed:

```sh
gc config show | grep -A12 'name = "witness"'   # shows the resolved idle_timeout / max_session_age
```

## Copy-paste starter (non-Bedrock city)

Put in `city.toml` under `[patches]`. Repeat the witness block for each rig.

```toml
[[patches.agent]]
  name = "gastown.deacon"
  idle_timeout = "4h"

[[patches.agent]]
  name = "<rig>/gastown.witness"
  idle_timeout    = "3h"
  max_session_age = "24h"
```

## Future work

- **Mechanical intake gate for `intake-sweep`.** `switchyard-gt` already resolves
  the token and speaks the `switchyard.work` API (it POSTs `/gastown/patrol`), so
  the missing piece is small: a read endpoint + a `switchyard-gt intake --count`
  (or `--json`) subcommand. With it, the sweep skips the nudge for any coordinator
  whose queue is empty — turning a fixed 6×/day drip into "wake only when there is
  real triage." (Spans the switchyard cloud + the `gt` plugin, not these packs.)
- **Deacon threshold-checks → exec orders.** Several `mol-deacon-patrol` steps
  (`dolt-health`, `queue-starvation-check`) are fixed-threshold comparisons the
  formula itself says should be mechanical, yet they run inside the paid deacon
  turn. Moving them to `exec` orders that mail on breach would let the deacon's
  `idle_timeout` go even higher.
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
- **Cap the worker pools.** `polecat` and `brakeman` default to `max_active_sessions
  = 5`; capping to 2 per rig bounds concurrent build churn — token spend *and* the
  #191 drain-churn blast radius — without starving throughput.
