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
| Status | Skeleton — manifest + ledger only |
| Scope | switchyard's factory execution path for epic-scale approved PRDs |
| Base contract | `gascity/REQUIREMENTS.md` (`gc.build-methodology-base.requirements.v1`) |
| Base formula | `build-base` |
| Upstream anchor | `GC-METH-012` |
| Pinned base | `gascity-packs` `sha:637398502880f1a2a96a385f0d1b38b85343fa4e` |

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
   from the gascity-packs checkout. The claims below are therefore verified by
   the Evidence Commands in this ledger, not by that suite.
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

### Pending

Each row lands with the switchyard PRD #269 acceptance criterion named beside
it. Until then the claim is not made.

| Claim | Lands with |
| --- | --- |
| **Formula contract** — `sy-build-from-prd` declares `extends = ["build-base"]` and preserves the inherited anchor order, overriding steps under their base ids without renaming, skipping, or reordering an anchor | the `sy-build-from-prd` step criteria below, collectively |
| **Requirements/plan artifacts** — the `fetch-prd` step renders `requirements.md` and `implementation-plan.md` from an approved PRD's own sections and records the app-side approval as plan-review evidence | `crit:3ee33868b070` |
| **Convoy mapping** — `map-pool-to-convoy` claims the target PRD's pool beads under lease and mints a local convoy ordered by phase, skipping and reporting any bead already claimed elsewhere | `crit:f8594ebe6dba` |
| **Publish contract** — the publish preflight override enforces PR-only publishing with the PRD and bead ids in the PR title | `crit:c8bee483d06e` |
| **Per-item implement override** — lease heartbeat, release-on-abandon, and the switchyard quality gates including `templ generate` | `crit:4ea0ccf29b82` |
| **Review and gap analysis** — verdict reports with per-criterion met/partial/missing traceability linked to delivering PRs | `crit:c20b14ed613e` |
| **Completion summary** — the factory run posts a summary message to the source PRD's discussion | `crit:867e5f748573` |
| **End-to-end evidence** — an interactive factory run on a small approved PRD lands reviewed PRs and completes its beads with PRs attached | `crit:707a711e70df` |

## Evidence Commands

Run these from the switchyard repository root.

```sh
# Import contract: the pack binds the base as `gc`, pinned.
sed -n '/^\[pack\]/,$p' packs/switchyard-build/pack.toml

# The binding name is exactly `gc` (expect one match).
grep -c '^\[imports\.gc\]' packs/switchyard-build/pack.toml

# The pin is a real gascity-packs commit, and it carries the base pack.
# NOTE: do not "simplify" this to `git ls-remote | grep <sha>`. ls-remote lists
# REF TIPS only, so a pinned commit that is not a branch or tag head is absent
# from its output — that check reports a false negative on a perfectly good pin.
PIN=637398502880f1a2a96a385f0d1b38b85343fa4e
gh api "repos/gastownhall/gascity-packs/commits/$PIN" --jq .sha
gh api "repos/gastownhall/gascity-packs/contents/gascity/pack.toml?ref=$PIN" --jq .path

# Mirror parity: the pre-publish guard names this pack.
grep -n 'for pack in' .github/workflows/mirror-packs.yml

# Ledger anchors the upstream evidence chain (expect all five).
for f in GC-METH-012 '## Compatibility Claims' '## Evidence Commands' \
         ../gascity build-base; do
  grep -q -- "$f" packs/switchyard-build/REQUIREMENTS.md \
    && echo "ok: $f" || echo "MISSING: $f"
done

# The pack is loadable and its imports resolve (requires the pin fetched).
gc import check
```

Against a gascity-packs checkout, the base side of the contract is reproduced by:

```sh
python3 -m pytest gascity/tests/test_formula_assets.py -q
python3 -m pytest gascity/tests/test_derived_pack_compatibility.py -q
```
