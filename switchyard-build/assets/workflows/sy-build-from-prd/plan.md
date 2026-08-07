This is the `sy-build-from-prd` plan stage. It is the `build-base` plan anchor,
overridden under its own id: the implementation plan is already written, so this
stage CONFIRMS it rather than authoring it.

The `fetch-prd` stage rendered the plan artifact from switchyard PRD
`{{prd_id}}`'s phases and criteria and recorded its path on the workflow root at
`gc.build.plan_path`. Read the artifact at that recorded path.

Do not re-plan the work. A switchyard PRD's phases are an approved delivery
order, and re-sequencing them here would put this run out of step with the
criteria the app will judge it against. Confirm that:

- the phases appear in the PRD's `sort_order`, each with its label, title and
  `done_means`, and the criteria belonging to each phase;
- affected areas and their boundary come from the PRD's `fair_game` and
  `hands_off`;
- the test strategy names each criterion's `verify_command`, and explicitly names
  any criterion that has none, since a contract-less criterion is a gap a later
  stage must close rather than a criterion to skip;
- risks and handoff criteria are present and attributable to PRD sections.

If something is missing or has drifted, repair the artifact in place from the PRD
— re-read it with `get_prd` — rather than writing a plan of your own. If the gap
cannot be closed from the PRD's sections without inventing content, stop the run
as blocked: record `gc.build.status=blocked` and
`gc.blocked_reason=prd-section-missing:<section>` on the workflow root, then close
this step with `gc.outcome=fail` and
`gc.failure_class=insufficient_prd_content`.

Artifact validation: this stage is gated by
`.gc/scripts/checks/build-artifact-valid.sh`, which validates the artifact
recorded at `gc.build.plan_path` (fallback `gc.var.plan_path`) against schema
`gc.build.plan.v1`. On repair attempts (`gc.attempt` greater than 1), read the
validator errors from `gc.attempt_log` on the validation loop control bead (the
dependent of this step bead) and repair the artifact in place instead of
rewriting it. Two bounded repair attempts follow the first failure; exhausting
them closes this stage with `gc.outcome=fail` and machine-readable validation
errors that block downstream stages. Never ask questions in headless mode; record
unresolved ambiguity inside the artifact.

The path is already recorded on the workflow root, so this stage does not need to
record it again. If you repaired the artifact at a different path, update
`gc.build.plan_path` with
`gc bd update "<workflow-root-id>" --set-metadata "gc.build.plan_path=<absolute path>"`.
Do not use `gc bd update --metadata 'key=value'`; `--metadata` only accepts a
JSON object.

Before closing this step, set the claimed step outcome with
`gc bd update "<claimed-step-id>" --set-metadata "gc.outcome=pass"`, then close
with `gc bd close "<claimed-step-id>" --reason "<concise reason>"`. Do not pass
`--metadata` or `--set-metadata` to `gc bd close`.
