# switchyard-build Compatibility Ledger

This ledger is the pack-local evidence that `switchyard-build` preserves the Gas
City `build-base` contract while layering switchyard's PRD-driven delivery loop
on top. It is the switchyard-side counterpart to `GC-METH-012` (external
implementation compatibility) in `gascity/REQUIREMENTS.md`, which
`gascity/tests/test_derived_pack_compatibility.py` enforces for the four packs
that live inside gascity-packs.

Each claim names the files that prove it. The Evidence Commands section gives
the exact commands that reproduce the proof. A claim that is not yet true is
recorded as **PENDING** against the switchyard PRD #269 acceptance criterion
that will satisfy it — this ledger never asserts evidence that does not exist.

| Field | Value |
| --- | --- |
| Status | Manifest, ledger, `sy-build-from-prd`'s source stage (`fetch-prd` and the three anchors it feeds), the `decompose` (pool → convoy) override, the `build-base` publish override (completion summary), and the publish preflight override |
| Scope | switchyard's factory execution path for epic-scale approved PRDs |
| Base contract | `gascity/REQUIREMENTS.md` (`gc.build-methodology-base.requirements.v1`) |
| Base formula | `build-base` |
| Upstream anchor | `GC-METH-012` |
| Pinned base | `gascity-packs` `sha:3b3b89f2011e06d84459aa7bea1552382f13930a` |

## Divergence From The In-Tree Derived Packs

`compound-engineering`, `superpowers`, `bmad`, and `gstack` are authored *inside*
gascity-packs, so each binds the base pack with a relative source:

```toml
[imports.gc]
source = "../gascity"
```

`switchyard-build` is authored in the **switchyard** repo instead — deliberately,
so the pack can never skew from the server it drives: pinning a switchyard commit
pins the API, the MCP tool surface, and this pack together. A `../gascity` path
would therefore dangle. This pack takes the pinned-remote form that
`packs/examples/city/pack.toml` already documents for `gc`, which is the same
binding name and the same base pack, resolved over git rather than over the
filesystem.

Two consequences follow, and they are the reason this section exists rather than
being left implicit:

1. `gascity/tests/test_derived_pack_compatibility.py` does **not** cover this
   pack. Its `DERIVED_PACKS` list is the four in-tree packs, and it reads them
   from the gascity-packs checkout. The claims below are therefore verified on
   the switchyard side: `scripts/check-derived-pack-compat.sh` is this repo's
   counterpart to that suite and runs in CI as the **`derived-pack
   compatibility`** job, and the Evidence Commands below cover what a static
   gate cannot reach (see the split under *Verified in CI* next).
2. The base moves only on an explicit `gc import upgrade`. After any upgrade,
   re-run the Evidence Commands and reconcile every claim the new base
   invalidates, in the same change that moves the pin.

## Compatibility Claims

### In force now

- **Import contract.** `packs/switchyard-build/pack.toml` imports the Gas City
  base pack as `gc`, so the pack inherits the shared `gc.*` surface (base
  formulas, role targets, template fragments) instead of re-defining it. The
  binding name is `gc` specifically because that is what gascity's own formulas
  and its `roles` sub-pack expect; renaming it breaks every `gc.*` route target
  (`gc.implementation-worker`, `gc.publisher`, `gc.run-operator`).
- **Pinned and unforked.** The import carries an explicit
  `version = "sha:..."` pin, verified to contain `gascity/pack.toml` at that
  commit. switchyard policy is required to ride gascity's documented stable
  override seams — `extends` on `build-base`, the `*_formula` selector vars, the
  `[metadata.gc.methodology]` block, and the path-shadow override contract — so
  that no change here requires editing gascity. A change that cannot be
  expressed through a seam is escalated upstream rather than resolved by forking
  the pin.
- **Mirror parity.** The pack is republished to the public mirror by
  `.github/workflows/mirror-packs.yml`, whose pre-publish sanity check names
  `switchyard-build` alongside `switchyard-ops` and `switchyard-mcp`, so a
  vanished or renamed pack fails the mirror push instead of silently deleting
  the pack from every consumer's next `gc import upgrade`.
- **System of record.** This pack mints no work. It claims work switchyard
  already holds and hands the delivery record back, leaving switchyard — not the
  local bead ledger — authoritative for PRD progress and per-PRD spend.
