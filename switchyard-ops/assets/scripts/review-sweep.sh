#!/bin/sh
# review-sweep: dispatch a reviewer session onto each open PR lacking a
# finished review on its current head — one PR per nudge.
#
# The rationale, the qualification gates, and the one-PR-per-nudge design live
# in orders/review-sweep.toml — read that first. Mechanics that matter here
# (inherited from merge-lane.sh and repair-sweep.sh, which document them):
#
# - Everything flows through FILES, never `pipe | while read`: a piped while
#   loop runs in a subshell where assignments vanish.
# - PR metadata goes to a file and jq reads the FILE — Linux's 128 KiB
#   per-argument cap, which macOS hides, breaks argument-passed JSON the
#   moment one PR accumulates a long comment thread.
# - Gates are evaluated on the CURRENT head, freshly queried per run. The
#   assignment marker embeds the head sha for the same reason: a verdict, and
#   therefore a dispatch, is about one exact head.
# - EVERY FAILURE IS ACCOUNTED (pack.toml's governing invariant). A failed
#   nudge, an unwritable marker, a failed spawn, a missing prerequisite on an
#   ENABLED lane — each lands in $failed and one mayor mail per cycle, because
#   a review lane that is down reads exactly like a quiet PR queue otherwise,
#   and starving merge-lane silently is the stall this lane exists to end.
set -u

. "$(dirname "$0")/../lib/roster.sh"

sy_load_conf

REVIEW_LANE_RIGS="${REVIEW_LANE_RIGS:-}"
REVIEW_LANE_BASE="${REVIEW_LANE_BASE:-staging}"
REVIEW_LANE_HOLD_LABEL="${REVIEW_LANE_HOLD_LABEL:-do-not-merge}"
REVIEW_LANE_MARKER="${REVIEW_LANE_MARKER:-Verdict: APPROVE}"
# The REJECT literal is a gate input, not just prose: a posted
# `Verdict: REQUEST CHANGES` comment is a FINISHED review of this head — the
# author's move now — and a gate that only recognised the approve literal
# re-dispatched the same head every TTL forever, a full review's tokens per
# cycle, burying the PR thread in identical rejections.
REVIEW_LANE_REJECT_MARKER="${REVIEW_LANE_REJECT_MARKER:-Verdict: REQUEST CHANGES}"
REVIEW_ASSIGNMENT_TTL="${REVIEW_ASSIGNMENT_TTL:-5400}"

# Off by default: posting verdicts under the repo's review bar is authority an
# operator grants per rig, deliberately, in roster.conf — merge-lane's exact
# posture. Empty means this lane does not even read the PR list, and missing
# prerequisites are NOT reported (an un-opted-in city must never notice this
# order exists).
[ -n "$REVIEW_LANE_RIGS" ] || exit 0

state="$(sy_state_dir)"
mkdir -p "$state" 2>/dev/null

# rs_mail_once KEY SUBJECT BODY — one mail per standing fault, cleared when
# the fault clears (vs_mail_once's shape). The lane is OPTED IN past this
# point, so a prerequisite hole is an incident, not a posture.
rs_mail_once() {
  _rm_marker="$state/review-sweep.alert.$1"
  [ -f "$_rm_marker" ] && return 0
  gc mail send mayor --subject "$2" --body "$3" >/dev/null 2>&1 || true
  : >"$_rm_marker" 2>/dev/null || true
}

for _rs_tool in jq gh; do
  if ! command -v "$_rs_tool" >/dev/null 2>&1; then
    rs_mail_once "prereq-$_rs_tool" \
      "review-sweep: lane enabled but '$_rs_tool' is missing" \
      "REVIEW_LANE_RIGS is set, so the operator asked for this lane, but '$_rs_tool' is not on PATH and no PR can be read or dispatched. Reviews are produced by NOBODY and merge-lane's review bar starves until it is installed."
    exit 0
  fi
  rm -f "$state/review-sweep.alert.prereq-$_rs_tool" 2>/dev/null
done

