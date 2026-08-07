This is the `sy-build-from-prd` fetch-prd stage. It is switchyard's source stage:
it renders the base workflow's requirements and plan artifacts from an APPROVED
switchyard PRD instead of authoring them, and it carries the app-side approval
forward as the plan-review evidence.

Build the PRD for `prd_id = {{prd_id}}`.

## Read the PRD

Read it over the switchyard MCP with `get_prd` (its `prd_id` argument is global,
so no `set_scope` is required). Do not read PRD content out of repository files,
a cached export, or a previous run's artifacts — the app is the system of record
and the run must reflect the PRD as it stands now.

Record the exact version you rendered from. `get_prd` returns the approved
content under `latest`, and `latest.version` is the version number.

## Refuse to build an unapproved PRD

Read `prd.status` and `prd.approved_at`. Continue only when the PRD has actually
been approved in the app — `approved_at` is set and `prd.status` is `approved`
or `executing`. A `draft`, `parked`, `blocked`, or `archived` PRD is not a
factory input.

If it is not approved, do not render anything and do not guess at intent. Record
`gc.build.status=blocked` and a machine-readable
`gc.blocked_reason` (for example `prd-not-approved:draft`) on the workflow root,
then close this step with `gc.outcome=fail` and
`gc.failure_class=input_not_approved`.

## Render, never invent

Every sentence in both artifacts must be traceable to a PRD section. This is a
stated stop condition on PRD #269: if the base pack's artifact contract cannot
be satisfied from the PRD's sections without inventing content, stop the run as
blocked rather than filling the gap yourself. Record
`gc.build.status=blocked` with
`gc.blocked_reason=prd-section-missing:<section>` and close with
`gc.outcome=fail` and `gc.failure_class=insufficient_prd_content`.

Reproduce the PRD's own wording for acceptance criteria verbatim. A criterion's
`crit_label` is its identity and downstream stages key on it, so never
paraphrase, renumber, merge, or split a criterion.

Both artifacts are Markdown with YAML front matter, written to the paths the
inherited `prepare` stage recorded on the workflow root
(`gc.build.requirements_path` and `gc.build.plan_path`, conventionally
`requirements.md` and `implementation-plan.md` under
`plans/prd-<prd_id>/build`). Write to those recorded paths rather than inventing
new locations.

### requirements.md

Render from the PRD's own sections, and say which section each part came from:

- **Requested outcome** — `latest.summary`, `latest.goals`, and
  `latest.contract.done_means`.
- **Constraints** — `latest.contract.fair_game` (what this work may touch),
  `latest.contract.hands_off` (what it must not), and
  `latest.contract.stop_conditions`.
- **Non-goals** — `latest.out_of_scope`.
- **Acceptance criteria** — `latest.acceptance_criteria`, verbatim, each paired
  with its `crit_label` from `annotations`, and with the criterion's
  `verify_command` when it has one.
- **Unresolved questions** — every entry in `questions` whose `status` is not
  `answered`. An open question is a real constraint on this run; list it rather
  than resolving it. Never ask a question in headless interaction mode — record
  it in the artifact instead.

### implementation-plan.md

Render from the PRD's phases and criteria:

- **Affected areas** — `latest.contract.fair_game`, with
  `latest.contract.hands_off` stated as the boundary.
- **Sequencing** — the `phases` array in `sort_order`, each with its `label`
  (`P0`, `P1`, ...), `title`, `description`, and `contract.done_means`, and the
  criteria that belong to that phase. Phase order is the delivery order.
- **Risks** — `latest.risks`.
- **Test strategy** — the per-criterion `verify_command` values; name any
  criterion that has no contract, since that is a gap a later stage must close
  rather than a criterion to skip.
- **Handoff criteria** — each phase's `contract.done_means`, and the PRD-level
  `latest.contract.done_means` as the run's overall exit condition.

## Record the app-side approval as the plan-review evidence

The PRD was reviewed and approved by a human in the app. That approval is this
run's plan-review evidence, and the `plan-review` stage closes on it instead of
running another design review. Record it on the workflow root so that stage — and
any later audit — can read it without re-querying:

```sh
gc bd update "<workflow-root-id>" \
  --set-metadata "gc.build.prd_id=<prd_id>" \
  --set-metadata "gc.build.prd_version=<latest.version>" \
  --set-metadata "gc.build.prd_approved_at=<prd.approved_at>" \
  --set-metadata "gc.build.prd_approver_account_id=<prd.approver_account_id>" \
  --set-metadata "gc.build.plan_review_evidence=switchyard-prd-approval"
```

Take `approved_at` and `approver_account_id` from the `get_prd` response as they
are returned. Never stamp an approval time yourself: a fabricated approval is a
delivery record for a review that never happened.

## Close

Record both rendered artifact paths on the workflow root before closing:

```sh
gc bd update "<workflow-root-id>" \
  --set-metadata "gc.build.requirements_path=<absolute path>" \
  --set-metadata "gc.build.plan_path=<absolute path>"
```

Do not use `gc bd update --metadata 'key=value'`; `--metadata` only accepts a
JSON object. Store plain scalar strings without embedded quote characters.

Before closing this step, set the claimed step outcome with
`gc bd update "<claimed-step-id>" --set-metadata "gc.outcome=pass"`, then close
with `gc bd close "<claimed-step-id>" --reason "<concise reason>"`. Do not pass
`--metadata` or `--set-metadata` to `gc bd close`, and do not use
`gc.outcome=success`; successful workflow stages use `gc.outcome=pass`.

Do not edit source files in this stage. Close it only after both artifacts exist
at their recorded paths and the approval evidence is on the workflow root.
