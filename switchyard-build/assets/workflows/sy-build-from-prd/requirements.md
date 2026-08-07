This is the `sy-build-from-prd` requirements stage. It is the `build-base`
requirements anchor, overridden under its own id: the artifact is already
written, so this stage CONFIRMS it rather than authoring it.

The `fetch-prd` stage rendered the requirements artifact from switchyard PRD
`{{prd_id}}`'s own sections and recorded its path on the workflow root at
`gc.build.requirements_path`. Read the artifact at that recorded path.

Do not re-author it, and do not "improve" it. The PRD is the approved source of
truth for what this run must deliver, and rewriting its requirements in this
stage silently substitutes your judgement for an approved decision. Confirm that:

- every acceptance criterion in the PRD appears in the artifact verbatim, with
  its `crit_label` intact and its `verify_command` where it has one;
- the requested outcome, constraints, and non-goals are present and each is
  attributable to a PRD section;
- unresolved questions are listed rather than answered.

If something is missing or has drifted from the PRD, repair the artifact in
place from the PRD — re-read it with `get_prd` — rather than writing new content
of your own. If the gap cannot be closed from the PRD's sections without
inventing content, stop the run as blocked: record `gc.build.status=blocked` and
`gc.blocked_reason=prd-section-missing:<section>` on the workflow root, then
close this step with `gc.outcome=fail` and
`gc.failure_class=insufficient_prd_content`.

Artifact validation: this stage is gated by
`.gc/scripts/checks/build-artifact-valid.sh`, which validates the artifact
recorded at `gc.build.requirements_path` (fallback `gc.var.requirements_path`)
against schema `gc.build.requirements.v1`. On repair attempts (`gc.attempt`
greater than 1), read the validator errors from `gc.attempt_log` on the
validation loop control bead (the dependent of this step bead) and repair the
artifact in place instead of rewriting it. Two bounded repair attempts follow the
first failure; exhausting them closes this stage with `gc.outcome=fail` and
machine-readable validation errors that block downstream stages. Never ask
questions in headless mode; record unresolved ambiguity inside the artifact.

The path is already recorded on the workflow root, so this stage does not need to
record it again. If you repaired the artifact at a different path, update
`gc.build.requirements_path` with
`gc bd update "<workflow-root-id>" --set-metadata "gc.build.requirements_path=<absolute path>"`.
Do not use `gc bd update --metadata 'key=value'`; `--metadata` only accepts a
JSON object.

Before closing this step, set the claimed step outcome with
`gc bd update "<claimed-step-id>" --set-metadata "gc.outcome=pass"`, then close
with `gc bd close "<claimed-step-id>" --reason "<concise reason>"`. Do not pass
`--metadata` or `--set-metadata` to `gc bd close`.
