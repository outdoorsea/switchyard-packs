# The 24-hour loop

*How a switchyard-driven city runs a day. Companion: `OPERATING-MODEL.md`.*

## Mission

Run an AI-first product organization where a small human team and a fleet of
agents continuously triage ideas and issues, move them through
pitch → PRD → build → review → deploy, and improve the system itself on a
24-hour cycle.

**Humans make exactly two kinds of decisions:** *what to build* (triage routing
and PRD approval) and *what to trust* (review gates, knowledge approval).
Everything else is agent work.

## Positions

| Component | Loop role |
|---|---|
| **Demand sensors** (product feedback, votes) | Sense: human demand → switchyard intake |
| **Error sensors** (Sentry-compatible ingest) | Sense: production pain → threshold → bead → fix → auto-resolve |
| **switchyard** | Decide + dispatch: intake → triage → pitch → PRD → human approval → epics/beads → claim pool → validation → reports |
| **Gas City** | Act: coordinators route, brakemen build in worktrees and open PRs |
| **Review gate** | Deterministic scanners + LLM triage as an MR gate |
| **Knowledge store** | Learn: decisions, incidents, lessons; linked to PRDs |

## Cadence

The loop is event-driven where possible; the clock entries are the
**guarantees**, not the only activity.

| When | What | Who | Gate |
|---|---|---|---|
| Continuous | Ideas and errors land in intake via webhooks; PR/MR state mirrors in | machines | — |
| Continuous | Threshold-crossing errors auto-file beads; workers fix; sensors auto-resolve on merge | sensors + rig crews | auto (regression re-opens) |
| Every wake cycle | Coordinator: check mail, reconcile with switchyard, triage epics, set priorities, sling work | coordinator (per rig) | — |
| Morning (~30 min) | Triage queue: route ideas to pitches, categorize issues, answer PRD questions, approve/park PRDs | **human** | **the** decision gate |
| All day | Claim pool drains: workers claim beads, heartbeat, complete; a *different* agent validates criteria | workers | separation of duties |
| On PR | Review gate: CI + review on the worker's pull request; a human merges; PR attaches to the PRD | **human** | the merge gate is a person |
| Nightly | Retro: aggregate completions, validations, intake, error spikes → daily report + improvement candidates back into intake | retro agent | candidates human-triaged |
| Nightly | Maintenance orders: backup, compact, stale-db sweep, branch prune, digest | dog pool | escalate to mayor on anomaly |
| Weekly | Human retro on the retros: adjust priorities, approve knowledge promotions, tune thresholds | **human** | — |

**The improvement flywheel:** every cycle the system (a) ships work, (b) records
what happened, and (c) proposes what to fix *about itself*. Humans steer by
triage, not by task assignment.

## The heartbeat (orders, not agents)

Layer 3 encodes the loop as timed orders — cooldown trigger → wisp → dog
executes → escalate to mayor on anomaly. No agent exists merely to run a clock.

| Order | Trigger | What runs |
|---|---|---|
| `pool-spawn` | 1m | Spawn a brakeman for each rig with claimable pool demand and a free WIP slot, and direct-assign it the demand bead |
| `answer-sweep` | 20m | Reap finished answerers, then keep one alive per rig whose open-question queue is non-empty |
| `judge-sweep` | 30m | Reap finished judging-validators, then keep one alive per rig whose judgment queue is non-empty |
| `loop-health` | 30m | Verify every pinned session has a live process **and** the status probe answers; wake what's down; escalate if the probe itself lies |
| `intake-sweep` | 4h | Nudge each coordinator to triage its project's intake and dispatched epics |
| `nightly-retro` | 24h | Nudge the retro agent to draft daily reports and propose improvements |
| `stray-reaper` | 6h | Flag sessions whose `GC_CITY` is not this city (relocated-root leftovers writing to the wrong store) |
| `config-drift` | 6h | Config-as-code guard: uncommitted tracked config, stray dupes, singleton-alias re-pins |

Governing invariant: **every silent failure becomes mail to the mayor within one
order cycle.**

Those are the orders that carry the loop itself; the pack ships several more
housekeeping sweeps. [`../README.md`](../README.md#what-switchyard-ops-gives-you)
has the full manifest.

## Why `pool-spawn` exists

Observed failure: dispatch died for days. Beads were slung and correctly routed
to a rig's worker pool, and no worker ever started — gc's controller owns the
spawn-and-claim half, and three defects there (a self-blocking molecule root, a
`scale_check` that will not spawn, config-routed beads nothing can claim) each
fail *silently*. A full queue beside an empty pool looks exactly like an idle
city.

So `pool-spawn` stops waiting on the controller and does that job in the pack: it
reads each rig's genuinely claimable demand, spawns one brakeman, and hands the
bead to it directly. Its cadence is 1m rather than a sweep interval because
dispatch is a **race** — the point is that a worker starts within an order cycle —
which puts it beside `publish-gate`'s 5m rather than the 6h reapers.

## Why `loop-health` exists

Observed failure: every pinned agent had a live process while `gc status`'s
runtime probe timed out and reported the whole city stopped. Nothing woke
anything, and orders went stale — because every safeguard reads the probe.

So `loop-health` checks liveness **against tmux**, not against the probe, and
treats a lying probe as an escalation in its own right. It checks panes rather
than `ps` argv, because resumed sessions restart with only `--session-id`: an
argv grep marks every once-woken coordinator dead forever.

## Why the sweep lanes reap before they spawn

Observed failure: `judge-sweep` and `answer-sweep` spawned one adhoc session per
rig per cycle and removed none, so the population grew until the host saturated —
14 concurrent adhoc sessions across two rigs, load excursion to 311 on a 16-core
box.

The retention was never a cadence problem, which is why widening the intervals in
`city.toml` did not stop it. It is a **state** problem: a finished adhoc session
leaves the live-state set — it settles as `asleep` — so the "one already running?"
guard correctly reported none live and correctly spawned a replacement, while the
finished session stayed registered forever. The guard was not the leak; the
missing half of the lifecycle was. Widening the interval only slows the accrual,
it never bounds it.

So a cycle is now **reap-then-spawn**. Reaping decides on tmux pane state and
never age — for the same reason `loop-health` reads panes, and because an
age-based guard misclassified 4 of 12 sessions and killed one holding an unread
mayor escalation. A sweep reaps only what it spawned, and every uncertain read
leaves the session running. Full rules, and the four gates that stand between a
cycle and a spawn, are in
[`../README.md`](../README.md#the-sweep-lanes-reap-what-they-spawn).

## Escalation discipline

Two tiers, deliberately:

- **Live regressions mail every cycle.** A singleton alias being reconciler-
  pinned means a twin session is being spawned *right now*.
- **Hygiene mails at most once per 24h.** Uncommitted config and stray files are
  real but not urgent. A 30-minute nag trains everyone to ignore mayor mail,
  and then the escalation channel is worth nothing when it matters.