- **Requirements/plan artifacts.** `sy-build-from-prd` declares
  `extends = ["build-base"]` and its `fetch-prd` stage renders `requirements.md`
  and `implementation-plan.md` from an approved PRD's own sections, recording the
  app-side approval on the workflow root as the `plan-review` evidence
  (`gc.build.plan_review_evidence=switchyard-prd-approval`, alongside the PRD id,
  version, approval time and approver account). The `requirements`, `plan`, and
  `plan-review` anchors are overridden **under their base ids**, keeping their
  base artifact schemas and their `build-artifact-valid.sh` gates, so a
  PRD-derived artifact is validated by exactly the check the base would have
  applied; only the authoring instruction changes, from *author* to *confirm*.
  `fetch-prd` is an added stage between `prepare` and `requirements`, so no
  anchor is renamed, skipped, or reordered. Every remaining anchor is still
  inherited unchanged and is listed as Pending below.
  Satisfies `crit:3ee33868b070`.

- **Convoy mapping.** `packs/switchyard-build/formulas/sy-build-from-prd.formula.toml`
  overrides the base `decompose` anchor — under its own base id, restated in
  full — and points it at
  `packs/switchyard-build/assets/workflows/sy-build-from-prd/map-pool-to-convoy.md`,
  which claims the target PRD's pool beads under lease, mints a local convoy
  ordered by phase, and reports every bead it could not take. Three properties
  carry this claim, and each is the reason a neighbouring rule was rejected:
  - **The lease is the mutex, so a skip is never a steal.** A bead held by
    another lane is skipped and reported, never released or waited out; the run
    hands back rather than taking a live claim, per the PRD's stop condition.
    The report rides `trace.coverage` with the schema's own `blocked` status, so
    the base's `build-artifact-valid.sh` gate enforces it instead of leaving it
    to optional prose.
  - **One identity per bead, derived deterministically.** The pool's WIP cap
    (`projects.pool_wip_limit`, default 1) keys on the `claimed_by` string —
    `HeldPoolBeads(project_id, claimed_by)` — so a run holds a whole PRD's beads
    only by claiming each as `sy-build/<prd_id>/<pool-bead-id>`. Deriving it
    rather than randomising it is what lets a retry recognise its OWN prior
    claims instead of reporting them as another lane's and minting an empty
    convoy.
  - **Phase order comes from one pool read.** `list_claimable_beads` projects
    `phase_label` beside `prd_id` and `crit_label` (crit:f74755f880ea), which is
    the whole reason that projection exists (q178/q189). The criteria read is
    for the skip report only, never for phase.
  Satisfies `crit:f8594ebe6dba`.

- **Artifact contract preserved.** The `decompose` override changes only `title`
  and `description_file`; `gc.run_target`, both `gc.build.*` artifact keys,
  `needs`, and the `build-artifact-valid.sh` check block are the base's own,
  restated verbatim because `extends` merges steps by WHOLE-STEP REPLACEMENT.
  The stage still emits `gc.build.decomposition.v1` at the recorded
  decomposition path and still sets `gc.input_convoy_id` +
  `gc.build.implementation_convoy_id` for the inherited `implement` drain.

- **Per-item implement override** (`crit:4ea0ccf29b82`).
  `assets/workflows/do-work/implement.md` overrides the per-item implement
  prompt through the asset path-shadow seam, so `gascity/formulas/do-work.formula.toml`
  stays inherited and unforked — no `extends`, no step rename, no edit to the
  pin. The directory is `do-work/`, not `build-base/`: `build-base`'s `implement`
  stage is the DRAIN ORCHESTRATOR (`[steps.drain] formula = "do-work"`), so the
  per-item work runs in `do-work`'s own `implement` step and a shadow written at
  the base stage's path would rewrite the drain's prose while leaving every item
  on gascity's generic instructions. The override binds the three things a
  leased item owes the pool: **heartbeat** the claim (reusing `sy.pool.claimed_by`
  verbatim, since the pool renews a lease only for the identity that took it, and
  the factory holds one identity per bead because switchyard's WIP limit keys on
  that string), **release on abandon** with a handoff — explicitly *not* complete,
  because at per-item time the PR is open by construction and attaching an open PR
  marks a PRD's criteria delivered and judge-reachable — and the **switchyard
  quality gates** `go build ./...`, `go vet ./...`, `go test ./...` with
  `templ generate` ordered ahead of them. Because a shadow *replaces* the base
  file rather than merging with it, the override restates every inherited base
  instruction (worktree resolution, the summary's required sections, the coverage
  table, the front-matter and trace shapes, the validator loop); the
  `implement-item-gate` CI job asserts each one is still present, so a rewrite
  cannot silently install a weaker prompt at the stronger one's path.

