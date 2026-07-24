# The operating model: a Gas City driven by switchyard

*Design of record for any city consuming these packs. Companion: `LOOP.md`.*

## Design stance

Gas City is a generic agent runtime — sessions, rigs, packs, orders, formulas,
mail, beads. Everything opinionated arrives as a **pack**. The gastown pack is
the "coding platform" plugin; it stays **pinned and unforked**, extended only
through local packs and overlays. That keeps a city upgradeable: `gc` and
gastown evolve upstream, adaptations live in three small layers.

```
┌─ Cloud control plane (not in the city) ─────────────────────────┐
│  switchyard: decide + dispatch (the backlog authority)          │
│  error / demand sensors feed its intake                         │
└──────────────▲───────────────┬──────────────────────────────────┘
     MCP + webhooks            │ webhooks → switchyard intake
┌──────────────┴───────────────▼──────────────────────────────────┐
│ LAYER 3  switchyard-ops (this repo): pool-spawn, loop-health,    │
│          intake-sweep, nightly-retro, stray-reaper, config-drift │
│ LAYER 2  switchyard-mcp overlay (this repo): MCP into every rig  │
│ LAYER 1  gastown pack (pinned sha): per-rig delivery crews +     │
│          city governance (mayor / deacon / boot / dogs)          │
│ LAYER 0  gc core: sessions, rigs, mail, beads, orders, wisps     │
└──────────────────────────────────────────────────────────────────┘
```

**Adapting to another domain** = swap the Layer-1 pack (gastown → a support-desk
pack, a data-pipeline pack…) and point the Layer-2 overlay at that domain's
control plane. Layers 0 and 3 don't change. That is the whole portability
argument for keeping ops logic in packs instead of hand-edited agent homes.

## Roles, not names

This repo names no agent and no rig. It describes positions; a city fills them.

### City-wide governance (one each, from gastown)

| Role | Mode | Job |
|---|---|---|
| **mayor** | always | Cross-rig coordinator; receives every escalation; owns the digest |
| **deacon** | always | Patrol loop: agent health, orphan cleanup, periodic formula dispatch |
| **boot** | always | Watchdog for the watchers — liveness of panes, not of beads |
| **dog** pool | on-demand | Mechanical orders: backups, sweeps, digests |

### Per product rig (the delivery cell)

| Role | Mode | Job |
|---|---|---|
| **coordinator** | pinned, `min=1` | The rig's brain: reconcile with switchyard, triage epics, set priorities, sling beads, answer PRD questions |
| **polecat** ×2–4 | on-demand | Workers: claim bead → worktree → build → MR/PR → hand off |
| **refinery** | on-demand | Merge queue: land approved MRs, keep main green |
| **witness** | always (session recycle) | Progress monitor: stuck beads, orphaned work, lease expiry |

**Scaling rule: coordinators are pinned, workers are elastic.** A rig with no
work costs one idle coordinator; a rig under load fans workers out to its cap. A
suspended rig keeps its config and costs zero.

That fan-out is Layer 3's, not the controller's: gc's `scale_check` cannot be
relied on to spawn, so the `pool-spawn` order reads each rig's claimable demand
itself and starts a worker for it — bounded by the pool's `max_active_sessions`,
so elastic still means capped.

`switchyard-ops` discovers coordinators automatically — anything with
`pool.min >= 1` that is not suspended. There is no roster to maintain.

### The singleton-alias exception

A coordinator whose alias is held by a **manual** session must stay `min=0`.
Pinning it `min=1` does not keep that session alive: the reconciler only counts
sessions it spawned, so `min=1` mints a *second* session that fights the alias.
Declare such agents in `roster.conf`'s `PINNED_EXTRA`; `loop-health` keeps them
alive by waking the alias, and `config-drift` mails the mayor if anything
re-pins them. This cost a real incident to learn; it is encoded here so it costs
nobody else one.

## What deliberately does not exist

- **No "manager of managers"** between the mayor and the coordinators.
  Switchyard **is** the backlog authority; adding a local one forks truth.
- **No always-on workers.** An idle polecat is pure burn; claims are cheap.
- **No agent whose only job is a cron.** That is an **order** on the dog pool.
- **No local backlog that shadows switchyard.** Claim the bead, mint the local
  bead from the claim, let completion flow back.

## Token economy

Idle agents dominate cost, and they are a configuration choice:

- **Pin a cheap model** on the mechanical tier (witness, boot, patrol). `model`
  is a valid key in `agent.toml`. Judgment tiers (mayor, coordinators) can stay
  expensive — there are few of them.
- **`wake_mode = "fresh"`** on patrol agents. `resume` rehydrates the entire
  prior context on every wake; patrol agents re-derive state from beads anyway.
- **Buy savings with lighter cycles, not slower ones.** A patrol agent that
  checks in rarely is a patrol agent that is not patrolling. Cut tool calls per
  turn; keep the cadence.

For the concrete per-agent settings that put these into practice — the witness
Bedrock respawn, deacon/witness `idle_timeout`, worker blast radius, and the
`[[patches.agent]]` fully-qualified-name rule — see
[`TOKEN-HARDENING.md`](TOKEN-HARDENING.md).

## Observability contract

1. `gc status` must answer inside its timeout. A wedged probe is a P0 city bug,
   because every other safeguard reads it. `loop-health` escalating when the
   probe lies is its whole reason to exist.
2. Coordinator liveness should be visible from the control plane, not only from
   inside the city.
3. **Every silent failure becomes mail to the mayor within one order cycle.**
   This is the governing invariant of Layer 3. A check that can fail quietly is
   not a check.

## Operational gotchas (learned the hard way)

- `gc rig add` / `gc rig resume` **rewrite `city.toml` and drop comments.**
  After any gc command that rewrites config, re-verify `[[patches.agent]]`.
- **`gc bd mol wisp <missing-formula>` prints an error and exits 0.** A formula
  that fails to pour looks exactly like a formula with nothing to do. Check
  `gc bd formula list` before believing an idle agent is idle.
- **`gc import install` does not materialize formulas** — the supervisor
  reconcile does, a tick later. Don't diagnose from an immediate re-check.
- **Packs live in a content-addressed cache** whose directory name hashes the
  pack URL and version. Never hardcode that path into an `agent.toml`; it
  changes on every re-pin.
- **Never track `.gc/`, `.beads/`, worktrees, or `.env`.** Use a whitelist
  `.gitignore`. A blacklist leaks the first artifact nobody thought of.
