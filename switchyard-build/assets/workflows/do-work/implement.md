This is switchyard's per-item implement prompt. It shadows the Gas City base
pack's `assets/workflows/do-work/implement.md` through the documented asset
path-shadow seam, so the base `do-work` formula stays inherited and unforked
while the work each drained item does is switchyard's.

A shadow REPLACES the base file; it does not merge with it. Every inherited
instruction is therefore restated below. Do not trim this file down to the
switchyard rules — deleting a line here deletes the instruction, and a weaker
prompt at the same path silently shadows the stronger one it replaced.

## Why this file, and not an `implement` step override in the formula

`build-base`'s `implement` stage is the DRAIN ORCHESTRATOR, not the work: it
carries `[steps.drain] formula = "do-work"` and hands each convoy member to a
separate session. Overriding the `implement` anchor in
`sy-build-from-prd.formula.toml` would therefore rewrite the drain's prose and
leave the per-item work running gascity's generic instructions. The per-item
work runs HERE, in `do-work`'s own `implement` step, once per convoy member in
that member's own worktree. `sy-build-from-prd` narrows
`allowed_drain_policies` to `separate`, so this is the only per-item path a
factory run takes.

## The item you are working is a LEASED switchyard pool bead

The convoy member you own mirrors a bead in switchyard's cloud claim pool, which
the `decompose` stage already claimed under a lease. Read the linkage from the
source anchor's metadata:

- `sy.pool.bead_id` — the switchyard pool bead this item delivers
- `sy.pool.claimed_by` — the identity that holds the lease
- `sy.pool.prd_id` — the PRD this run delivers
- `sy.pool.crit_label` — the `crit:<hash>` acceptance criterion
- `sy.pool.phase_label` — `P0`, `P1`, … or empty
- `sy.pool.lease_expires_at` — when the lease lapses if nobody renews it

**`sy.pool.claimed_by` is load-bearing. Use it verbatim; never re-derive it.**
Every lease action is accepted only for the identity that took the claim, so a
guessed or reconstructed identity is refused — and the refusal looks like a
busy bead rather than like your mistake. It is deliberately one identity PER
BEAD (`sy-build/<prd-id>/<pool-bead-id>`): switchyard's WIP limit keys on the
`claimed_by` STRING, so a single shared identity across the drain would get the
second concurrent claim refused.

If the source anchor carries no `sy.pool.bead_id`, this item is not pool-backed.
Implement it, run the gates in Rule 3, and skip Rules 1 and 2.
Do not invent a pool id, and never call a lease action with a guessed one — the
id you would guess is another criterion's bead, and the action would land on it.

## Rule 1 — heartbeat the lease for as long as you hold the item

    claim_action { kind: "bead", action: "heartbeat",
                   bead_id:    "<sy.pool.bead_id>",
                   claimed_by: "<sy.pool.claimed_by>",
                   lease_seconds: 3600 }

Pass `sy.pool.claimed_by` exactly as it is recorded; never re-derive it. The
lease renews only for the identity that took the claim, so a reconstructed
identity is refused — and the refusal reads as a busy bead, not as your error.

Heartbeat at least every 15 minutes while the item is open, and ALWAYS
immediately before starting anything expected to run for minutes — a full test
suite, a schema migration, a long build. Those are exactly the stretches where
a session goes quiet for longer than it means to.

The lease is taken at the server's one-hour cap and renewed, rather than held
open by a longer lease class (settled by switchyard PRD 269 q179). One hour is
the ceiling, not a budget: a heartbeat is the only thing separating a live item
from a reclaimed one.

Why this matters more than it looks: the claim-pool lease is the ONLY mutex
between switchyard's execution lanes. A lapsed lease is swept back to the pool,
another lane claims the same criterion, and two workers build it in parallel —
a collision discovered at merge, when the loser's work is already written. A
quiet claim also reads as STALLED on the PRD page, so a human triaging the
board sees a wedged item where there is a working one.

Record what you are doing as you go by passing task-trace `events` on the
heartbeat — `plan` for the approach you chose, `checkpoint` for a unit of
progress, `verification_run` for a command and its exit code, `blocked` for a
blocker hit. This is the process trace a reviewer reads later; it costs one
argument on a call you are already making.

**A lost lease does not invalidate finished work.** If a heartbeat is refused
(409) because the lease was already swept, that is BOOKKEEPING, not a verdict
on your code. Do not delete your branch and do not abandon the item. Commit
what you have, push the branch, and report the lost lease in the summary's
`## Remaining Risks` so the run can re-claim and reconcile. Discarding sound
work over an expired timestamp is the more expensive mistake.