TMP=$(mktemp -d 2>/dev/null) || exit 0
trap 'rm -rf "$TMP"' EXIT INT TERM

markers="$state/review-assignments"
mkdir -p "$markers" 2>/dev/null

# Marker keys embed the head sha, so a marker for an old head can never
# suppress a re-pushed PR; stale keys just age out here. `settled.` markers
# (a head already carrying a finished review — see below) age out on the same
# sweep: once the head is gone from the open-PR list they are dead weight.
find "$markers" -type f -mtime +7 -delete 2>/dev/null || true

LOG="$state/review-sweep.log"

# One session roster for the whole sweep (cost + coherence — see roster.sh).
# UNKNOWN liveness dispatches nothing: a nudge into a roster we cannot read
# could double-assign, and this lane loses only latency by waiting a cycle.
sy_session_snapshot || exit 0

# mkey_for SLUG NUM HEAD — the assignment/settled marker path for one exact
# PR head. ONE definition: the gate that reads it and the dispatch that
# writes it must never drift on the key shape, or every PR is silently
# re-dispatched every cycle.
mkey_for() {
  printf '%s/%s' "$markers" "$(printf '%s' "$1#$2@$3" | tr -c 'A-Za-z0-9' '-')"
}

# marker_fresh FILE TTL — first line's first field is the routed-at epoch
# (repair-sweep's marker shape); fresh means younger than TTL seconds.
marker_fresh() {
  [ -f "$1" ] || return 1
  _mf_at="$(awk 'NR==1{print $1}' "$1" 2>/dev/null)"
  case "${_mf_at:-}" in '' | *[!0-9]*) _mf_at=0 ;; esac
  [ $((now - _mf_at)) -lt "$2" ]
}

now="$(date +%s)"
failed=""
suspended_rigs="$(sy_suspended_rigs)"

