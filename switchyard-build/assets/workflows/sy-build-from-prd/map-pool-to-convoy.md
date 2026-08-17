Map switchyard PRD {{prd_id}}'s claim-pool beads onto a phase-ordered local
convoy, and record what you could not take.

This stage stands where `build-base`'s `decompose` stands, and it satisfies the
same artifact contract — a `gc.build.decomposition.v1` artifact at the recorded
decomposition path, gated by `build-artifact-valid.sh`. What differs is where
the work items come from.

**Do not invent work items.** switchyard already holds one pool bead per
acceptance criterion of this PRD, and switchyard — not the local bead ledger —
is the system of record for PRD progress and per-PRD spend. Creating task beads
from the plan here would fork the work: the factory would build items nobody is
tracking while the real pool beads sat claimable for another lane to take.

**Never take a bead another lane holds.** The claim-pool lease is the ONLY mutex
between switchyard's execution lanes. Stealing or force-releasing a live claim
is not a recoverable mistake — it puts two workers on one criterion, and the
loser's work is discovered only at merge. A bead you cannot claim is SKIPPED and
REPORTED. If delivering this PRD would require taking a held claim, stop the run
and hand back rather than taking it.

The claims, the reads, and the releases in this stage all go through the
**switchyard MCP** from inside this session. The `switchyard-api.sh` order
library is read-only by design and fails open; it is for deciding whether to
start a session, never for a claim.

---

**1. Read the pool ONCE. It is the phase-ordering source.**

`list_claimable_beads` projects `prd_id`, `crit_label`, and `phase_label` onto
every row (switchyard PRD 269 P0, crit:f74755f880ea), specifically so this stage
can order a convoy by phase **without a second read**. Take the rows whose
`prd_id` is {{prd_id}}.

- `phase_label` is ALWAYS present; `""` means the bead carries no phase.
- Read `total` against `count`, and `truncated`. A bounded page that silently
  dropped this PRD's tail would mint a convoy missing real work — pass a `limit`
  large enough, or page until you have every row for this PRD.
- The listing carries only OPEN, UNCLAIMED beads. A bead another lane already
  holds is **absent from it entirely** rather than present-and-refusing, which
  is why step 2 exists.

**2. Read the criteria for the denominator and the holders — never for phase.**

`list_criteria(prd_id={{prd_id}})` returns every criterion of the PRD with its
LIVE claim state (`claimed_by`, `lane`, `lease_expires_at`, present only while
something actually holds it). This read is what makes "report what you skipped"
possible: it is the only surface that can distinguish

- a criterion **held by another lane** (a live `claimed_by` — report it,
  never take it),
