Write the gap-analysis verdict report to {{report_path}} with pass/fail,
findings, missing evidence, and recommended fixes for subject {{subject_path}}.

The report is a `gc.verdict-report.v1` document: front matter carries `schema`,
`kind: gap-analysis`, `verdict` (`pass` or `fail`) and `severity`, and every
finding carries `id`, `severity`, `title`, `evidence` and `required_fix`. A
`pass` takes `severity: none`; a `fail` takes a real severity and at least one
finding.

## Per-criterion traceability

The subject is a switchyard PRD's delivery, so the requirements you compare
against are that PRD's acceptance criteria and nothing else. Every criterion
gets one row, in one table:

| id | status | traceability | delivering PR | evidence |
| --- | --- | --- | --- | --- |
| `crit:<hash>` | covered | met | `#<number>` <url> | test, file, or command that shows it |

- **`id` is the `crit:<hash>` label, verbatim.** Never the criterion's prose and
  never a reworded summary of it: the label is a hash OF that text, so a row
  keyed on anything else names a criterion that does not exist and orphans the
  record the PRD reads back.
- **`status` stays in the base coverage vocabulary** — `covered`,
  `not_applicable`, `deferred`, `blocked`, `out_of_scope`, `superseded`. Any
  status other than `covered` also needs a rationale saying why.
- **`traceability` is `met`, `partially_met`, or `missing`** — the gap verdict
  on that criterion, carried alongside the base status rather than squeezed
  into it.

## A met row names the PR that delivered it

`met` requires BOTH `status: covered` AND a delivering PR named in the row by
number and URL. A criterion you believe is satisfied but cannot attribute to a
PR is `partially_met` at best — never `met`. This is the whole point of the
column: a merged, PRD-attached PR is the only delivery signal switchyard
accepts, so a `met` with no PR behind it is the exact claim this report exists
to stop.

Two rules keep the table honest when the run is partial:

- **Every criterion appears exactly once, including the ones you did not
  reach.** A criterion nothing in this run touched is `missing`. Omitting it is
  the failure this table is built to catch — a short table reads as full
  coverage.
- **A criterion outside this run's convoy is `out_of_scope`**, with the
  rationale naming the run or phase that owns it. It is not `missing`, and it is
  not absent.

Treat an untested criterion as a gap unless the implementation summary explains
a legitimate manual verification, and say which. Use `verdict: fail` when any
criterion this run claimed is `missing` or `partially_met`, and when any
required behavior, migration note, or test evidence is absent.

Every `missing` and `partially_met` row needs a matching finding, so the report
carries the fix as well as the gap: the finding's `id` cites the `crit:<hash>`,
and its `required_fix` says what would move the row to `met`.
A gap with no finding is a gap nobody is going to act on.