## Rule 2 — release on abandon; never let the lease lapse silently

If you stop WITHOUT delivering — blocked, out of scope, the item turns out to be
already satisfied by merged main, or you exhausted your attempts — hand the bead
back explicitly:

    claim_action { kind: "bead", action: "release",
                   bead_id:    "<sy.pool.bead_id>",
                   claimed_by: "<sy.pool.claimed_by>",
                   handoff: { changed:              "...",
                              verified_now:         "...",
                              broken_or_unverified: "...",
                              next_best_step:       "...",
                              commands:             "...",
                              repo_ref:             "<branch or commit SHA>" } }

Release WITH a handoff, always. An abandoned item that simply goes quiet strands
the criterion for the lease's full hour and then re-offers it to a worker who
starts from zero — rediscovering the same blocker, in the same order, at the
same cost. The handoff is the difference between the next session resuming and
the next session repeating. Write the handoff's `broken_or_unverified` honestly: a
half-built branch described as clean is worse than one described as broken.

**Do not complete the bead from this step.** Completion belongs to the run's
`finalize` stage, and it is gated on a MERGED pull request: attaching a PR marks
the PRD's criteria delivered and judge-reachable, so attaching one that is
merely OPEN gets unlanded code signed off as done. At per-item time your PR is
open by construction. Leave the bead claimed, leave the branch pushed, and let
`finalize` complete it once the PR lands.

Never release a bead you do not hold, and never force-release one another lane
holds. A claim you cannot take is reported, not resolved.

## Rule 3 — the switchyard quality gates, before this item is done

switchyard's repository gates are not optional and not deferred to review. Run
them from INSIDE the item's worktree, after `cd "$WORKTREE"`:

    go build ./...
    go vet ./...
    go test ./...

**If you edited any `.templ` file, regenerate before the gates above:**

    go run github.com/a-h/templ/cmd/templ@latest generate ./internal/dashboard/

`.templ` files generate Go code, and the generated `_templ.go` is what compiles.
Skipping this produces two distinct failures that look nothing alike: a MISSING
regeneration fails as `undefined: <name>`, while a STALE one fails as a
signature mismatch on a function that plainly exists. Both are avoidable by
running the generator, and both waste a reviewer's time when they reach CI.
Commit the regenerated files alongside the source change.

**Red is not done.** A failing test is fixed, not disabled, not skipped, and not
handed onward as "pre-existing". If a test fails for a reason genuinely outside
this item's boundary, that is a Rule 2 release with the failure named in the
handoff — not a green summary with a caveat buried in it.

Record the gate commands and their observed results in the summary's
`## Verification` section (see below). The section requires both the first
verification command and the final proof command with observed pass/fail, so the
gates are the natural content for it, not an addition to it.

Publishing is not this step's job: a factory run publishes PR-only, from the
`publish` stage, and switchyard's repository forbids pushing to `main`. Commit
in the worktree and leave the branch for the publisher.

## Rule 4 — judge the item's plan before you build it, and fan out past the threshold

**Run this before Rule 3's gates, and before you write a line of the item.**

An epic-sized item is epic-sized whichever lane reached it. A `switchyard-ops`
brakeman that claims a criterion from the cloud pool and this drain's per-item
step do the same job at the same granularity: build ONE criterion, in ONE
worktree, on ONE branch, and leave ONE pull request. So the fan-out decision is
the same decision, and it is made by the same script — never by a second one
written on this side of the seam.

### The item's plan artifact

Before building, write your build plan for THIS item as an artifact: one plan
item per line, no numbering needed, `#` comments and blank lines ignored. Put it
under the run's artifact root beside the other build artifacts, at
`<artifact_root>/items/<sy.pool.bead_id>/plan.txt`, and record its absolute path
on the claimed step bead:

    gc bd update "<claimed-step-id>" \
      --set-metadata "gc.build.item_plan_path=<absolute path>"

This is a per-ITEM artifact and not the run's `gc.build.plan_path`. The run-level
plan artifact is PRD-shaped — phases and criteria, which the `decompose` stage
already mapped to this convoy — so its items are the criteria, not the tasks
inside the one criterion you hold. The plan that can exceed a fan-out threshold
is this one.

### Judge it with the shared decomposer

    packs/switchyard-build/assets/scripts/resolve-fanout.sh decompose \
      --plan <gc.build.item_plan_path> --rig <the run's rig> \
      --crit "<sy.pool.crit_label>" --prd "<sy.pool.prd_id>"

