# The operating model: a Gas City driven by switchyard

*Design of record for any city consuming these packs. Companion: `LOOP.md`.*

## Design stance

Gas City is a generic agent runtime — sessions, rigs, packs, orders, formulas,
mail, beads. Everything opinionated arrives as a **pack**. The gascity pack is
the build-methodology plugin; it stays **pinned and unforked**, extended only
through local packs and overlays. That keeps a city upgradeable: `gc` and
gascity evolve upstream, adaptations live in three small layers.

```
┌─ Cloud control plane (not in the city) ─────────────────────────┐
│  switchyard: decide + dispatch (the backlog authority)          │
│  error / demand sensors feed its intake                         │
└──────────────▲───────────────┬──────────────────────────────────┘
     MCP + webhooks            │ webhooks → switchyard intake
┌──────────────┴───────────────▼──────────────────────────────────┐
│ LAYER 3  switchyard-ops (this repo): pool-spawn, loop-health,    │
│          intake-sweep, nightly-retro, stray-reaper, config-drift │
│          + brakeman / answerer / judge, and sy-item-work         │
│ LAYER 2  switchyard-mcp overlay (this repo): MCP into every rig  │
│ LAYER 1  gascity pack (pinned sha): the build workflow graph —   │
│          formulas, role targets, artifact schemas                │
│ LAYER 0  gc core: sessions, rigs, mail, beads, orders, wisps     │
└──────────────────────────────────────────────────────────────────┘
```

**Adapting to another domain** = swap the Layer-1 pack (gascity → a support-desk
pack, a data-pipeline pack…) and point the Layer-2 overlay at that domain's
control plane. Layers 0 and 3 mostly don't change. That is the portability
argument for keeping ops logic in packs instead of hand-edited agent homes.

"Mostly" is doing real work in that sentence, and the gastown → gascity swap is
what proved it. Layer 3 *did* change, in one place: the worker lane. A Layer-1
pack owns how work gets from a bead to a reviewable branch, and that contract
differs enough between packs that Layer 3 cannot be blind to it — see
**The worker lane** below. Budget for that when swapping Layer 1; everything
else here really is portable.

### gascity and gastown are not versions of each other

They occupy the same slot but solve different halves, and both ship actively.
gastown is an **orchestration** pack: always-on crew (mayor, deacon, boot),
per-rig delivery cells (polecat, refinery, witness), patrol formulas, a dog
pool. gascity is a **methodology** pack: a graph of build formulas, stateless
role targets they dispatch to, artifact schemas — and no session topology at
all.

So this is not an upgrade path, and moving between them is not a rename. Read
**What you give up** before treating it as one.

## Roles, not names

This repo names no agent and no rig. It describes positions; a city fills them.

### City-wide governance

| Role | From | Mode | Job |
|---|---|---|---|
| **mayor** | city-local (`gc init`) | always | Cross-rig coordinator; receives every escalation; owns the digest |
| **dog** pool | the `bd` pack | on-demand | Mechanical formula orders: backups, Dolt sweeps, digests |

The mayor is **not** from a pack here. gascity ships no always-on crew, so
`gc init` writes an `agents/mayor/` into the city and you declare its
`[[named_session]]` yourself. This is load-bearing: every escalation in this
pack is `gc mail send mayor`, and all 14 call sites redirect to `/dev/null`, so
a city with no resident mayor loses its entire escalation path **silently**.

Note the dog pool comes from `bd` (the Dolt beads provider), not from the
methodology pack — so it survives a Layer-1 swap. It is only needed for
*formula* orders; all ten of this pack's own orders are `exec` scripts the
controller runs directly.

### Per product rig (the delivery cell)

| Role | From | Mode | Job |
|---|---|---|---|
| **coordinator** | city-local | pinned, `min=1` | The rig's brain: reconcile with switchyard, triage epics, set priorities, sling beads |
| **brakeman** ×2–4 | switchyard-ops | on-demand | Workers: claim bead → worktree → build → push → open PR |
| **answerer** | switchyard-ops | on-demand | Drains open PRD questions |
| **judge** | switchyard-ops | on-demand | Drains the awaiting-validation backlog |
| gascity **role targets** | gascity `roles` | stateless | `gc.implementation-worker`, `gc.publisher`, `gc.run-operator` — what the formula's steps dispatch *to* |

gascity's roles are not sessions you scale; they are targets a formula step
names. The pool you size is `brakeman`.

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

## The worker lane

This is the one place Layer 3 knows something about Layer 1, so it is worth
stating plainly rather than leaving in a formula comment.

A brakeman runs **`sy-item-work`** (this pack's formula), which extends
gascity's `implementation-base` and adds a publish step:

```
prepare-worktree → implement → publish → close-source-anchor
```

Two things about that order are deliberate.

**The worker closes its own bead.** Under gastown it was forbidden to — the
refinery closed it after verifying the merge. There is no refinery here, so
"never close your own bead" would deadlock every item. If you are porting an
agent prompt across, this is the rule that inverts.

**`close-source-anchor` depends on `publish`, and that is not stylistic.**
gascity's own `do-work` is `prepare-worktree → implement → close-source-anchor`:
it never pushes. Push and PR-opening live in gascity's separate `publish`
formula, whose `push` and `open_pr` vars **both default to `"false"`**. A worker
on bare `do-work` therefore builds the change, closes its bead, and leaves the
branch on local disk — and every switchyard surface reads that bead as
delivered. Sequencing the close behind the publish is what makes "closed" imply
"a human can see it".

`sy-item-work` does *not* `expand` gascity's `publish` formula, because it
cannot: that formula declares `[[steps]]` rather than a `[template]`, so it is a
workflow rather than an expansion, and it requires a `final_report` this
per-item lane never produces. It publishes the way gascity's own `build-basic`
does — an inline step targeted at `gc.publisher`.

The mechanical backstop for all of this is the `publish-gate` order, which
reports any closed worker bead carrying no `pr_url`. It replaced `merge-gate`,
whose job (stop work reaching "done" unreviewed) was the same; only the way work
can go missing moved.

## What you give up

Moving from gastown to gascity is a real trade, not a cleanup. gascity ships no
session topology, so these go away and **nothing in this pack replaces them**:

| Gone | What it did | Consequence |
|---|---|---|
| **witness** (per rig, always-on) | Watched for stuck beads, orphaned work, lease expiry | Nothing notices a bead that stalls mid-build |
| **deacon** (city, always-on) | Patrol loop: agent health, orphan cleanup | No periodic health sweep beyond `loop-health`'s coordinator check |
| **boot** (city, watchdog) | Liveness of panes — the watcher of watchers | A frozen controller is noticed later |
| **refinery** (per rig) | Merge queue; kept `main` green | Nothing merges automatically; every PR waits on a human |

The last row is mostly a feature — this pack always wanted review before merge,
and `merge-gate` existed to force it. The first three are a genuine loss of
supervision, and the honest summary is that a gascity city is cheaper to idle
and less self-healing.

Decide deliberately whether you accept that. `loop-health` still verifies pinned
coordinators are alive and that the status probe is not lying, so the city
notices *dead* agents; it does not notice *stuck work*.

## What deliberately does not exist

- **No "manager of managers"** between the mayor and the coordinators.
  Switchyard **is** the backlog authority; adding a local one forks truth.
- **No always-on workers.** An idle worker is pure burn; claims are cheap.
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