- **One decomposer, shared with the pool lane** (switchyard PRD #372,
  `crit:6a3b156b1a02`). The per-item `implement` stage and the `switchyard-ops`
  brakeman build a criterion at the same granularity — one criterion, one
  worktree, one branch, one pull request — so past `SY_FANOUT_THRESHOLD` the impl
  stage fans out through `switchyard-ops`'s own
  `assets/scripts/fanout-decompose.sh`, and this pack ships **no decomposer of its
  own**. Rule 4 of the implement override writes the per-ITEM plan artifact
  (`gc.build.item_plan_path`, deliberately not the run's PRD-shaped
  `gc.build.plan_path`, whose items are the criteria the `decompose` stage already
  mapped to this convoy) and hands it to that script through
  `assets/scripts/resolve-fanout.sh`, which resolves the installed ops pack and
  `exec`s it — argv, stdin, stdout and the exit code cross untouched, its own
  report goes to stderr, and it prints no `decision=` ever. Unresolvable, it exits
  `3` and the item is built serially; it never answers the question locally. A
  second implementation would pass every functional test while drifting the one
  decision line an operator reads, disagreeing at the strictly-exceeds boundary,
  and leaving `SY_FANOUT_ENABLED=0` stopping one lane and not the other — so
  `scripts/fanout-shared-decomposer.test.sh` asserts the STRUCTURE (exactly one
  shell file under `packs/` formats a decision line; no `switchyard-build` script
  dereferences the threshold knobs) before any behaviour. Behaviour:
  [docs/epic-fanout.md §6](../../docs/epic-fanout.md).

- **Review and gap analysis.** Both verdict reports trace the PRD's acceptance
  criteria one row each, keyed by `crit:<hash>`, carrying switchyard's
  `met`/`partially_met`/`missing` verdict alongside the base `coverage_statuses`
  vocabulary, and a `met` row names the PR that delivered it. The two overrides
  ride the documented path-shadow seam — `assets/workflows/review/write-report.md`
  and `assets/workflows/gap-analysis/write-report.md`, the base's own asset paths
  — so no gascity formula is edited and the pin stays unforked. `crit:c20b14ed613e`.

- **Completion summary** (`crit:867e5f748573`).
  `assets/workflows/build-base/publish.md` overrides the run's terminal stage
  through the asset path-shadow seam, so `build-base` stays inherited and
  unforked — no `extends`, no step rename, no edit to the pin. The stage is
  `publish` because it is build-base's LAST anchor (`needs = ["finalize"]`, no
  condition): at `finalize` the pull requests are not open yet — finalize records
  the outcome metadata that publish then acts on — so a summary posted any
  earlier could not name a single PR. The override resolves its destination from
  the PRD itself: `get_prd` returns the PRD's `blueprint_id`, which the PRD page
  renders as its **Discussion** section (the composer there posts to the same
  endpoint the `post_blueprint_message` tool hits), and the summary is attributed
  to the registered factory agent via `agent_ref` rather than to the human
  account behind the token. Three properties make the claim more than "a message
  is sent": the destination is resolved from the PRD rather than from a launch
  input, so a run cannot post another PRD's readers a summary of work never done
  for them; the post is guarded by `gc.build.completion_summary_posted_at` read
  BEFORE posting, because this stage is retryable and a discussion thread is
  append-only with no de-duplication; and the summary reports rather than
  fabricates — it never claims a criterion is delivered, since delivery is
  recorded by attaching a MERGED PR. Because this file sits at the BASE pack's
  asset path it is inherited by every formula extending `build-base`, not only
  `sy-build-from-prd`, so it reads the PRD id from the workflow root's
  `gc.build.prd_id` (never a `{{prd_id}}` placeholder, which renders its own raw
  body where that var is undefined) and degrades to a recorded
  `completion_summary_status=skipped` no-op on a run that had no source PRD.
  Because a shadow *replaces* the base file rather than merging with it, the
  override restates the base's whole publish contract — all five required
  workflow-root keys, the disabled-publishing branch and its remote status, and
  the close conditions; the `completion-summary-gate` CI job asserts each one is
  still present, so a rewrite cannot silently install a weaker publish gate at
  the stronger one's path.

