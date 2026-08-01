Push your branch to origin and open a pull request for it.

This step is the reason the work becomes visible to a human. Nothing downstream
merges on your behalf — there is no refinery in a gascity city. If you skip this
step, or let it fail quietly, the change exists only on local disk while every
switchyard surface reads the bead as delivered.

**Do not close any bead in this step.** The close is the next step, and it
depends on this one precisely so that a bead cannot reach closed without a PR.

---

**1. Branch-shape gate (fails closed).**

Confirm you are on the per-item branch the worktree step cut, not your agent
home branch or a stray local checkout, and that the bead records it.

```bash
CONVOY_STATUS=$(gc convoy status {{convoy_id}} --json)
WORK_BEAD_ID=$(printf '%s' "$CONVOY_STATUS" | jq -r 'if (.children | length) == 1 then .children[0].id else empty end')
if [ -z "$WORK_BEAD_ID" ]; then
    echo "sy-item-work requires an input convoy with exactly one tracked member" >&2
    exit 1
fi

CURRENT_BRANCH=$(git branch --show-current)
if [ -z "$CURRENT_BRANCH" ] || [ "$CURRENT_BRANCH" = "{{base_branch}}" ]; then
    echo "BRANCH SHAPE GATE FAILED"
    echo "  current branch: ${CURRENT_BRANCH:-<detached>}"
    echo "  Refusing to open a PR from the base branch or a detached HEAD."
    echo "  Re-run the prepare-worktree step to get a per-item branch."
    exit 1
fi

gc bd update "$WORK_BEAD_ID" --set-metadata branch="$CURRENT_BRANCH"
```

**2. Commit anything outstanding, then push.**

"Already committed" and "the commit failed" are different outcomes and must not
share a branch. `git commit` exits non-zero for BOTH — an empty index is the
ordinary case here (the implement step usually committed already), while a
failing hook or an unmergeable index is a real error. A blanket `|| true` folds
the second into the first and pushes whatever happens to be on the branch.
Decide with the index, not with the exit code.

```bash
git add -A || {
    echo "STAGING FAILED — refusing to push a partially staged change."
    exit 1
}

if git diff --cached --quiet; then
    echo "Nothing outstanding to commit; the implement step already committed."
else
    git commit -m "<summary>" || {
        echo "COMMIT FAILED — the working tree has changes that would not commit."
        echo "  Do NOT push: the branch would be missing part of the work."
        exit 1
    }
fi

git push -u origin "$CURRENT_BRANCH"
PUSH_EXIT=$?
if [ "$PUSH_EXIT" -ne 0 ]; then
    echo "PUSH FAILED (exit $PUSH_EXIT) — branch '$CURRENT_BRANCH' is NOT on origin."
    exit 1
fi
```

**3. Verify the push actually landed. `git push` exiting 0 is not proof.**

This check is not ceremony — it is here because the exit code has lied before.
Confirm the ref is reachable on origin *and* that its tip matches your HEAD.

```bash
REMOTE_REF=$(git ls-remote origin "refs/heads/$CURRENT_BRANCH" 2>/dev/null | awk '{print $1}')
LOCAL_HEAD=$(git rev-parse HEAD)
if [ -z "$REMOTE_REF" ]; then
    echo "PUSH VERIFICATION FAILED: no ref for '$CURRENT_BRANCH' on origin. Branch is local-only."
    exit 1
fi
if [ "$REMOTE_REF" != "$LOCAL_HEAD" ]; then
    echo "PUSH VERIFICATION FAILED"
    echo "  origin/$CURRENT_BRANCH = $REMOTE_REF"
    echo "  local HEAD             = $LOCAL_HEAD"
    exit 1
fi
```

**4. Open the pull request, and record its URL on the bead.**

Use the forge the rig's `origin` actually points at — `gh` for GitHub,
`glab` for GitLab. Resolve it rather than assuming; several rigs are GitLab.

