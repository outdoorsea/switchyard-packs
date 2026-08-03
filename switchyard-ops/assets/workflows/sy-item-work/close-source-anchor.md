Close the source anchor for this work item.

This is `implementation-base`'s source-anchor close, re-stated here for one
reason only: it must run **after** `publish`, not after `implement`. The parent
contract wires it to `implement`; a bead that closed there would be marked
delivered with its branch still on local disk.

Before closing, confirm the publish step actually produced a pull request. The
step ordering makes this nearly always true, so treat a failure here as a real
signal rather than a formality:

```bash
CONVOY_STATUS=$(gc convoy status {{convoy_id}} --json)
WORK_BEAD_ID=$(printf '%s' "$CONVOY_STATUS" | jq -r 'if (.children | length) == 1 then .children[0].id else empty end')
PR_URL=$(gc bd show "$WORK_BEAD_ID" --json | jq -r '.[0].metadata.pr_url // empty')
if [ -z "$PR_URL" ]; then
    echo "REFUSING TO CLOSE: bead $WORK_BEAD_ID has no metadata.pr_url."
    echo "The publish step did not record a pull request. Closing now would mark"
    echo "unreviewed, unpushed work as delivered."
    exit 1
fi
```

Then verify the implementation result and close the anchor. If
`{{summary_path}}` is set, write or verify the per-item implementation summary
there before closing.

## Verify the close actually took effect — do not skip this

**The precondition guard above is not enough.** It proves a PR exists; it proves
nothing about whether your close succeeded. On 2026-08-02 this step closed
itself with `gc.outcome: pass` and the reason "Source anchor closed after
publish verified" while `sf-u2cb` was still **open** — deadlocking all of PRD
#294 behind `pool_wip_limit: 1` for about an hour. Every surface read healthy:
the workflow said pass, the judge said nothing was reachable, the bridge agent
said it was carrying on. Nobody was wrong locally. The failure lived in the seam.

A close that reports success is not a close. Re-read the bead and assert the
postcondition:

```bash
# after issuing the close on the work bead
ACTUAL=$(gc bd show "$WORK_BEAD_ID" --json | jq -r '.[0].status // "unknown"')
if [ "$ACTUAL" != "closed" ]; then
    echo "FATAL: close reported success but $WORK_BEAD_ID is status=$ACTUAL."
    echo "Do NOT report pass. A stranded anchor blocks every dependent bead and"
    echo "holds the pool WIP slot open with no surface reporting a problem."
    exit 1
fi
```

Also close the **input convoy** explicitly, then assert it too. The convoy
depends on the work bead, so a stranded convoy keeps dependents blocked even
after the anchor closes correctly — `sf-km76` was left open by the same defect
and had to be cleared by hand:

```bash
CONVOY_ID={{convoy_id}}
# after issuing the close on the convoy
CONVOY_ACTUAL=$(gc bd show "$CONVOY_ID" --json | jq -r '.[0].status // "unknown"')
if [ "$CONVOY_ACTUAL" != "closed" ]; then
    echo "FATAL: input convoy $CONVOY_ID is status=$CONVOY_ACTUAL after close."
    exit 1
fi
```

Verify the outcome, not the input. That rule is already written into
`city.toml` for base-branch checks (`gh pr view <n> --json baseRefName`) for
exactly this reason — the same class of bug, one lane over.

Note the difference from gastown, in case you are carrying that habit: under
`mol-polecat-work` a worker was forbidden to close its own bead, because the
refinery closed it after verifying the merge. There is no refinery here. Closing
your own source anchor is correct and expected — *once the PR exists*. What you
must never do is close before publishing, or close in place of publishing.

Merging is still not yours. The PR stays open for a reviewer.