- **Compatibility test in CI.** `scripts/check-derived-pack-compat.sh` enforces
  the statically checkable claims above on every push and pull request, as the
  `derived-pack compatibility` job in `.github/workflows/ci.yml`. It is
  self-tested against hermetic fixtures by
  `scripts/check-derived-pack-compat.test.sh`, which runs first in the same job
  — a gate nothing exercises is indistinguishable from a gate that passes
  everything.

### Verified in CI, and what is not

The gate covers the claims that can be checked from this repository alone:
the binding is named `gc` and is the only import, the base is pinned to a
40-hex commit rather than a moving ref, the source is the pinned remote and
never `../gascity`, every pin this ledger asserts equals the pin the manifest
holds, the anchors below are all present, every `crit:` label is well-formed,
and the mirror workflow still guards this pack by name.

Three Evidence Commands are deliberately **left out** of it: the two `gh api`
calls and `gc import check` need the network, credentials, or the `gc` binary.
A gate that skips itself when one of those is unavailable would report success
for a check that never ran, which is worse than no gate at all — CI would go
green and be read as "compatible". Those three stay manual, run at
pin-upgrade time.

Pin coherence is the claim most likely to be the one that fires. The pin is
written in three places — the manifest's `[imports.gc]`, the `Pinned base` row
above, and the `PIN=` line below — and an upgrade moves the first, leaving this
ledger vouching for a commit the pack no longer imports.

- **Publish contract** (`crit:c8bee483d06e`). `assets/workflows/publish/preflight.md`
  overrides the base publish preflight through the asset path-shadow seam:
  `gc`'s formula parser resolves a `description_file` written in the documented
  `../assets/…` form against every search-path layer and keeps the last match
  (`internal/formula/parser.go`, `readDescriptionFile`), so this pack's copy wins
  while `gascity/formulas/publish.formula.toml` stays inherited and unforked —
  no `extends`, no step rename, no edit to the pin. The override enforces
  **PR-only publishing** (a direct push to the default or any protected branch is
  refused *even when* `push` is authorized, because the factory always holds push
  authorization to write its topic branch) and requires **both the PRD and pool
  bead ids in the PR title**, with the `PRD #N` ref bounded to exactly one
  occurrence across title, body and branch so a factory PR cannot trip the
  repository's own `prd-ref guard` and end up auto-linked to no PRD. Unevaluable
  checks fail closed. Because a shadow *replaces* the base file rather than
  merging with it, the override restates every inherited base check; the
  `publish preflight-gate` CI job asserts each one is still present, so a rewrite
  cannot silently install a weaker gate at the stronger one's path.

### Pending

Each row lands with the switchyard PRD #269 acceptance criterion named beside
it. Until then the claim is not made.

| Claim | Lands with |
| --- | --- |
| **Formula contract** — `sy-build-from-prd` declares `extends = ["build-base"]` and preserves the inherited anchor order, overriding steps under their base ids without renaming, skipping, or reordering an anchor | the `sy-build-from-prd` step criteria below, collectively |


## Evidence Commands

Run these from the switchyard repository root.

The first command is the whole statically checkable set at once; the rest are
either what it checks (kept here because this ledger should stay readable
without reading the gate) or the three it deliberately cannot reach.

