This is the `build-base` publish stage. switchyard-build overrides it through
the asset path-shadow seam so a factory run ends by telling the PRD's own
readers what happened, in the place they are already watching.

The stage keeps every inherited responsibility. What it adds is one final act:
after the publish outcome is recorded, post a completion summary to the source
PRD's discussion.

Publish is the run's LAST anchor (`needs = ["finalize"]`, no condition), so it
is the only stage that can describe the whole run — the artifacts exist, the
review has run, the final report is written, and the PRs are open by the time
this stage closes. A summary posted anywhere earlier would have to guess at all
of that.

## The inherited publish contract

This section is the base's own contract, restated. A shadow REPLACES the base
file rather than merging with it, so anything dropped here is simply gone from
the running agent's instructions.

If `push` or `open_pr` is enabled, publish the finalized build result according
to the workflow metadata. If publishing is disabled, record the exact reason and
leave the artifacts ready for a later publisher.

Write a publish result artifact under the workflow artifact root when one is
available. Record the same publish outcome on the workflow root bead and this
publish step before closing.

Required workflow root metadata:

- `gc.build.publish_status=published|noop|failed`
- `gc.build.publish_action=push|pr|push_pr|noop|failed`
- `gc.build.publish_recorded_at=<UTC timestamp>`
- `gc.build.publish_artifact_path=<publish result artifact path>`
- `gc.build.publish_reason=<short machine-readable reason>`

For disabled publishing, use `gc.build.publish_status=noop`,
`gc.build.publish_action=noop`, and a reason such as
`push=false_open_pr=false`. Also record whether remotes were present with
`gc.build.publish_remote_status`.

Record the publish action or explicit no-op on both the workflow root and the
publish step before moving on to the summary below.

## Rule 1 — resolve the source PRD, or record an explicit no-op

Read `gc.build.prd_id` from the workflow root. The `fetch-prd` stage recorded it
there at the start of a switchyard factory run.

Take the id from that metadata key, never from a template placeholder. This file
sits at the BASE pack's asset path, so it is inherited by every formula that
extends `build-base` — not only `sy-build-from-prd`. A `prd_id` var exists in
some of those variable contexts and not others, and an undefined name renders
its own raw body rather than failing, so a placeholder here would ship literal
braces into a running agent's instructions.

A run with no `gc.build.prd_id` is therefore not a defect. It is a build that
did not come from a switchyard PRD, and it has no discussion to post to. Do not
guess a PRD id, do not search for a plausible one, and do not fail the stage.
Record the skip and close normally:

```sh
gc bd update "<workflow-root-id>" \
  --set-metadata "gc.build.completion_summary_status=skipped" \
  --set-metadata "gc.build.completion_summary_reason=no-source-prd"
```

A guessed id posts another PRD's readers a summary of work that was never done
for them.

## Rule 2 — post the completion summary to the source PRD's discussion

Read the PRD over the switchyard MCP with `get_prd` (its `prd_id` argument is
global, so no `set_scope` is required). The response carries `blueprint_id`: the
thread the PRD was drafted from, which the PRD page renders as its **Discussion**
section. That id is the destination — resolve it from the PRD rather than
reusing a thread id from an earlier stage or from the launch inputs.

Post with `post_blueprint_message`, passing `blueprint_id` and a markdown `body`.
Pass `agent_ref` as well, so the summary is attributed to the registered factory
agent rather than to the human account behind the API token; call
`register_agent` first if this session has not registered. A run's summary
signed by a person who was not watching the run misattributes the work.

The body reports the run. Include:

- The PRD and the version this run built, from `gc.build.prd_id` and
  `gc.build.prd_version`.
- The run's outcome, from `gc.build.final_report_path` and the publish status
  recorded above — including a failed or partial run. A run that went badly is
  the one whose summary is most worth reading.
- Every pull request the run opened, by URL.
- Each pool bead the run worked, with the criterion `crit_label` it belongs to
  and what became of it.
- Anything left outstanding: criteria not attempted, gaps the review or
  gap-analysis stages recorded, and any bead released rather than completed.
- A pointer to the final report and the gap-traceability report by path, so a
  reader can get from the summary to the evidence.

Then record what was posted:

```sh
gc bd update "<workflow-root-id>" \
  --set-metadata "gc.build.completion_summary_status=posted" \
  --set-metadata "gc.build.completion_summary_blueprint_id=<blueprint_id>" \
  --set-metadata "gc.build.completion_summary_message_id=<posted message id>" \
  --set-metadata "gc.build.completion_summary_posted_at=<UTC timestamp>"
```

If the post itself fails, record
`gc.build.completion_summary_status=failed` with a machine-readable
`gc.build.completion_summary_reason`, and do not let the failure erase the
publish outcome already recorded above — a summary that did not send is a
reporting gap, not a reason to lose the record of PRs that really opened.

## Rule 3 — post exactly once, even when this stage is retried

Before posting, read `gc.build.completion_summary_posted_at` from the workflow
root. If it is already set, a summary for this run has already been posted: do
not post a second one. Re-run the recording step if metadata is missing, but
leave the thread alone.

This stage is retryable, and a discussion thread is append-only with no
de-duplication. Every retry that skips this check adds another near-identical
summary to a thread humans read.

## Rule 4 — report the run as it actually happened

The summary is a delivery record, and switchyard is the system of record it
feeds. Never describe work the run did not do.

- Do not claim a criterion is delivered. Delivery is recorded by attaching a
  MERGED pull request to the PRD, which happens elsewhere and only once a PR
  lands. An open PR named in a summary is an open PR, and the summary says so.
- Do not attach a PR, complete a bead, or write a validation verdict from this
  stage. This stage reports; it does not change a criterion's state.
- Take PR URLs, bead ids, and outcomes from what the run recorded, not from
  memory of what it intended. If a value was never recorded, say it is unknown
  rather than filling it in.

## Close

Before closing this step, set the claimed step outcome with
`gc bd update "<claimed-step-id>" --set-metadata "gc.outcome=pass"`, then close
with `gc bd close "<claimed-step-id>" --reason "<concise reason>"`. Do not pass
`--metadata` or `--set-metadata` to `gc bd close`, and do not use
`gc.outcome=success`; successful workflow stages use `gc.outcome=pass`.

Do not use `gc bd update --metadata 'key=value'`; `--metadata` only accepts a
JSON object. Store plain scalar strings without embedded quote characters.

Close this step only after the publish action or explicit no-op is recorded on
both the workflow root and the publish step, and after
`gc.build.completion_summary_status` is recorded as `posted`, `skipped`, or
`failed`. Never ask questions in headless mode; record unresolved ambiguity in
the publish artifact instead.
