# factory-run: the P0 toy `build-basic` run

> **STATUS: COMPLETE.** Workflow `sbox-e6k` ran to a terminal state and closed
> with `gc.build.final_outcome=approved`; 48 of its 50 beads are closed and none
> is in progress. The run's own final report — the `factory-run.md` the
> criterion names — is committed verbatim alongside its whole artifact chain at
> [`docs/evidence/prd-269-p0-build-basic/`](../../docs/evidence/prd-269-p0-build-basic/).
> See [Run outcome](#run-outcome) below.

Evidence for switchyard PRD 269 P0 ("Coexistence proven"), acceptance
criterion `crit:5d2c69f83803`:

> A toy build-basic run completes end-to-end in the sandbox rig with its
> factory-run.md committed as evidence.

This file is the **operator's** record of that run: the city it ran in, the pack
pins it ran against, the rig it ran in, every step the workflow took, and the
five findings the attempt surfaced. The run's own final report — the
`factory-run.md` the criterion names, written by the factory rather than by a
person — is committed verbatim beside its whole artifact chain under
[`docs/evidence/prd-269-p0-build-basic/`](../../docs/evidence/prd-269-p0-build-basic/).
Together they are this criterion's evidence.

It is a run log, not a design document: if you are looking for what the factory
*is*, read [REQUIREMENTS.md](REQUIREMENTS.md) and the `sy-build-from-prd`
formula instead.

## Why a run, and not more code

The criterion asks for **execution evidence**, and seven prior validator
verdicts on this criterion rejected code-only deliveries for exactly that
reason — the formula and overrides have been on `main` since PR #1247, but no
run of them had ever been recorded. P0 exists to de-risk the adoption *before*
P1 depends on it, so what had to be proven here is that gascity's stock
`build-basic` actually executes in this city, alongside the pinned gastown
pack, without forking either.

## The city and its pins

The run happened in the live `gc-factory` city, which is the point: P0 is a
coexistence proof, and a run in some other city would prove nothing about this
one. Pins at run time (`packs.lock`):

| Pack | Source | Pin |
|------|--------|-----|
| `gc` (gascity base) | `gastownhall/gascity-packs` → `gascity` | `3b3b89f2011e06d84459aa7bea1552382f13930a` |
| `gc` roles | `gastownhall/gascity-packs` → `gascity/roles` | `3b3b89f2011e06d84459aa7bea1552382f13930a` |
| gastown core | `gastownhall/gascity` → `internal/bootstrap/packs/core` | `f895c0ff47d6ee9334ed282a416387eb5b084d24` |
| bd | `gastownhall/gascity` → `examples/bd` | `f895c0ff47d6ee9334ed282a416387eb5b084d24` |
| `switchyard-ops` | `outdoorsea/switchyard-packs` → `switchyard-ops` | `f4471fb971e1554024c1dd3d71a12e8d47007b1a` |
| `switchyard-mcp` | `outdoorsea/switchyard-packs` → `switchyard-mcp` | `c101d5719ade3a0a4bba55b99e4f366f760b63ab` |

Coexistence gate, run before and after the sandbox rig was added:

```console
$ gc import check
Import state OK: 6 remote import(s) checked
```

Both families resolve from one search path with no fork: `mol-*` formulas come
from the gastown core pack, `build-*` from the gascity pack. `gc formula list`
returns 43 formulas across both.

## The sandbox rig

Registered specifically for this proof, so nothing in a real project could be
touched by a toy run:

- **path** `/Users/jeremy/gc-factory-sandbox`
- **name** `sandbox`, **prefix** `sbox`, **default branch** `main`
- **payload** one trivial Go module (`package sandbox`), so the run has real
  code to plan, implement, test and review against — and nothing any other
  project depends on
- **no git remote**, deliberately: the run cannot push anywhere, and a
  switchyard MCP session started in it resolves no project scope (PRD #334),
  so no lane can mistake it for a real rig

It inherited the whole `gc.*` role family automatically from
`[defaults.rig.imports.gc]` in `city.toml` — twelve roles, all `min=0`, which
is the "no idle-cost regression" half of the P0 contract:

```
sandbox/gc.design-author                    sandbox/gc.publisher
sandbox/gc.design-implementation-reviewer   sandbox/gc.requirements-planner
sandbox/gc.design-test-risk-reviewer        sandbox/gc.review-synthesizer
sandbox/gc.gap-analyst                      sandbox/gc.run-operator
sandbox/gc.implementation-reviewer          sandbox/gc.task-decomposer
sandbox/gc.implementation-worker            sandbox/gc.issue-triager
```

## What this run surfaced

All of these are recorded because a coexistence proof that hides what it
tripped over is worth less than one that names it. None is a switchyard bug.

### 1. `gc rig add` cannot create a rig — gastownhall/beads#4566

Registering **any** new rig in this city fails while initializing the rig's
beads database:

```
Error: failed to open Dolt store: failed to initialize schema: schema
migration: pending schema migrations alter pre-existing dirty tables:
comments, compaction_snapshots, dependencies, events, issue_snapshots,
labels; run 'bd dolt commit' to commit the working set at the current
schema, then re-run the migration (gastownhall/beads#4566)
```

A freshly created Dolt database is left with an **uncommitted working set**
(10 modified tables), and the schema migration refuses to run over it. The
error names its own remedy, but that remedy is a **catch-22**: `bd dolt commit`
must open the database to commit it, and opening runs the migration that
refuses. Running it returns the identical error.

The unblock is to commit the working set *underneath* beads, against the
running Dolt server, scoped to the sandbox database alone:

```sh
dolt --host 127.0.0.1 --port 27825 --user root --password "" --no-tls \
     --use-db sbox sql -q "CALL DOLT_COMMIT('-Am', 'commit working set');"
```

`dolt_status` then reports zero dirty tables and `gc rig add --adopt`
succeeds. **This is an upstream beads defect, not a pack or city
misconfiguration**, and it blocks new-rig creation for anyone on this build.

### 2. `bd` is scoped by environment, not by working directory

Inside a gc worker session, `BEADS_DIR` and `GC_BEADS_SCOPE_ROOT` are exported
and pin every `bd` invocation to *that worker's* rig. Beads resolves config
with environment variables at priority 1, **above** the repository's own
`.beads/metadata.json`, so `cd`-ing into another rig does not re-scope `bd`:

```console
$ cd /Users/jeremy/gc-factory-sandbox && bd dolt show
  Database: sw          # the switchyard rig's database, not sbox
```

Every `bd`/`gc` call meant for another rig must therefore clear them
(`env -u BEADS_DIR -u GC_BEADS_SCOPE_ROOT ...`) or the call silently operates
on the wrong database. During this attempt two `bd dolt commit` calls landed on
the live `sw` database before the cause was found. `dolt commit` snapshots the
working set into history rather than altering or deleting rows, and beads
batch-commits routinely, so the effect was two extra commits in `sw`'s history
— but the trap is sharp enough to be worth writing down.

### 3. A new rig is staffed with `switchyard-ops` lanes automatically

`switchyard-ops` is imported at **city** scope, and gc expands a city import's
rig-scoped agents into **every** rig. A rig added for a toy run therefore
acquires the full lane set — `answerer`, `brakeman`, `dupe-scout`,
`golden-journey`, `intake-triage`, `judge`, `refactor-scout`, `security-scout`
— and `lane-ensure.sh` picks it up automatically, because `lane_rigs()` derives
its sweep set from `gc agent list --json` rather than from any allowlist. A
`sandbox/switchyard-ops.golden-journey` session did spawn during this run.

The lanes are inert here rather than dangerous: no `RIG_PROJECTS` entry maps
`sandbox` to a switchyard project, so `sy_rig_project_override sandbox` yields
the empty string and the lanes go scope-dark; the sandbox repo also has no git
remote, so PRD #334's git-remote scope resolution finds nothing either. They
still cost session slots.

Suspending them individually is **not** available — `gc agent suspend` refuses
a pack-defined agent (`use [[patches]] to override`) — so the two real controls
are `gc rig add --start-suspended` (which also stops the factory roles, so it
cannot be used *during* a run) and removing the rig when the run is done.

### 4. A step survives its agent's death only if someone re-reads the transcript

The sharpest finding of the run, and the one most worth fixing upstream: a
transient API outage stranded a step that had **already done its work**.

At 2026-08-12T23:24Z the `gc.task-decomposer` session (`gf-oxc4`) wrote
`plans/toy-greet/decomposition.md` (12,646 bytes), verified its own gate, and
announced the close. Its next API call died in a host-wide DNS failure
(~00:20–00:40Z, which killed unrelated sessions across the city too):

```
⏺ All in place. Setting the step outcome and closing.
  Ran 1 shell command
⏺ API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)
✻ Sautéed for 51m 45s
```

The work landed; the **state transition** did not. `sbox-il1` sat
`in_progress` for over two hours with its artifact complete on disk.

What makes this a factory-design finding rather than a bad night:

- **The two failure modes are externally identical.** "Finished but never
  recorded it" and "hung mid-task" both present as a step `in_progress` with a
  quiet session. No bead-level signal separates them.
- **Bead-state polling cannot see it.** A watcher keyed on step transitions
  reports a stall at 15 and 30 minutes for a step that is merely slow, and
  reports the same thing for one that is dead. Session `last active` is the
  finer signal, and the session transcript is the only *decisive* one.
- **`gc.session_affinity: require` makes it terminal, not self-healing.** The
  step is pinned to `gc.session_id: gf-oxc4`, so no sibling agent can pick it
  up. Nothing in the workflow retries it.
- **Recovery was one nudge, and cost nothing — confirmed, not theorised.**
  `gc session nudge gf-oxc4` with "your last call failed on a DNS blip, not on
  logic — retry the close, do not redo the decomposition" resumed the session
  at the failed call. Within minutes `sbox-il1` and `sbox-0rz` both closed and
  the decomposer's task beads materialised, taking the run from 6-of-42 to
  8-of-50 and releasing it into the drain step. The artifact was not rewritten.

The wrong reflex here is a relaunch: a second `gc sling` would re-run
decomposition from scratch and race a step whose output already existed. The
right one is to peek before concluding. **A factory step should be idempotent
at its close, or the run needs a sweeper that re-drives a step whose session
died after its artifact landed** — as it stands, an outage of a few minutes
costs hours of wall-clock and needs a human or an operator agent to notice.

### 5. The run's root bead reports `fail` on a run that was approved

The completed workflow root carries **both** of these:

```
gc.outcome:               fail
gc.build.final_outcome:   approved
```

They are two different axes, and a reader who checks the first one alone will
report a successful run as a failed one. That is not hypothetical — it is the
single most likely way this criterion gets misjudged from the bead state.

The cause is narrow and has nothing to do with the build. Two *control* beads —
implement control `sbox-n0f` and review-loop control `sbox-3gc` — quarantined on

```
lstat /Users/jeremy/gc-factory-sandbox/.gc/scripts: no such file or directory
```

because the sandbox rig has no `.gc/scripts/checks/` directory for gate scripts
to resolve against, and the `fail` propagated to the root. Their *iteration*
beads closed `pass`, the commit exists, the review loop had already recorded all
three `approve` verdicts and `code_review.verdict=done` before the quarantine,
and every proof command still passes on re-run. The run's own report flags this
under "Remaining Risks" as R-5 and warns, in its own words, that *"reading either
control bead's outcome instead of the item evidence will misread this build as
failed."*

Two things follow, and the second is the reusable one:

- **Rig wiring is a factory prerequisite.** A rig that will host factory runs
  needs `.gc/scripts/checks/` to exist, or its gate scripts cannot resolve and
  control beads quarantine on a filesystem error rather than on anything about
  the work. `gc rig add` does not create it.
- **A composite outcome field with two axes is read wrong eventually.** This is
  the same shape as switchyard's own `beads_mirror.completion_state` defect
  (PRD #333) — one field carrying a completion axis and a validation axis, where
  a writer or a reader takes one for the other. Here the *evidence* axis says
  approved and the *control* axis says fail, and only the artifacts disambiguate
  them. Worth carrying upstream as a gascity observation.

## The run

| | |
|---|---|
| **formula** | `build-basic` (gascity base pack, pin `3b3b89f2`) |
| **rig** | `sandbox` |
| **target** | `sandbox/gc.run-operator` |
| **task bead** | `sbox-kuw` — "Add a Greet function to the sandbox package that returns a fixed greeting, covered by a unit test" |
| **workflow root** | `sbox-e6k` |
| **vars** | `artifact_root=plans/toy-greet`, `interaction_mode=headless` |
| **publish posture** | `push=false`, `open_pr=false` (formula defaults, unchanged) |

Launched with:

```sh
gc sling sandbox/gc.run-operator sbox-kuw --on build-basic \
   --var artifact_root=plans/toy-greet \
   --var interaction_mode=headless --nudge
```

`--on` rather than a bare `--formula` sling because `build-basic` contains a
drain step, and a v2 formula with a drain requires a target convoy; `--on`
attaches the workflow to an existing bead and auto-creates that convoy.

## Run outcome

**The run completed.** Workflow root `sbox-e6k` is closed with
`gc.build.final_outcome: approved`, and its own final report
(`gc.build.final_report_path`) is committed here verbatim as
[`docs/evidence/prd-269-p0-build-basic/factory-run.md`](../../docs/evidence/prd-269-p0-build-basic/factory-run.md).

```console
$ env -u BEADS_DIR -u GC_BEADS_SCOPE_ROOT gc bd --rig sandbox list --all
...
Total: 50 issues (2 open, 0 in progress)
```

48 of 50 closed, **none in progress**. The two that remain open are not factory
steps: `sbox-kuw` is the source task bead the workflow was slung *on*, and
`sbox-9yu` is its input convoy. The denominator grew from the original 40
because the plan's own task beads are created by the run — a rising denominator
is the factory working, not drift.

### Every stage ran

| Stage | Bead | Result |
|---|---|---|
| Prepare build context | `sbox-0mx` | closed |
| Generate requirements | `sbox-p6y`, `sbox-xg6` | 6 requirements accepted |
| Write implementation plan | `sbox-kjy`, `sbox-qmw` | plan `approved` |
| Run design review | `sbox-3mq` | 5 findings, all resolved by amending the plan in place |
| Create task beads | `sbox-il1`, `sbox-0rz` | 1 work item (closed after the finding #4 nudge) |
| Drain implementation | `sbox-875`, convoy `sbox-kxl`, anchor `sbox-9qf` | commit `55e4267`, `gc.drain_state=succeeded` |
| Review loop | `sbox-3gc`, lanes `sbox-doc` / `sbox-9jx` / `sbox-elx`, fan-in `sbox-1n7` | 3 lanes → 1 synthesis, all `approve`, `code_review.verdict=done` |
| Apply review findings | `sbox-f7g` | deliberate no-op — 0 required fixes |
| Publish | `sbox-51v` | no-op by configuration (`push=false`, `open_pr=false`) |
| Finalize workflow | `sbox-9g5`, `sbox-eia` | closed — wrote `factory-run.md` |

The three review lanes fanned out over one shared context and fanned back in to
a single synthesis; all three returned `approve` with 0 required fixes, which is
why the fix lane was a no-op rather than a skip.

### What it built

The entire product of the run, in a source-anchor worktree:

```console
$ git -C /Users/jeremy/gc-factory-sandbox/worktrees/sbox-9qf show --name-status --oneline HEAD
55e4267 sandbox: add Greet() with the module's first unit test
M	sandbox.go
A	sandbox_test.go
```

Two files, 29 insertions, no new dependencies. Re-verified independently for
this write-up rather than taken from the report:

```console
$ go test -count=1 ./...
ok  	sandbox	0.748s
$ go vet ./... && go build ./...   # both exit 0
$ grep -n 'func Greet() string' sandbox.go
14:func Greet() string {
```

The full diff is committed at
[`delivered-commit-55e4267.patch`](../../docs/evidence/prd-269-p0-build-basic/delivered-commit-55e4267.patch).

The launcher checkout at `/Users/jeremy/gc-factory-sandbox` is **still at
`1595155`** and has no `Greet()`. That is the correct end state, not a partial
build: this run had `push=false` and `open_pr=false`, so the publish step was a
no-op by design and the work stays in the worktree. The run's own report says as
much in its Summary, unprompted.

### The artifact chain is verifiable, not asserted

Fourteen artifacts, all committed under
[`docs/evidence/prd-269-p0-build-basic/`](../../docs/evidence/prd-269-p0-build-basic/):

```
requirements.md            13,067 b   gc.build.requirements.v1, approved, REQ-001..006
implementation-plan.md     17,019 b   gc.build.plan.v1, approved, all 6 REQs covered
plan-review.md             13,751 b   design review
decomposition.md           12,646 b   gc.build.decomposition.v1
task-sbox-9qf-summary.md   12,444 b   per-item implementation summary
implementation-summary.md   9,544 b   canonical implementation summary
review-context.md          11,880 b   shared context the three lanes read
review-acceptance.md       11,302 b   lane: acceptance and correctness — approve
review-test-evidence.md    11,775 b   lane: test evidence — approve
review-simplicity.md        9,585 b   lane: simplicity and maintainability — approve
review-synthesis.md        12,181 b   fan-in synthesis — approve
review-fix-summary.md       7,333 b   fix-lane summary (no-op)
review-report.md           10,710 b   normalized review report
factory-run.md              9,635 b   gc.build.final-report.v1, status approved
```

Each carries a `trace.upstream` block of sha256 hashes over its inputs. The
final report's block covers ten of them, and **all ten were recomputed and
match** — so requirements → plan → review → decomposition → implementation →
review → report is a checkable chain rather than a claim. Anyone can repeat it;
the command is in the bundle's README.

Role handoff worked across the whole chain with no operator intervention:
`gc.run-operator` → `gc.requirements-planner` → `gc.review-synthesizer` →
`gc.task-decomposer` → `gc.implementation-worker` → three reviewer roles →
`gc.publisher`.

## What this proves, and what it does not

**Proves.** gascity's `build-basic` compiles and executes to a terminal,
approved state in this city against the pinned base pack, in a rig that
inherited the `gc.*` roles from the city's rig defaults, alongside the pinned
gastown core pack — with `gc import check` clean before and after, and no fork
of either import. It proves the *whole* starter lifecycle, not just its front
half: requirements, plan, design review, decomposition, bead creation, a
convoy-drained implementation in a separate worktree, a three-lane review with
fan-in, and a finalize that emitted its own report. Seven roles handed off to
one another with no operator in the loop.

**Does not prove.** Anything about `sy-build-from-prd`, which is P1's subject
and is not imported into this city. It also does not prove the factory path on
a *real* PRD: this run's task is a toy, chosen so the mechanics are what is
under test rather than the work. Those are separate criteria
(`crit:707a711e70df` interactive, `crit:d2c053dd7b13` headless) and neither is
delivered here. It does not prove the **publish** stage either — `push=false`
and `open_pr=false` made `sbox-51v` a no-op, so nothing exercised pushing a
branch or opening a PR from a factory run.

## Re-reading this run

The rig is deliberately still standing, so every claim above can be re-checked
at its source rather than only in this repo:

```sh
# every bd/gc call for another rig MUST clear the worker's own beads scope,
# which is set by environment and outranks the target repo's own metadata
env -u BEADS_DIR -u GC_BEADS_SCOPE_ROOT gc bd --rig sandbox list --all
env -u BEADS_DIR -u GC_BEADS_SCOPE_ROOT gc bd --rig sandbox show sbox-e6k

git -C /Users/jeremy/gc-factory-sandbox/worktrees/sbox-9qf show 55e4267
ls -la /Users/jeremy/gc-factory-sandbox/plans/toy-greet/
```

Read `gc.build.final_outcome`, **not** `gc.outcome`, on the root — finding #5
explains why the two disagree and which one describes the build.

## Cleanup still owed

Deliberately **not** done in the session that finished this file, because the
rig is the primary source this evidence is derived from and removing it is
irreversible. It should happen once the criterion is validated:

```sh
gc rig remove sandbox   # retires the rig and the switchyard-ops lanes of finding #3
gc dolt cleanup         # reaps the orphaned `sbx` database from an earlier attempt
```

Until then the rig costs four idle `sandbox/switchyard-ops.*` session slots
(finding #3): they are scope-dark and inert, but they are not free.