```sh
# Everything checkable offline, in one run — the same gate CI runs.
bash scripts/check-derived-pack-compat.sh

# ...and the gate's own self-test, which CI runs first.
bash scripts/check-derived-pack-compat.test.sh

# Import contract: the pack binds the base as `gc`, pinned.
sed -n '/^\[pack\]/,$p' packs/switchyard-build/pack.toml

# The binding name is exactly `gc` (expect one match).
grep -c '^\[imports\.gc\]' packs/switchyard-build/pack.toml

# The pin is a real gascity-packs commit, and it carries the base pack.
# NOTE: do not "simplify" this to `git ls-remote | grep <sha>`. ls-remote lists
# REF TIPS only, so a pinned commit that is not a branch or tag head is absent
# from its output — that check reports a false negative on a perfectly good pin.
PIN=3b3b89f2011e06d84459aa7bea1552382f13930a
gh api "repos/gastownhall/gascity-packs/commits/$PIN" --jq .sha
gh api "repos/gastownhall/gascity-packs/contents/gascity/pack.toml?ref=$PIN" --jq .path

# Mirror parity: the pre-publish guard names this pack.
grep -n 'for pack in' .github/workflows/mirror-packs.yml

# Per-item implement override (crit:4ea0ccf29b82): the override sits at the
# shadow path, retains every inherited base instruction, and binds the heartbeat
# identity, the release-on-abandon direction and all four quality gates inside
# their own sections. 46 assertions.
#
# The path is part of the assertion twice over — see the In-force claim above.
# The suite checks the path first, because a prompt one directory across (or
# under build-base/ rather than do-work/) overrides nothing and fails silently.
bash scripts/implement-item-gate.test.sh

# The same suite runs in CI as the `implement-item-gate self-test` job.
grep -n 'implement-item-gate' .github/workflows/ci.yml

# One decomposer (crit:6a3b156b1a02): the structural claim first — exactly one
# shell file in packs/ formats a fan-out decision line, and it is switchyard-ops's
# — then resolution precedence, exec-passthrough, refusal-not-substitution, and
# the impl prompt's route. 37 assertions, under bash and dash.
bash scripts/fanout-shared-decomposer.test.sh
FANOUT_TEST_SH=dash bash scripts/fanout-shared-decomposer.test.sh

# This pack ships NO decomposer. Expect exactly one hit, in switchyard-ops.
grep -rl --include='*.sh' 'serial_past_threshold=%s' packs/

# The same suite runs in CI as the `one-decomposer self-test` job.
grep -n 'fanout-shared-decomposer' .github/workflows/ci.yml

# Convoy mapping (crit:f8594ebe6dba): the override sits on the BASE id, not a
# renamed one. Expect `id = "decompose"` and NO step whose id is
# "map-pool-to-convoy" — the stage's name lives in its title and its asset
# filename, the id belongs to the base contract.
# ANCHOR THESE. Unanchored, both patterns also match the formula's own prose
# (it explains the rule by quoting the id it does NOT use), so the negative
# assertion reports 1 and reads as a failure while the file is correct.
F=packs/switchyard-build/formulas/sy-build-from-prd.formula.toml
grep -c '^id = "decompose"' "$F"           # expect 1 (positive control)
grep -c '^id = "map-pool-to-convoy"' "$F"  # expect 0

# ...and it restates the base's target, artifact keys and check block, because
# `extends` replaces a step WHOLE (a partial override silently drops them).
for k in 'gc.run_target" = "gc.task-decomposer' \
         'gc.build.artifact_schema" = "gc.build.decomposition.v1' \
         'gc.build.decomposition_path,gc.var.decomposition_path' \
         'build-artifact-valid.sh'; do
  grep -q -- "$k" "$F" && echo "ok: $k" || echo "MISSING: $k"
done

# Skip-not-steal, and the deterministic per-bead identity, are both stated in
# the asset (expect all four).
for s in 'Never release a bead you skipped' \
         'sy-build/{{prd_id}}/<pool-bead-id>' \
         'pool_wip_limit' 'blocked'; do
  grep -q -- "$s" packs/switchyard-build/assets/workflows/sy-build-from-prd/map-pool-to-convoy.md \
    && echo "ok: $s" || echo "MISSING: $s"
done

# The WIP cap really does key on the claimed_by string, which is what makes one
# identity per bead necessary rather than stylistic.
grep -n 'claimed_by = ?' internal/db/epics.go
grep -n 'HeldPoolBeads(r.Context(), proj.ID, claimedBy)' internal/api/api_v1_beads.go

# Phase ordering needs no second read: the pool projects phase_label itself.
grep -rn 'PhaseLabel' internal/db/pool.go | head -3

# Completion summary (crit:867e5f748573): the override sits at the shadow path,
# restates the base publish contract in full, resolves its destination from the
# PRD's own blueprint_id, guards against double-posting, and refuses to claim
# delivery. 46 assertions, each scoped to the section that owns the rule.
#
# The path is part of the assertion — see the In-force claim above. The suite
# checks it first, because a prompt one directory across overrides nothing and
# fails silently.
bash scripts/completion-summary-gate.test.sh

# The same suite runs in CI as the `completion-summary-gate self-test` job.
grep -n 'completion-summary-gate' .github/workflows/ci.yml

# Publish contract (crit:c8bee483d06e): the override sits at the shadow path,
# retains every inherited base check, and binds PR-only publishing, the two-id
# title rule and fail-closed refusal inside their own sections. 22 assertions.
#
# The path is part of the assertion, not a filing preference: gc resolves the
# base formula's `../assets/workflows/publish/preflight.md` across search-path
# layers and keeps the LAST match, so the same file one directory across
# overrides nothing and fails silently. The suite checks the path first.
bash scripts/publish-preflight-gate.test.sh

# The same suite runs in CI as the `publish preflight-gate self-test` job.
grep -n 'publish-preflight-gate' .github/workflows/ci.yml

# Ledger anchors the upstream evidence chain (expect all five).
for f in GC-METH-012 '## Compatibility Claims' '## Evidence Commands' \
         ../gascity build-base; do
  grep -q -- "$f" packs/switchyard-build/REQUIREMENTS.md \
    && echo "ok: $f" || echo "MISSING: $f"
done

# Review + gap-analysis traceability: the two overrides sit at the base's own
# asset paths, and their contract holds. Also runs in CI as
# `verdict-traceability gate self-test`.
bash scripts/verdict-traceability-gate.test.sh

# Formula contract: the formula extends the base rather than forking it.
grep -n '^extends' packs/switchyard-build/formulas/sy-build-from-prd.formula.toml

# No anchor is renamed, skipped or reordered: every step id this formula
# declares is either a build-base anchor id or the added `fetch-prd` stage.
# Expect NO output — any line printed is a step id that is neither.
grep -o '^id = "[^"]*"' packs/switchyard-build/formulas/sy-build-from-prd.formula.toml \
  | sed 's/^id = "//;s/"$//' \
  | grep -vxE 'fetch-prd|requirements|plan|plan-review|decompose'

# `fetch-prd` is INSERTED between `prepare` and the `requirements` anchor.
grep -n -A2 '^id = "fetch-prd"' packs/switchyard-build/formulas/sy-build-from-prd.formula.toml

# The overridden anchors keep their base artifact schemas and the base's
# validation gate. Expect exactly 3 declared check paths — anchor the pattern
# at `path =` so a prose mention of the script in a comment is not counted.
grep -c '^path = "\.gc/scripts/checks/build-artifact-valid\.sh"' \
  packs/switchyard-build/formulas/sy-build-from-prd.formula.toml

# The declared schemas, in stage order: expect `gc.build.requirements.v1`,
# `gc.build.plan.v1`, then `gc.build.decomposition.v1`. Match the SETTING, not
# the bare schema name, for the same reason the check path above is anchored —
# the decompose stage's own comment names its schema in prose, and an
# unanchored pattern counts that comment as a fourth declaration.
grep -o '"gc\.build\.artifact_schema" = "[^"]*"' \
  packs/switchyard-build/formulas/sy-build-from-prd.formula.toml

# Every description_file the formula names exists — the same contract that
# gascity/tests/test_formula_assets.py enforces for in-tree packs.
grep -o 'description_file = "[^"]*"' packs/switchyard-build/formulas/sy-build-from-prd.formula.toml \
  | sed 's/^description_file = "//;s/"$//' \
  | while read -r p; do
      [ -f "packs/switchyard-build/formulas/$p" ] \
        && echo "ok: $p" || echo "MISSING: $p"
    done

# The approval is recorded from the app, never fabricated, and an unapproved
# PRD is refused rather than built.
grep -n 'plan_review_evidence\|prd_approved_at\|prd_approver_account_id' \
  packs/switchyard-build/assets/workflows/sy-build-from-prd/fetch-prd.md
grep -n 'Never stamp an approval time yourself' \
  packs/switchyard-build/assets/workflows/sy-build-from-prd/fetch-prd.md
grep -n 'prd-not-approved' \
  packs/switchyard-build/assets/workflows/sy-build-from-prd/fetch-prd.md

# plan-review fails closed when the approval evidence is absent.
grep -n 'plan-review-evidence-missing\|missing_approval_evidence' \
  packs/switchyard-build/assets/workflows/sy-build-from-prd/plan-review.md

# The pack is loadable and its imports resolve (requires the pin fetched).
gc import check
```

Against a gascity-packs checkout, the base side of the contract is reproduced by:

```sh
python3 -m pytest gascity/tests/test_formula_assets.py -q
python3 -m pytest gascity/tests/test_derived_pack_compatibility.py -q
```
