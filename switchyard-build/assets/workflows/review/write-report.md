Write the review verdict report to {{report_path}} with pass/fail, findings,
missing evidence, and recommended fixes for subject {{subject_path}}.

The requested review authority is `{{review_mode}}`: in `report` mode, write
findings and verdicts without mutating code; in `agent` mode, also include a
structured fix handoff for the caller's review-fix formula to apply; in
`interactive` mode, safe fixes may be negotiated or applied with every change
and reason recorded in the report. The interaction posture is
`{{interaction_mode}}`.

## Per-criterion traceability

This run builds a switchyard PRD, so "the requirements" are that PRD's
acceptance criteria and nothing else. Every criterion gets one row, in one
table, under `## Verification`:

| id | status | traceability | delivering PR | evidence |
| --- | --- | --- | --- | --- |
| `crit:<hash>` | covered | met | `#<number>` <url> | test, file, or command that shows it |

- **`id` is the `crit:<hash>` label, verbatim.** Never the criterion's prose and
  never a reworded summary of it: the label is a hash OF that text, so a row
  keyed on anything else names a criterion that does not exist and orphans the
  record the PRD reads back.
- **`status` stays in the base coverage vocabulary** — `covered`,
  `not_applicable`, `deferred`, `blocked`, `out_of_scope`, `superseded`. Any
  status other than `covered` also needs its `rationale` in `trace.coverage`.
- **`traceability` is `met`, `partially_met`, or `missing`** — switchyard's own
  verdict on the criterion, carried alongside the base status rather than
  squeezed into it.

## A met row names the PR that delivered it

`met` requires BOTH `status: covered` AND a delivering PR named in the row by
number and URL. A criterion you believe is satisfied but cannot attribute to a
PR is `partially_met` at best — never `met`. This is the whole point of the
column: a merged, PRD-attached PR is the only delivery signal switchyard
accepts, so a `met` with no PR behind it is the exact claim this report exists
to stop.

Two rules keep the table honest when the run is partial:

- **Every criterion appears exactly once, including the ones you did not
  reach.** A criterion you never got to is `missing`. Omitting it is the failure
  this table is built to catch — a short table reads as full coverage.
- **A criterion outside this run's convoy is `out_of_scope`**, with the
  rationale naming the run or phase that owns it. It is not `missing`, and it is
  not absent.

Use `verdict: fail` when any criterion this run claimed is
`missing` or `partially_met`, and when any required behavior, migration note,
or test evidence is absent.

**This table IS the coverage matrix.** `build-artifact-valid.sh` parses the body
for the `id`/`status` pair and requires it to match `trace.coverage` exactly. It
merges EVERY table in the body whose header carries both of those column names,
then compares the union — so a second such table does not add detail, it
silently corrupts the match and fails the stage with an error that points at the
YAML rather than at the extra table. Keep one.

## Artifact validation

This step is gated by `.gc/scripts/checks/build-artifact-valid.sh`, which
validates the report recorded at `gc.build.review_report_path` (fallback
`gc.var.report_path`) against schema `gc.build.review.v1`. Keep the required
body sections present and in order — `## Verdict`, `## Findings`, then
`## Verification`. On repair attempts (`gc.attempt` greater than 1), read the
validator errors from `gc.attempt_log` on the validation loop control bead (the
dependent of this step bead) and repair the report in place instead of rewriting
it. Two bounded repair attempts follow the first failure; exhausting them closes
this stage with `gc.outcome=fail` and machine-readable validation errors that
block downstream stages. Never ask questions in headless mode; record unresolved
ambiguity inside the report.