```bash
ORIGIN_URL=$(git remote get-url origin)
case "$ORIGIN_URL" in
    *github.com*)  FORGE=gh  ;;
    *gitlab*)      FORGE=glab ;;
    *)             FORGE=""  ;;
esac

**Capture the status, never just the last line.** `2>&1 | tail -1` takes the
tail of the *combined* stream and throws the exit code away through the pipe, so
a failed create yields the forge's ERROR TEXT in `PR_URL` — which then gets
written to the bead. `publish-gate` only reports beads whose `pr_url` is
**empty**, so a non-empty garbage value sails past the very check meant to catch
this. Keep the output, keep the status, and only accept a real URL.

```bash
case "$FORGE" in
  gh)
    CREATE_OUT=$(gh pr create --base "{{base_branch}}" --head "$CURRENT_BRANCH" \
        --title "<title>" --body "<what changed, and how it was verified>" 2>&1)
    CREATE_RC=$?
    # An existing PR for this branch is success, not failure — look it up.
    if [ "$CREATE_RC" -ne 0 ]; then
        PR_URL=$(gh pr view "$CURRENT_BRANCH" --json url --jq .url 2>/dev/null)
    else
        PR_URL=$(printf '%s\n' "$CREATE_OUT" | grep -Eo 'https://[^[:space:]]+' | tail -1)
    fi
    ;;
  glab)
    CREATE_OUT=$(glab mr create --target-branch "{{base_branch}}" --source-branch "$CURRENT_BRANCH" \
        --title "<title>" --description "<what changed, and how it was verified>" --yes 2>&1)
    CREATE_RC=$?
    if [ "$CREATE_RC" -ne 0 ]; then
        PR_URL=$(glab mr view "$CURRENT_BRANCH" --output json 2>/dev/null | jq -r '.web_url // empty')
    else
        PR_URL=$(printf '%s\n' "$CREATE_OUT" | grep -Eo 'https://[^[:space:]]+' | tail -1)
    fi
    ;;
  *)
    echo "UNKNOWN FORGE for origin '$ORIGIN_URL' — cannot open a PR."
    echo "Escalate rather than closing: the branch is pushed but unreviewed."
    gc mail send mayor --subject "sy-item-work: unknown forge, PR not opened" \
        --body "Bead $WORK_BEAD_ID pushed $CURRENT_BRANCH but origin '$ORIGIN_URL' matched no known forge."
    exit 1
    ;;
esac
```

If the PR already exists for this branch, that is success — the lookup above
reuses its URL rather than failing.

**Validate before writing.** `pr_url` is the one field `publish-gate` trusts, so
an unvalidated write disarms the gate. Refuse anything that is not an `https://`
URL, and escalate instead of recording it:

```bash
case "$PR_URL" in
  https://*) ;;
  *)
    echo "PR NOT OPENED — no usable URL for '$CURRENT_BRANCH'."
    echo "  forge exit: ${CREATE_RC:-?}"
    echo "  forge said: ${CREATE_OUT:-<no output>}"
    gc mail send mayor --subject "sy-item-work: PR not opened, bead left open" \
        --body "Bead $WORK_BEAD_ID pushed $CURRENT_BRANCH but no PR could be opened or found. Forge exit ${CREATE_RC:-?}. Output: ${CREATE_OUT:-<none>}"
    exit 1
    ;;
esac
```

Only now record the result, and the target, on the bead:

```bash
gc bd update "$WORK_BEAD_ID" \
  --set-metadata target={{base_branch}} \
  --set-metadata pr_url="$PR_URL" \
  --notes "Published: <brief summary>"
```

`pr_url` is load-bearing. Switchyard's `attach_prd_pr` and the PRD Completion
tab read it, and the `publish-gate` order escalates any closed pool bead that
has no `pr_url` — which is what turns a silent non-publish into mayor mail
within one order cycle.

**5. If the PR could not be opened, escalate — do not proceed.**

An unopened PR is not a smaller success. Mail the mayor and fail this step so
the close never runs. A stranded branch with an open bead is recoverable; a
closed bead with no PR looks exactly like finished work.
