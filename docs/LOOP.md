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
| **Gas City** | Act: coordinators route, polecats build in worktrees, refinery merges, witness monitors |
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
| On merge | Review gate: CI + advisory review; refinery merges; PR attaches to the PRD | refinery | advisory → hard gate later |
| Nightly | Retro: aggregate completions, validations, intake, error spikes → daily report + improvement candidates back into intake | retro agent | candidates human-triaged |
| Nightly | Maintenance orders: backup, compact, stale-db sweep, branch prune, digest | dog pool | escalate to mayor on anomaly |
| Weekly | Human retro on the retros: adjust priorities, approve knowledge promotions, tune thresholds | **human** | — |

**The improvement flywheel:** every cycle the system (a) ships work, (b) records
what happened, and (c) proposes what to fix *about itself*. Humans steer by
triage, not by task assignment.

## The heartbeat (orders, not agents)

Layer 3 encodes the loop as timed orders — cooldown trigger → wisp → dog
executes → escalate to mayor on anomaly. No agent exists merely to run a clock.

| Order | Trigger | What the dog does |
|---|---|---|
| `loop-health` | 30m | Verify every pinned session has a live process **and** the status probe answers; wake what's down; escalate if the probe itself lies |
| `intake-sweep` | 4h | Nudge each coordinator to triage its project's intake and dispatched epics |
| `nightly-retro` | 24h | Nudge the retro agent to draft daily reports and propose improvements |
| `stray-reaper` | 6h | Flag sessions whose `GC_CITY` is not this city (relocated-root leftovers writing to the wrong store) |
| `config-drift` | 6h | Config-as-code guard: uncommitted tracked config, stray dupes, singleton-alias re-pins |

Governing invariant: **every silent failure becomes mail to the mayor within one
order cycle.**

## Why `loop-health` exists

Observed failure: every pinned agent had a live process while `gc status`'s
runtime probe timed out and reported the whole city stopped. Nothing woke
anything, and orders went stale — because every safeguard reads the probe.

So `loop-health` checks liveness **against tmux**, not against the probe, and
treats a lying probe as an escalation in its own right. It checks panes rather
than `ps` argv, because resumed sessions restart with only `--session-id`: an
argv grep marks every once-woken coordinator dead forever.

## Escalation discipline

Two tiers, deliberately:

- **Live regressions mail every cycle.** A singleton alias being reconciler-
  pinned means a twin session is being spawned *right now*.
- **Hygiene mails at most once per 24h.** Uncommitted config and stray files are
  real but not urgent. A 30-minute nag trains everyone to ignore mayor mail,
  and then the escalation channel is worth nothing when it matters.
