#!/bin/sh
# merge-lane: merge reviewed, green pull requests into the staging base.
#
# The full rationale, the review bar, and the one-merge-per-run design live in
# orders/merge-lane.toml — read that first. Mechanics that matter here:
#
# - Everything flows through FILES, never `pipe | while read`: a piped while
#   loop runs in a subshell where assignments vanish, producing a dead check
#   that looks healthy (integration-lane documents the same trap).
# - PR metadata goes to a file and jq reads the FILE. Passing the JSON as a
#   command argument breaks on Linux's 128 KiB per-argument cap the moment one
#   PR accumulates a long comment thread — and macOS hides that cap locally.
# - Gates are evaluated on the CURRENT head, freshly queried per run. Nothing
#   here trusts a verdict recorded against an older head or an older base.
set -u

. "$(dirname "$0")/../lib/roster.sh"

sy_load_conf

MERGE_LANE_RIGS="${MERGE_LANE_RIGS:-}"
MERGE_LANE_BASE="${MERGE_LANE_BASE:-staging}"
MERGE_LANE_HOLD_LABEL="${MERGE_LANE_HOLD_LABEL:-do-not-merge}"
MERGE_LANE_REVIEW_MARKER="${MERGE_LANE_REVIEW_MARKER:-Verdict: APPROVE}"

# Off by default: merge authority is granted per rig, deliberately, in
# roster.conf. An empty list means this lane does not even read the queue.
[ -n "$MERGE_LANE_RIGS" ] || exit 0

TMP=$(mktemp -d 2>/dev/null) || exit 0
trap 'rm -rf "$TMP"' EXIT INT TERM

LOG="$(sy_state_dir)/merge-lane.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null

for rig in $MERGE_LANE_RIGS; do
  rig_root="$(sy_rig_root "$rig")"
  [ -d "$rig_root/.git" ] || continue

  # owner/repo straight off the rig's own remote (integration-lane's pattern).
  slug=$(git -C "$rig_root" remote get-url origin 2>/dev/null \
    | sed -e 's#^git@github.com:##' -e 's#^https://github.com/##' -e 's#\.git$##')
  case "$slug" in
    */*) : ;;
    *)   continue ;;
  esac

  # Oldest first: gh returns newest-first, and taking that order would let a
  # fresh PR queue-jump work that has been waiting through the whole pipeline.
  gh pr list --repo "$slug" --state open --base "$MERGE_LANE_BASE" --limit 100 \
    --json number,isDraft,labels,createdAt > "$TMP/queue.json" 2>/dev/null \
    || : > "$TMP/queue.json"
  jq -r --arg hold "$MERGE_LANE_HOLD_LABEL" '
    sort_by(.createdAt)[]
    | select(.isDraft | not)
    | select(([.labels[]?.name] | index($hold)) | not)
    | .number' "$TMP/queue.json" > "$TMP/queue" 2>/dev/null || : > "$TMP/queue"

  while read -r num; do
    [ -n "$num" ] || continue

    gh pr view "$num" --repo "$slug" \
      --json mergeable,mergeStateStatus,reviews,comments,commits,statusCheckRollup \
      > "$TMP/meta.json" 2>/dev/null
    [ -s "$TMP/meta.json" ] || continue

    mergeable=$(jq -r '.mergeable // ""' "$TMP/meta.json")
    [ "$mergeable" = "MERGEABLE" ] || continue

    # A green check on a BEHIND branch was green against the base at trigger
    # time only. Update the branch (one cycle of fresh CI against the real
    # base) and let a later run judge the honest verdict.
    mstate=$(jq -r '.mergeStateStatus // ""' "$TMP/meta.json")
    if [ "$mstate" = "BEHIND" ]; then
      gh pr update-branch "$num" --repo "$slug" >/dev/null 2>&1
      continue
    fi

    # Review bar, part 1: no standing CHANGES_REQUESTED. Judged on each
    # reviewer's LATEST review so a rework that earned a later approval is not
    # blocked by the review it answered.
    blocked=$(jq -r '
      [.reviews | group_by(.author.login)[] | max_by(.submittedAt)
       | select(.state == "CHANGES_REQUESTED")] | length' "$TMP/meta.json")
    [ "$blocked" = "0" ] || continue

    # Review bar, part 2: a finished review. Either a real APPROVED review, or
    # a fallback review comment carrying the marker — but only one posted
    # after the head's last commit, because a verdict on an older head proves
    # nothing about this one.
    #
    # "Last commit" EXCLUDES merges from the base: this lane's own BEHIND
    # handling update-branches the PR, and counting that merge commit would
    # reset the review clock on a diff that gained no authored content — every
    # fallback-reviewed PR would then starve in an update-review-update loop
    # of the lane's own making. A base merge changes what the PR lands ON, and
    # the CI bar below re-proves that; it does not change what the PR SAYS.
    approved=$(jq -r '[.reviews[] | select(.state == "APPROVED")] | length' \
      "$TMP/meta.json")
    if [ "$approved" = "0" ]; then
      last_commit=$(jq -r '
        [.commits[]
         | select(.messageHeadline | test("^Merge (branch|remote-tracking branch) ") | not)
         | .committedDate] | max // ""' "$TMP/meta.json")
      fallback=$(jq -r --arg m "$MERGE_LANE_REVIEW_MARKER" --arg t "$last_commit" '
        [.comments[]? | select(.body | contains($m)) | select(.createdAt > $t)]
        | length' "$TMP/meta.json")
      [ "$fallback" != "0" ] || continue
    fi

    # CI bar: every check on the head completed, none failed, and at least one
    # exists — a PR with no checks at all gets no merge, because the absence
    # of CI is not CI. Handles both check runs and legacy status contexts.
    jq -r '
      [.statusCheckRollup[]?
       | if .state? then
           (if .state == "SUCCESS" then "ok"
            elif .state == "PENDING" or .state == "EXPECTED" then "pending"
            else "bad" end)
         else
           (if .status != "COMPLETED" then "pending"
            elif .conclusion == "SUCCESS" or .conclusion == "NEUTRAL"
                 or .conclusion == "SKIPPED" then "ok"
            else "bad" end)
         end]
      | "\(length) \([.[] | select(. == "pending")] | length) \([.[] | select(. == "bad")] | length)"
    ' "$TMP/meta.json" > "$TMP/ci" 2>/dev/null || printf '0 0 1\n' > "$TMP/ci"
    read -r total pending bad < "$TMP/ci"
    [ "${total:-0}" -gt 0 ] || continue
    [ "${pending:-1}" = "0" ] || continue
    [ "${bad:-1}" = "0" ] || continue

    if gh pr merge "$num" --repo "$slug" --merge >/dev/null 2>&1; then
      printf '%s merged %s#%s into %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$slug" "$num" "$MERGE_LANE_BASE" >> "$LOG"
    else
      # Every gate passed and the merge still failed: the lane's model of
      # mergeability is wrong for this PR, and only a person can say why.
      gc mail send mayor \
        -s "merge-lane: $slug#$num passed every gate but the merge failed" \
        -m "gh pr merge $num --repo $slug --merge failed even though the PR was mergeable, not behind, reviewed, and CI-green. The lane will retry next run; if this repeats, something about the repo's merge rules is outside the lane's model." \
        >/dev/null 2>&1
    fi

    # One merge per rig per run: this merge just moved the base under every
    # sibling, so their green is stale by construction. Stop here and let the
    # next run update-branch and re-prove the next one.
    break
  done < "$TMP/queue"
done

exit 0
