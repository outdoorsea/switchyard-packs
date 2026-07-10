# Gas City packs

Packs for running a Gas City whose backlog authority is **switchyard**. Nothing
here names a rig, an agent, or a machine — any Gas City can import these.

They live in this repo, next to the server they drive, so a pack can never skew
from the API it calls. Pin a switchyard commit and you have pinned the server,
the MCP tool surface, and the orders that use them, together.

```
packs/switchyard-ops/     Layer 3 — the city's 24-hour heartbeat (timed orders)
                                  + brakeman, the worker pool you sling to
packs/switchyard-mcp/     Layer 2 — overlay: switchyard MCP into a rig's crew
packs/examples/city/      a reference pack.toml + city.toml to copy
packs/docs/OPERATING-MODEL.md   roles, layering, token economy, gotchas
packs/docs/LOOP.md              the 24-hour cadence and escalation discipline
```

**Setting up for the first time — any surface (single terminal, Claude Code,
OpenAI desktop, Gas City)?** Start at [`onboarding/`](onboarding/README.md): one
shared operating manual ([`AGENTS.md`](onboarding/AGENTS.md)) plus a per-client
"register the MCP server" page.

For the Gas City design of record, read
[`docs/OPERATING-MODEL.md`](docs/OPERATING-MODEL.md), then copy
[`examples/city/`](examples/city/README.md).

## Packs vs. the Claude Code plugin

[`plugins/switchyard/`](../plugins/switchyard) and these packs solve different
problems, and you may want both:

|  | `plugins/switchyard` | `packs/` |
|---|---|---|
| Consumer | any Claude Code session | agent sessions under `gc` |
| Gives you | `/switchyard:*` slash commands | MCP overlay + timed orders |
| Needs | Claude Code | a Gas City |

A human driving switchyard by hand wants the plugin. A city that runs
coordinators on a heartbeat wants the packs.

## Install

