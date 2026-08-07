This is the `sy-build-from-prd` plan-review stage. It is the `build-base`
plan-review anchor, overridden under its own id: the plan this run executes is an
approved switchyard PRD, so the review that gates it has already happened, in the
app, by a human. This stage RECORDS that approval as the stage's evidence instead
of running a second design review.

That is the whole point of the override. Re-reviewing an approved PRD here would
either rubber-stamp it — a review with no authority to change anything, since the
plan came from an approved spec — or reach a verdict that contradicts a decision
the team already made and cannot act on it.

## Read the evidence

The `fetch-prd` stage recorded the approval on the workflow root:

- `gc.build.prd_id`
- `gc.build.prd_version`
- `gc.build.prd_approved_at`
- `gc.build.prd_approver_account_id`
- `gc.build.plan_review_evidence=switchyard-prd-approval`

Read those keys from the workflow root bead. State them in this step's summary,
so the run's own trace says which PRD version was approved, by which account, and
when — the same facts a later gap-analysis or audit needs.

## Fail closed on missing evidence

If `gc.build.plan_review_evidence` is absent, or the approval time or approver is
missing, this stage has nothing to stand on. Do not substitute your own review
and do not close it as passed: an unreviewed plan closing a review stage is
exactly the fabricated approval this override exists to avoid. Record
`gc.build.status=blocked` and
`gc.blocked_reason=plan-review-evidence-missing` on the workflow root, then close
this step with `gc.outcome=fail` and
`gc.failure_class=missing_approval_evidence`.

Do not re-derive the evidence by calling `get_prd` yourself here. If it is
missing from the workflow root, `fetch-prd` did not do its job, and the run
should stop so that is visible rather than papered over.

## Close

Confirm only that the artifacts this run will execute are the ones the recorded
approval covers: the plan at `gc.build.plan_path` was rendered from
`gc.build.prd_id` at `gc.build.prd_version`. A mismatch between the recorded PRD
version and the version the artifacts were rendered from is a blocking finding,
not a note — record it as above with
`gc.blocked_reason=plan-review-version-mismatch`.

Before closing this step, set the claimed step outcome with
`gc bd update "<claimed-step-id>" --set-metadata "gc.outcome=pass"`, then close
with `gc bd close "<claimed-step-id>" --reason "<concise reason>"`. Do not pass
`--metadata` or `--set-metadata` to `gc bd close`, and do not use
`gc.outcome=success`; successful workflow stages use `gc.outcome=pass`.