`resolve-fanout.sh` locates the installed `switchyard-ops` pack and `exec`s
`fanout-decompose.sh`; it decides nothing itself. Everything the decomposer
governs stays the decomposer's: `SY_FANOUT_THRESHOLD` (default 4, which the plan
must **strictly exceed**), the `SY_FANOUT_ENABLED=0` kill switch, the
concurrency cap, and the one `fanout-decompose:` decision line an operator
reads. **Do not implement any part of that judgment here** — a second threshold
comparison drifts from the first at the boundary, and a kill switch that stops
the pool lane but not the factory lane is worse than no kill switch, because
nothing says which lane a reader is looking at.

Set `SY_FANOUT_OPS_PACK_DIR` to the installed `switchyard-ops` pack root if the
resolver cannot find it (it reports `source=` on every run, and `source=none` on
none). **If it exits `3` it has resolved nothing: build the item SERIALLY and say
so in `## Remaining Risks`.** Do not answer the fan-out question locally. That
degradation is the same one `fanout-decompose.sh` takes when it cannot mint —
one worker, building serially, reporting it — and it is the only correct one.

### `decision=serial` — build the item yourself

Nothing was minted and nothing changed: implement the plan, heartbeating under
Rule 1, and run Rule 3's gates yourself. This is byte-for-byte the behaviour
this step had before fan-out existed, which is what a run that configures
nothing gets.

### `decision=fanout` — the integration gate IS the build step

Build **no plan item yourself**. The gate runs each item exactly once through the
child harness and refuses (exit `4`) a run whose children produced nothing — so
an item you pre-built re-briefs a child over finished work, that child changes
nothing, and the gate fails over a tree that is in fact complete.

Run the gate through the lease keeper, resolving both through the same resolver:

    "$(packs/switchyard-build/assets/scripts/resolve-fanout.sh --which lease)" \
      --bead "<sy.pool.bead_id>" --agent "<sy.pool.claimed_by>" \
      --tenant <tenant> --project <project> -- \
      "$(packs/switchyard-build/assets/scripts/resolve-fanout.sh --which integrate)" \
        --worktree "$WORKTREE" --branch <this item's branch> \
        --plan <gc.build.item_plan_path> \
        --parent <the decomposer's parent bead> --crit "<sy.pool.crit_label>" \
        --prd "<sy.pool.prd_id>" --rig <the run's rig> \
        --verify '<this criterion's verify_command>'

The keeper is not optional. You are blocked in one long call for the whole
fan-out, and a blocked session heartbeats nothing — Rule 1's cadence cannot be
kept from inside a fan-out, so the beat has to come from a process that is not
this session. A lease that lapses mid-gate hands your bead to a successor while
you still hold the worktree.

`--verify` is **this criterion's own `verify_command`**, which the run's plan
artifact records in its test strategy for your `sy.pool.crit_label`. switchyard
judges the criterion by exactly that command, so a gate that chose its own suite
would be green against a contract nobody is judged by. **A criterion that
declares no `verify_command` cannot be fanned out**: the gate fails
`reason=no-verify` by design. Build that item serially and record the missing
contract in `## Remaining Risks`.

The gate's exit code is the publish gate — zero means the item is done, anything
else means it is not, and it runs the build and the targeted tests over the
combined tree, which is Rule 3's gates discharged for a fan-out. A nonzero exit
is a Rule 2 release with the gate's own report line in the handoff, not a green
summary with a caveat in it.

### Report the decision either way

Paste both the `fanout-decompose:` line and, on a fan-out, the
`fanout-integrate:` line verbatim into the item summary's `## Verification`
section. A serial run reports too: a decomposer that fans out correctly and
stays silent when it declines is, from outside, indistinguishable from one that
crashed — both leave a serial build and no beads. The behaviour, every knob and
every failure path are documented in `docs/epic-fanout.md`.

## Inherited instructions — carried over from the base implement prompt, none dropped

### Resolving the worktree

Resolve `<source-anchor-id>` using the same rules as `prepare-worktree`. For a
synthetic drain-unit convoy, the source anchor is the original drain member in
`gc.drain_member_id`, not the synthetic convoy id. Read `work_dir` from the
source anchor, never read `work_dir` from the synthetic drain-unit convoy,
validate that it is an absolute existing git worktree, set `WORKTREE` to that
path, then `cd "$WORKTREE"` before reading or editing source files. If
`work_dir` is missing, invalid, or points at the launcher checkout, fail this
step before editing.