Packs are **authored here** and **consumed from the public mirror**,
[`outdoorsea/switchyard-packs`](https://github.com/outdoorsea/switchyard-packs) —
this repo is private, and `gc import` needs a git source it can clone
anonymously to resolve and lock a pin. `.github/workflows/mirror-packs.yml`
republishes `packs/` there on every push to `main`, byte-for-byte, so the
mirror's root is this directory's root and each pack is a top-level subpath.

The mirror is a projection, never a source. Send changes here.

```sh
# city-wide, ONCE: the heartbeat orders AND a brakeman pool in every rig
gc import add https://github.com/outdoorsea/switchyard-packs/tree/main/switchyard-ops

# per rig: the MCP overlay, for each rig whose crew drives switchyard
gc import add https://github.com/outdoorsea/switchyard-packs/tree/main/switchyard-mcp --rig YOUR_RIG

gc import install
gc import check
```

**Import `switchyard-ops` at city scope only.** One city import yields both the
orders *and* a `brakeman` pool in every rig — `gc` expands a pack's rig-scoped
agents into each rig from the city import. Adding `--rig` on top registers every
order a second time under that rig, so `loop-health` and `intake-sweep` nudge
twice per cycle and mail the mayor twice per escalation.

Measured on a 14-rig city:

| Import scope | `brakeman` agents | order registrations |
|---|---|---|
| city only | 14 | 1 |
| rig only | 1 | 1 (that rig) |
| both | 14 | **2** |

To keep workers out of a rig, suspend the agent there rather than withholding
the import:

```toml
[[patches.agent]]
  dir = "<rig>"
  name = "brakeman"
  suspended = true
```

`gc import add` writes the `[imports.*]` entry and locks the resolved commit
into `packs.lock`; see [`examples/city/`](examples/city/README.md) for the TOML
it produces.

Working on the packs themselves? Import your checkout directly. `gc` promotes a
path inside a git worktree to a `file://` source and locks it to the
checked-out commit, so a local import still pins:

```toml
source = "/path/to/switchyard/packs/switchyard-ops"
```

## What `switchyard-ops` gives you

Five mechanical orders, run by the dog pool, under one invariant: **every silent
failure becomes mail to the mayor within one order cycle.**

| Order | Every | Purpose |
|---|---|---|
| `merge-gate` | 5m | Worker beads carry a `merge_strategy` before the refinery sees them |
| `loop-health` | 30m | Pinned coordinators alive; escalate when the status probe lies |
| `intake-sweep` | 4h | Nudge coordinators to triage their switchyard project |
| `nightly-retro` | 24h | Daily reports + improvement candidates |
| `stray-reaper` | 6h | Sessions rooted at a stale city path |
| `config-drift` | 6h | Config-as-code guard (no-ops if the city isn't a git repo) |

### Review before merge

gastown's refinery reads `metadata.merge_strategy` off the **work bead** and
defaults to **`direct`** — it lands the agent's commit on your default branch,
unreviewed. `gc sling --merge` does *not* set that: it is a `gc convoy create`
flag and a silent no-op on a bead route.

So `merge-gate` stamps every open bead routed to a `*.brakeman` pool with
`merge_strategy=mr` (override via `MERGE_STRATEGY` in `roster.conf`). gastown
decides *how* work merges; this pack decides *that it must be reviewed*.

It is a backstop, not a guarantee — stamp the bead where it is minted if you
can, and **protect your default branch** so an un-stamped bead fails loudly
instead of landing.

> **GitLab rigs:** gastown's `mr` mode shells out to `gh pr create` / `gh pr
> view` and has no `glab` support, so on a GitLab remote the refinery cannot
> open the MR. Per its own contract it records a blocked reason and escalates to
> the mayor rather than merging. Fixing this belongs upstream in gastown.

## Workers: the brakeman pool

`switchyard-ops` ships one agent, `brakeman` — an elastic pool that claims a
routed bead, builds it in a bead-scoped worktree, and hands the branch to
gastown's refinery. It is the thing you sling work to:

```sh
gc sling YOUR_RIG/switchyard-ops.brakeman ex-1234
```

Set `default_sling_targets` on the rig and a bare `gc sling ex-1234` lands in the
pool, so dispatch never has to name an agent.

### One required rig setting

```toml
[[rigs]]
  formula_vars = { binding_prefix = "gastown." }
```

Without it the handoff **strands your bead, silently**. `{{binding_prefix}}` in
gastown's `mol-polecat-work` resolves to the import binding of the pack that
*cooked* the formula — `switchyard-ops` — so the submit step hands off to
`YOUR_RIG/switchyard-ops.refinery`, which nobody ships. The worker pushes its
branch, assigns to nobody, and the bead sits open with no reviewer. Pinning the
var renders `gastown.refinery`. gastown's own polecat already resolves to that
value, so the override changes nothing for it.

Verified the hard way: a shadow run got as far as a pushed `polecat/<bead>`
branch before the handoff evaporated.

Concurrent sessions draw names from
[`agents/brakeman/namepool.txt`](switchyard-ops/agents/brakeman/namepool.txt) —
railway occupations: `fireman`, `switchman`, `shunter`, `hostler`, `carman`, …
The name identifies a *session*, not a specialty. Every brakeman claims from the
same queue. Keep at least `max_active_sessions` names in the pool.

The pool sits at `min_active_sessions = 0`: an idle worker is pure token burn,
and claims are cheap. It scales up on demand and drains back to nothing.

**A brakeman runs gastown's `mol-polecat-work`, unchanged.** That formula is
agent-agnostic — it claims via `gc hook --claim`, scopes its worktree to the
bead rather than the agent, and hands off to the refinery. Nothing in it
requires the claimant to be called `polecat`. The one place the old name
survives is the feature branch it cuts, `polecat/<bead-id>`, and that string is
a wire contract the refinery validates on handoff. Renaming it would mean owning
the handoff step forever. The agent is ours; the method stays gastown's.

## No roster to maintain

The pack names no agent. `loop-health` and `intake-sweep` derive the coordinator
set from `gc agent list --json` — every agent with `pool.min >= 1` that is not
suspended. That is the reconciler's own intent, so the roster cannot drift from
config.

Only what `gc` cannot express goes in a **city-local, un-versioned**
`$GC_PACK_STATE_DIR/roster.conf` (see
[`roster.conf.example`](switchyard-ops/assets/roster.conf.example)):

- `PINNED_EXTRA` — singleton-alias agents that must stay `min=0` (pinning them
  spawns a twin that fights the alias) but still need liveness checks.
- `RETRO_AGENT` — who drafts the nightly report.
- `COORDINATORS` — override the sweep set.

With no `roster.conf` at all, everything still works.

## LLM instructions are assets, not strings

What a coordinator actually *does* during a sweep lives in
[`assets/prompts/`](switchyard-ops/assets/prompts), versioned and reviewable —
not buried in a shell heredoc. The scripts decide *who* to nudge; the prompts
decide *what* they do.

## Requirements

- `gc` (Gas City), `jq`, `tmux`
- `switchyard-mcp` on `PATH`, authenticated via `switchyard-mcp login`

The overlay ships **no token**. The MCP server resolves it from
`$SWITCHYARD_API_TOKEN` or a `chmod 600` machine-local token file. Never put a
token in `overlay/.claude/settings.json`.
