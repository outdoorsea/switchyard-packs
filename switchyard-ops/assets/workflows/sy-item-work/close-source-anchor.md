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

Note the difference from gastown, in case you are carrying that habit: under
`mol-polecat-work` a worker was forbidden to close its own bead, because the
refinery closed it after verifying the merge. There is no refinery here. Closing
your own source anchor is correct and expected — *once the PR exists*. What you
must never do is close before publishing, or close in place of publishing.

Merging is still not yours. The PR stays open for a reviewer.