Do not infer the source anchor from dependency ids such as the
`prepare-worktree` step. Read the claimed step bead's `gc.root_bead_id`, read
that do-work root with `gc bd show <root-bead-id> --json`, then read the root
metadata `gc.input_convoy_id`. Read that input convoy with `gc bd show
<input-convoy-id> --json`; if the JSON output is a one-element list, unwrap the
first element before reading metadata. If the input convoy has
`gc.synthetic_kind=drain-unit-convoy`, use its `gc.drain_member_id` as the
source anchor. Otherwise use the input convoy id as the source anchor. Then
read the source anchor and use only its `work_dir` metadata as `WORKTREE`.

`gc.work_dir` is the launcher rig root, not the implementation worktree. Use
`gc.work_dir` only later to run `.gc/scripts/checks/build-artifact-valid.sh`.
After resolving `WORKTREE`, run `cd "$WORKTREE"` and verify `pwd -P` equals
`$WORKTREE` before any source read, source edit, test, file hash, `git add`, or
`git commit`. If a command uses the launcher checkout path for source edits,
verification, hashes, or commits, the step is invalid and must fail.

Do not edit files in the launcher checkout. Implement only the owned source
anchor boundary, run sandboxed verification from inside the worktree, and make a
focused commit in the worktree. Leave the source anchor open for
`close-source-anchor`; close only this implementation step when done.

### The item summary artifact

Write or update the task summary with these schema-required body sections,
using the exact `##` headings below in this order:

- `## Summary`
- `## Intended Behavior`
- `## Changed Files`
- `## Verification`
- `## Remaining Risks`

The `## Verification` section must include both the first verification command
and the final proof command, with the observed pass/fail result.

Write the summary as a `gc.build.implementation-summary.v1` artifact and record
its absolute path on the workflow root bead as `gc.implementation.summary_path`
before closing.
Include a Markdown coverage table. The validator only recognizes a table with
an `ID` column and a `Status` column. Use this shape:

| ID | Status |
| --- | --- |
| REQ-001 | covered |

For a factory run the covered ids are the switchyard criteria this item
delivers — use the `sy.pool.crit_label` value, so the coverage table joins back
to the PRD rather than to a locally invented requirement id.

Use mapping objects for front matter; do not use scalar shortcuts such as
`workflow: sy-build-from-prd`. The top-level YAML shape must be:

- `schema: gc.build.implementation-summary.v1`
- `workflow: {id: <workflow-root-id>, formula: <root-workflow-formula>}`
- `methodology: {pack: switchyard-build, name: sy-build-from-prd}`
- `producer: {formula: do-work, stage: implement, attempt: <positive integer>}`
- `status: approved` or another schema-allowed status
- `trace: {upstream: [...], coverage: [...]}`

`producer` names the formula and stage that actually produced the artifact,
which for a drained item is `do-work` / `implement` — this file's own step, not
the parent factory formula. `methodology` names the pack driving the run.

Trace front matter must use the validator shape exactly:

- `trace.upstream[]` entries must include `path` and `hash`; do not use
  `id`/`title`/`type` entries as the upstream shape.
- For the source anchor bead, use `path: beads/<source-anchor-id>` and
  `hash: bead:<source-anchor-id>`. For changed files or upstream build
  artifacts, use repo-relative paths and scheme-qualified hashes such as
  `sha256:<digest>` or `git:<revision>`.
- If an upstream entry lists `ids`, every listed id must appear exactly once in
  `trace.coverage` and in the Markdown coverage table with the same status.
- Coverage statuses are not artifact statuses. Use `covered` for satisfied
  requirements; do not use `approved` in `trace.coverage[].status` or the
  Markdown coverage table.

### Artifact validation

Artifact validation: this step is gated by `.gc/scripts/checks/build-artifact-valid.sh`, which validates the summary recorded at `gc.implementation.summary_path` (fallbacks `gc.build.implementation_summary_path`, then `gc.var.summary_path`) against schema `gc.build.implementation-summary.v1`. Before closing this step, read the launcher rig root from the workflow root bead's `gc.work_dir`, then run the same validator locally from that rig root with `GC_BEAD_ID=<claimed-step-id> .gc/scripts/checks/build-artifact-valid.sh`; fix every reported validation error before setting `gc.outcome=pass`. On repair attempts (`gc.attempt` greater than 1), read the validator errors from `gc.attempt_log` on the validation loop control bead (the dependent of this step bead) and repair the summary in place instead of rewriting it. Two bounded repair attempts follow the first failure; exhausting them closes this stage with `gc.outcome=fail` and machine-readable validation errors that block downstream stages. Never ask questions in headless mode; record unresolved ambiguity inside the summary.

Heartbeat the pool lease (Rule 1) before entering a repair attempt. Repair
loops are a common place for an item to go quiet past its lease.