- a criterion **already delivered** (`status: done`, or a closed satisfying
  bead — not this run's work), and
- a criterion **missing from the pool for some other reason** (no claim, not
  done, yet absent from step 1's listing — report it as unexplained rather
  than pretending it does not exist).

Use it for the report only. Ordering comes from step 1's `phase_label`, per
q178/q189; re-deriving phase here would reintroduce exactly the second read
that projection was added to remove.

**3. Claim each bead under a DISTINCT identity.**

The pool's WIP cap (`projects.pool_wip_limit`, default **1**) keys on the
`claimed_by` STRING, not on the account or the token:
`HeldPoolBeads(project_id, claimed_by)` counts what that one identity holds. A
factory run therefore holds a whole PRD's beads legitimately — but only if each
claim carries its own identity. Reuse one identity across the loop and the
SECOND claim is refused, with a refusal that looks nothing like a busy bead.

Derive the identity deterministically from the run and the bead:

    sy-build/{{prd_id}}/<pool-bead-id>

Deterministic matters on a retry. This stage has `max_attempts = 3`; if attempt
1 claimed four beads and then failed, attempt 2 re-derives the SAME identity and
can recognise its own claims instead of reporting them as somebody else's — see
step 4. A random or timestamped identity would strand attempt 1's claims for the
lease's full hour and report every one of them as "claimed elsewhere", minting
an empty convoy from a PRD whose work this very run is holding.

Claim with the switchyard MCP `claim` tool — the single entry point for every
claimable domain, selected by `kind`:

    claim { kind: "bead", bead_id: "<pool-bead-id>",
            claimed_by: "sy-build/{{prd_id}}/<pool-bead-id>",
            lease_seconds: {{pool_lease_seconds}} }

The lease is taken at the server's 1-hour cap and **heartbeated** rather than
extended (settled by q179). A longer value is clamped, not honoured. This stage
does not heartbeat: the per-item implement override owns the lease from here,
which is why step 5 records the identity on the mirror bead.

**4. Classify a refusal before you skip on it. Three different 409s reach here.**

They mean different things and only ONE of them is a skip. Read the response
body; do not branch on the status code alone.

| Refusal | How to recognise it | What it means | Do |
| --- | --- | --- | --- |
| Held by another lane | `bead <id> is not claimable: status=<s>, held_by="<who>"` | Another lane owns it, or the pool listing went stale between step 1 and now | **SKIP and report.** Never release it |
| Already yours | same shape, but `held_by` equals the identity you derived in step 3 | A previous attempt of THIS stage claimed it | **Treat as claimed.** Put it in the convoy |
| WIP cap | body carries `wip_limit` and `held_bead`; message begins `WIP limit reached:` | This identity already holds its limit — the per-bead identity scheme was not followed | **Stop.** Fix the identity; do not skip the bead |
| PRD admission | message names a blocking PRD and offers `activate_prd`; mentions `prd_wip_limit` | Project-level admission control is holding this PRD's work back | **Stop and report.** Not a per-bead condition |

The pool listing going stale between the read and the claim is ordinary, not an
error: another lane can take a bead in that window. Skip it and carry on.

A skip is only ever recorded, never resolved. Do not call `release` on a bead
you do not hold, and do not wait out another lane's lease.

**5. Mirror each claimed bead locally, carrying the pool identity forward.**

The convoy is a graph of LOCAL beads, so create one per successfully claimed
pool bead with `gc bd create ...` and capture the returned ids. Each mirror bead
must carry the pool linkage as metadata — this is the interface the per-item
implement override (crit:4ea0ccf29b82) uses to heartbeat the lease, release on
abandon, and complete the bead back with its PR:

    gc bd update "<mirror-bead-id>" \
      --set-metadata "sy.pool.bead_id=<pool-bead-id>" \
      --set-metadata "sy.pool.claimed_by=sy-build/{{prd_id}}/<pool-bead-id>" \
      --set-metadata "sy.pool.prd_id={{prd_id}}" \
      --set-metadata "sy.pool.crit_label=<crit:...>" \
      --set-metadata "sy.pool.phase_label=<P0|P1|...|>" \
      --set-metadata "sy.pool.lease_expires_at=<RFC3339 from the claim response>"

`sy.pool.claimed_by` is the load-bearing one. Every later lease action —
heartbeat, release, complete — is accepted only for the identity that took the
claim, so a mirror bead without it is a bead whose lease nobody can renew.

Give the mirror bead the pool bead's title and its criterion text, and record
the requirements artifact as its spec. A bead's description is NOT carried into
a formula's rendered context; a worker handed only a title builds from the title
alone and every switchyard surface still reads the criterion as delivered.

**6. Mint the convoy in phase order.**

Order the mirror beads **P0, then P1, then P2, …, with unphased (`""`) beads
last**, preserving step 1's order within a phase — the pool returns oldest-claim
-first inside a priority tier, and that is a sensible tiebreak.

Follow the base's convoy-creation flow exactly:

1. Create every work item first (step 5) and capture the ids.
2. Create and link the convoy in ONE command, ids in phase order:
   `gc convoy create "prd-{{prd_id}}-build" <mirror-id...> --json`
3. Parse the convoy id from that JSON, then verify with `gc convoy list --json`.

Do not call `gc convoy add` for freshly created beads — they may not be visible
to that path yet. Do not run `gc bd show <convoy-id>`; a convoy id is not a bd
issue id. Do not reuse the launch convoy from `gc.var.convoy_id`.

**Do not create an empty convoy.** If every bead was skipped, there is nothing
to drain: write the artifact with `status: blocked`, record the skip report, and
fail this stage with a reason naming the lanes that hold the work. An empty
convoy would drain cleanly, review cleanly, and finalize as a successful build
of nothing.

**7. Write the decomposition artifact — the skip report rides its coverage table.**

Create the artifact at the path on the workflow root bead
(`gc.build.decomposition_path`, fallback `gc.var.decomposition_path`): Markdown
with YAML front matter, schema `gc.build.decomposition.v1`, mapping objects
only — no scalar shortcuts like `workflow: sy-build-from-prd`.

    schema: gc.build.decomposition.v1
    workflow: {id: <workflow-root-id>, formula: sy-build-from-prd}
    methodology: {pack: switchyard-build, name: sy-build-from-prd}
    producer: {formula: sy-build-from-prd, stage: decompose, attempt: <n>}
    status: approved        # or `blocked` when nothing could be claimed
    trace: {upstream: [...], coverage: [...]}

`trace.upstream[]` entries take `path` and `hash` (scheme-qualified, e.g.
`sha256:<digest>` or `git:<rev>`) — the requirements and plan artifacts by their
recorded paths. Do not use `id`/`title`/`type` entries there.

Put every criterion of this PRD in `trace.coverage` and in a Markdown coverage
table whose ID/Status pairs match it exactly. The validator only recognises a
table with an `ID` column and a `Status` column. Use the criterion's
`crit_label` as the ID, and these statuses — they are the schema's own, so the
report cannot be silently dropped or invented:

| ID | Status |
| --- | --- |
| crit:0123456789ab | covered |
| crit:cdef01234567 | blocked |

- `covered` — claimed by this run and in the convoy.
- `blocked` — held by another lane, or absent from the pool with no explanation.
  This is the skip report. Name the holder and the lease expiry in the Work
  Items section beneath it.
- `deferred` — deliberately excluded from this run.
- `not_applicable` / `out_of_scope` / `superseded` — already delivered, or no
  longer this PRD's work.

Coverage statuses are not artifact statuses: never write `approved` in a
coverage row.

Include the schema's required sections — **Summary**, **Selected Downstream
Formulas**, **Implementation Convoy**, **Work Items** — and under Work Items,
list the skipped beads with their holder and lease expiry, so a human reading
the artifact can tell a lane collision from a delivered criterion without
re-querying.

**8. Record the convoy on the workflow root, then close.**

    gc bd update "<workflow-root-id>" \
      --set-metadata "gc.build.decomposition_path=<absolute path>"

    gc bd update "<workflow-root-id>" \
      --set-metadata "gc.input_convoy_id=<convoy-id>" \
      --set-metadata "gc.build.implementation_convoy_id=<convoy-id>"

`--metadata` takes a JSON object and is not interchangeable with
`--set-metadata`. Verify both convoy fields are present on the workflow root and
point at the new convoy before closing — the `implement` stage drains
`gc.input_convoy_id`, so a missing value drains nothing and reports success.

Then set the outcome and close:

    gc bd update "<claimed-step-id>" --set-metadata "gc.outcome=pass"
    gc bd close "<claimed-step-id>" --reason "<concise reason>"

Do not pass `--metadata` or `--set-metadata` to `gc bd close`.

**9. If you abandon this stage, release what YOU claimed — and only that.**

Claims taken here outlive a failed stage: the lease runs an hour, and until it
expires no other lane can take that criterion. Before failing out, release every
bead this stage claimed, each under the identity that took it, with a handoff
saying the factory run abandoned the mapping:

    claim_action { kind: "bead", action: "release",
                   bead_id: "<pool-bead-id>",
                   claimed_by: "sy-build/{{prd_id}}/<pool-bead-id>",
                   handoff: { next_best_step: "...", broken_or_unverified: "..." } }

Never release a bead you skipped. A release you were not entitled to make is
indistinguishable, from the pool's side, from stealing the claim.

Artifact validation: this stage is gated by
`.gc/scripts/checks/build-artifact-valid.sh` against schema
`gc.build.decomposition.v1`. On a repair attempt (`gc.attempt` greater than 1),
read the validator errors from `gc.attempt_log` on the validation loop control
bead and repair the artifact in place rather than rewriting it — and re-read
step 4's "Already yours" row before re-claiming, because your earlier attempt's
claims are still live. Never ask questions in headless mode; record unresolved
ambiguity inside the artifact.