for rig in $REVIEW_LANE_RIGS; do
  # A suspended rig is the mayor's explicit stop order; dispatching reviews
  # into it (or spawning reviewers on it) fights that decision. lane-ensure
  # gates on the same fact for every other lane.
  _rig_suspended=0
  for _sr in $suspended_rigs; do
    [ "$_sr" = "$rig" ] && { _rig_suspended=1; break; }
  done
  [ "$_rig_suspended" -eq 1 ] && continue

  rig_root="$(sy_rig_root "$rig")"
  [ -d "$rig_root/.git" ] || continue

  # owner/repo straight off the rig's own remote (merge-lane's pattern).
  slug=$(git -C "$rig_root" remote get-url origin 2>/dev/null \
    | sed -e 's#^git@github.com:##' -e 's#^https://github.com/##' -e 's#\.git$##')
  case "$slug" in
    */*) : ;;
    *)   continue ;;
  esac

  gh pr list --repo "$slug" --state open --base "$REVIEW_LANE_BASE" --limit 100 \
    --json number,isDraft,labels,createdAt,headRefOid,reviewDecision \
    > "$TMP/queue.json" 2>/dev/null || : > "$TMP/queue.json"

  # First cut from the list call alone: open, not draft, no hold label, and no
  # verdict already standing in reviewDecision. APPROVED needs no reviewer;
  # CHANGES_REQUESTED is the AUTHOR's ball until a new head lands. (This lane's
  # own verdicts are COMMENTS, invisible to reviewDecision — the deep gate
  # below is what sees them.)
  jq -r --arg hold "$REVIEW_LANE_HOLD_LABEL" '
    sort_by(.createdAt)[]
    | select(.isDraft | not)
    | select(([.labels[]?.name] | index($hold)) | not)
    | select((.reviewDecision // "") != "APPROVED")
    | select((.reviewDecision // "") != "CHANGES_REQUESTED")
    | "\(.number) \(.headRefOid)"' "$TMP/queue.json" > "$TMP/queue" 2>/dev/null \
    || : > "$TMP/queue"
  [ -s "$TMP/queue" ] || continue

  # Deep gates need a per-PR view call, so they run only on the first cut:
  # a marker-comment verdict on the current head (either literal — the PR is
  # reviewed), and failing CI (red goes back to its author without spending a
  # review). A head found reviewed writes a `settled.` marker so later cycles
  # skip even the view call — the comment cannot un-post, and a new head is a
  # new key. Red CI writes NO marker: checks can be re-run on the same head.
  : > "$TMP/candidates"
  while read -r num head; do
    [ -n "$num" ] || continue

    mkey="$(mkey_for "$slug" "$num" "$head")"
    [ -f "$mkey.settled" ] && continue
    # A live assignment suppresses re-dispatch; an expired one means the
    # nudged session never delivered (died, drained, wedged) and the PR is
    # dispatched again rather than stranded behind a marker.
    marker_fresh "$mkey" "$REVIEW_ASSIGNMENT_TTL" && continue

    gh pr view "$num" --repo "$slug" --json comments,commits,statusCheckRollup \
      > "$TMP/meta.json" 2>/dev/null
    [ -s "$TMP/meta.json" ] || continue

    # A verdict after the head's last authored commit = reviewed. Same
    # merge-from-base exclusion as merge-lane, for the same starvation reason.
    last_commit=$(jq -r '
      [.commits[]
       | select(.messageHeadline | test("^Merge (branch|remote-tracking branch) ") | not)
       | .committedDate] | max // ""' "$TMP/meta.json")
    reviewed=$(jq -r --arg a "$REVIEW_LANE_MARKER" --arg r "$REVIEW_LANE_REJECT_MARKER" --arg t "$last_commit" '
      [.comments[]? | select((.body | contains($a)) or (.body | contains($r)))
       | select(.createdAt > $t)] | length' "$TMP/meta.json")
    if [ "${reviewed:-0}" != "0" ]; then
      : > "$mkey.settled" 2>/dev/null || true
      continue
    fi

    # Red CI: the author's problem, not a reviewer's. Pending is fine — review
    # and CI are parallel work on the same head.
    bad=$(jq -r '
      [.statusCheckRollup[]?
       | if .state? then (if .state == "FAILURE" or .state == "ERROR" then 1 else empty end)
         else (if .status == "COMPLETED" and (.conclusion != "SUCCESS" and .conclusion != "NEUTRAL" and .conclusion != "SKIPPED") then 1 else empty end)
         end] | length' "$TMP/meta.json")
    [ "${bad:-0}" = "0" ] || continue

    printf '%s %s\n' "$num" "$head" >> "$TMP/candidates"
  done < "$TMP/queue"
  [ -s "$TMP/candidates" ] || continue

  # The dispatchable pool: live reviewer sessions NOT already holding a fresh
  # assignment. A reviewer mid-review is busy — nudging it a second PR makes
  # its fresh-wake contract drop the first one on the floor while that PR's
  # marker still suppresses re-dispatch. Busy-ness is read from the markers
  # themselves (field 2 of a fresh marker is the target), the same ledger
  # that gates the PR side.
  if ! sy_session_aliases_for "$rig/$SY_NS.reviewer" active > "$TMP/live-all"; then
    failed="$failed $rig(roster-unreadable)"
    continue
  fi
  : > "$TMP/live"
  while IFS= read -r _alias; do
    [ -n "$_alias" ] || continue
    _busy=0
    for _m in "$markers"/*; do
      [ -f "$_m" ] || continue
      case "$_m" in *.settled) continue ;; esac
      if marker_fresh "$_m" "$REVIEW_ASSIGNMENT_TTL" &&
        [ "$(awk 'NR==1{print $2}' "$_m" 2>/dev/null)" = "$_alias" ]; then
        _busy=1
        break
      fi
    done
    [ "$_busy" -eq 0 ] && printf '%s\n' "$_alias" >> "$TMP/live"
  done < "$TMP/live-all"

  # Dispatch: pair candidates (oldest PR first) with free reviewers, one PR
  # per session per cycle. `paste` joins the two files line-by-line; a line
  # with an empty target is demand beyond the pool, left for the spawn below.
  dispatched=0
  paste "$TMP/candidates" "$TMP/live" > "$TMP/pairs" 2>/dev/null || : > "$TMP/pairs"
  while IFS="$(printf '\t')" read -r cand target; do
    [ -n "$cand" ] || continue
    [ -n "${target:-}" ] || break
    num="${cand%% *}"
    head="${cand##* }"
    if gc session nudge "$target" "REVIEW $slug#$num (base $REVIEW_LANE_BASE, head $head)

Review this pull request now, per your prompt. The approve literal for this
dispatch is exactly: $REVIEW_LANE_MARKER
The reject literal is exactly: $REVIEW_LANE_REJECT_MARKER
If the head has moved past $head, review the current head instead — the newer
diff is the one that would merge." </dev/null >/dev/null 2>&1; then
      mkey="$(mkey_for "$slug" "$num" "$head")"
      if ! printf '%s %s\n' "$now" "$target" > "$mkey" 2>/dev/null; then
        # The nudge went out but nothing suppresses a re-dispatch: the next
        # cycle puts a second reviewer on this PR. Report it — an unwritable
        # state dir is one incident, not a per-cycle nag, so via the once-path.
        failed="$failed $slug#$num(marker-write-failed)"
      fi
      printf '%s dispatched %s#%s@%s -> %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$slug" "$num" "$head" "$target" >> "$LOG" 2>/dev/null || true
      dispatched=$((dispatched + 1))
    else
      failed="$failed $slug#$num(nudge-failed:$target)"
    fi
  done < "$TMP/pairs"

  # Spawn toward the pool ceiling when demand outruns the live pool. The new
  # session receives its assignment on a LATER cycle, once it answers live.
  # The ceiling is the AGENT's own max_active_sessions, read from the resolved
  # config so a city patch is honored without a second knob — and read only
  # when there is unassigned demand, because it costs a gc invocation.
  n_candidates="$(grep -c . "$TMP/candidates" 2>/dev/null)" || n_candidates=0
  n_live="$(grep -c . "$TMP/live-all" 2>/dev/null)" || n_live=0
  unassigned=$((n_candidates - dispatched))
  if [ "$unassigned" -gt 0 ]; then
    # Both shapes gc emits: an object with .agents, or a bare top-level array
    # (roster.sh and pool-spawn parse the same output with the same guard).
    pool_max="$(gc agent list --json 2>/dev/null | jq -r --arg q "$rig/$SY_NS.reviewer" '
      (if type == "array" then . else (.agents // []) end)[]
      | select((.qualified_name // .name // "") == $q)
      | (.pool.max // .max_active_sessions // 2)' 2>/dev/null | head -n1)"
    case "${pool_max:-}" in '' | *[!0-9]*) pool_max=2 ;; esac
    cap=$((pool_max - n_live))
    [ "$unassigned" -lt "$cap" ] && cap="$unassigned"
    i=0
    while [ "$i" -lt "$cap" ]; do
      if ! gc session new "$rig/$SY_NS.reviewer" --no-attach >/dev/null 2>&1; then
        # A rig that never imported the reviewer agent, or a city at its
        # session cap: without this the lane is indistinguishable from a
        # quiet PR queue while every candidate waits forever.
        failed="$failed $rig(spawn-failed)"
        break
      fi
      i=$((i + 1))
    done
  fi
done

if [ -n "$failed" ]; then
  gc mail send mayor \
    --subject "review-sweep: could not dispatch every review" \
    --body "This cycle failed to dispatch or account for:$failed

nudge-failed means the reviewer session's alias resolved but 'gc session nudge' returned non-zero — check the session with 'gc session peek'.
marker-write-failed means the reviewer WAS nudged but the assignment could not be recorded, so nothing suppresses a duplicate dispatch next cycle: fix the pack state directory's writability.
spawn-failed means 'gc session new <rig>/$SY_NS.reviewer' failed — the agent is not imported into that rig, is suspended, or the city is at its session cap.
roster-unreadable means 'gc session list --json' could not be read, so liveness was UNKNOWN and nothing was dispatched for that rig this cycle." \
    >/dev/null 2>&1 || true
fi

exit 0
