#!/bin/sh
# pr-rework-sweep: dispatch a rework session onto each open PR whose standing
# review verdict is a rejection — one PR per nudge.
#
# The rationale, the standing-reject definition, and the TTL/cadence decoupling
# live in orders/pr-rework-sweep.toml — read that first. Mechanics here follow
# review-sweep.sh and repair-sweep.sh, which document them:
#
# - Everything flows through FILES, never `pipe | while read`: a piped while
#   loop runs in a subshell where assignments vanish.
# - PR metadata goes to a file and jq reads the FILE — Linux's 128 KiB
#   per-argument cap breaks argument-passed JSON on long comment threads.
# - The assignment marker embeds the head sha: an assignment is about one
#   exact head, and a rework that lands MOVES the head, which is what retires
#   the assignment. The marker is written only AFTER the nudge succeeds — a
#   failed dispatch must leave nothing live, or it suppresses its own retry.
# - THE SETTLED LEDGER IS READ, NEVER WRITTEN. review-sweep records what
#   verdict stands on each exact head (including a verdict carried across a
#   content-identical rebase by patch-id); this lane consults that ledger to
#   recognise a reject whose comment predates a rebased head. Only review-sweep
#   writes it — two writers on one ledger is how the two lanes drift.
# - EVERY FAILURE IS ACCOUNTED (pack.toml's governing invariant). A failed
#   nudge, an unwritable marker, a failed spawn, a missing prerequisite on an
#   ENABLED lane — each lands in $failed and one mayor mail per cycle, because
#   an orphaned rejected PR reads exactly like a quiet queue otherwise, and
#   that silent orphaning is the stall this lane exists to end.
set -u

. "$(dirname "$0")/../lib/roster.sh"

sy_load_conf

PR_REWORK_RIGS="${PR_REWORK_RIGS:-}"
# Base, hold label and the verdict literals are the REVIEW lane's values by
# default: this lane consumes exactly the verdicts that lane (and merge-lane)
# trade in, and two configs for one literal is drift waiting to happen.
PR_REWORK_BASE="${PR_REWORK_BASE:-${REVIEW_LANE_BASE:-staging}}"
PR_REWORK_HOLD_LABEL="${PR_REWORK_HOLD_LABEL:-${REVIEW_LANE_HOLD_LABEL:-do-not-merge}}"
REVIEW_LANE_MARKER="${REVIEW_LANE_MARKER:-Verdict: APPROVE}"
REVIEW_LANE_REJECT_MARKER="${REVIEW_LANE_REJECT_MARKER:-Verdict: REQUEST CHANGES}"
# PAIRED TO THE REWORK AGENT'S max_session_age (4h), not to the cadence. At
# expiry the marker simultaneously stops suppressing re-dispatch AND stops
# counting its session busy, so an expired assignment whose holder is still
# alive gets a second nudge that drops the in-flight fix on the floor. With
# the TTL at the agent's own age ceiling, the holder CANNOT still be alive at
# expiry — the reconciler has already killed it — so re-dispatch is always
# recovery, never interruption. Completed work does not wait on this window:
# the delivered pre-pass below releases the busy hold the moment the head
# moves. Shortening this below max_session_age reintroduces the mid-fix
# restart; lengthen both together or neither.
PR_REWORK_ASSIGNMENT_TTL="${PR_REWORK_ASSIGNMENT_TTL:-14400}"
# The sibling repair lane's TTL, read here only to judge whether the shared
# rework session is currently busy with a criterion repair (its markers carry
# the target alias in field 2, same shape as ours).
REPAIR_ASSIGNMENT_TTL="${REPAIR_ASSIGNMENT_TTL:-3600}"

# Off by default: pushing fixes onto other sessions' PR branches is authority
# an operator grants per rig, deliberately, in roster.conf — review-sweep's
# exact posture. An un-opted-in city must never notice this order exists.
[ -n "$PR_REWORK_RIGS" ] || exit 0

state="$(sy_state_dir)"
mkdir -p "$state" 2>/dev/null

# rw_mail_once KEY SUBJECT BODY — one mail per standing fault, cleared when the
# fault clears (review-sweep's rs_mail_once shape). The lane is OPTED IN past
# this point, so a prerequisite hole is an incident, not a posture.
rw_mail_once() {
  _rw_marker="$state/pr-rework-sweep.alert.$1"
  [ -f "$_rw_marker" ] && return 0
  gc mail send mayor --subject "$2" --body "$3" >/dev/null 2>&1 || true
  : >"$_rw_marker" 2>/dev/null || true
}

for _rw_tool in jq gh; do
  if ! command -v "$_rw_tool" >/dev/null 2>&1; then
    rw_mail_once "prereq-$_rw_tool" \
      "pr-rework-sweep: lane enabled but '$_rw_tool' is missing" \
      "PR_REWORK_RIGS is set, so the operator asked for this lane, but '$_rw_tool' is not on PATH and no rejected PR can be read or dispatched. Every rejected PR stays orphaned until it is installed."
    exit 0
  fi
  rm -f "$state/pr-rework-sweep.alert.prereq-$_rw_tool" 2>/dev/null
done

TMP=$(mktemp -d 2>/dev/null) || exit 0
trap 'rm -rf "$TMP"' EXIT INT TERM

markers="$state/pr-rework-assignments"
review_markers="$state/review-assignments"
repair_markers="$state/repair-assignments"
mkdir -p "$markers" 2>/dev/null

# Marker keys embed the head sha, so a marker for an old head can never
# suppress a reworked-and-repushed PR; stale keys just age out here.
find "$markers" -type f -mtime +7 -delete 2>/dev/null || true

LOG="$state/pr-rework-sweep.log"

# One session roster for the whole sweep (cost + coherence — see roster.sh).
# UNKNOWN liveness dispatches nothing: a nudge into a roster we cannot read
# could double-assign, and this lane loses only latency by waiting a cycle.
sy_session_snapshot || exit 0

# mkey_for SLUG NUM HEAD — the assignment marker path for one exact PR head.
# The SAME key transform as review-sweep's, deliberately: settled_verdict below
# reads that lane's ledger by reconstructing its keys, and a drift in the
# transform silently reads an empty ledger forever.
mkey_for() {
  printf '%s/%s' "$markers" "$(printf '%s' "$1#$2@$3" | tr -c 'A-Za-z0-9' '-')"
}

# settled_verdict SLUG NUM HEAD — the verdict review-sweep recorded as standing
# on this exact head ("approve"/"reject"), or nothing. Field 2 of the settled
# marker; settled markers written before verdicts were recorded are empty and
# read as nothing, which fails toward "not standing" — one review-lane cycle of
# latency, never a wrong dispatch.
settled_verdict() {
  _sv_f="$review_markers/$(printf '%s' "$1#$2@$3" | tr -c 'A-Za-z0-9' '-').settled"
  [ -f "$_sv_f" ] || return 0
  awk 'NR==1{print $2}' "$_sv_f" 2>/dev/null
}

# marker_fresh FILE TTL — first line's first field is the routed-at epoch
# (repair-sweep's marker shape); fresh means younger than TTL seconds.
marker_fresh() {
  [ -f "$1" ] || return 1
  _mf_at="$(awk 'NR==1{print $1}' "$1" 2>/dev/null)"
  case "${_mf_at:-}" in '' | *[!0-9]*) _mf_at=0 ;; esac
  [ $((now - _mf_at)) -lt "$2" ]
}

# marker_delivered FILE — has this assignment been observed DELIVERED (its
# PR's head moved, or the PR left the open list)? An appended line, never a
# rewrite of line 1 (repair-sweep's `consumed` stamp shape), so the routed-at
# parse above and any older marker keep parsing exactly as before.
marker_delivered() {
  [ -f "$1" ] || return 1
  awk 'NR>1 && $1 == "delivered" { found = 1 } END { exit !found }' "$1" 2>/dev/null
}

# target_busy ALIAS — does ALIAS hold a fresh, UNDELIVERED assignment from
# THIS lane or the criterion-repair lane? The rework agent is
# max_active_sessions=1 and both sweeps route to it; nudging a second job at
# a fresh-wake session drops the first on the floor while its marker still
# suppresses re-dispatch. (repair-sweep carries the mirror-image check for
# this lane's markers — the two must stay paired, or the direction that
# loses its check silently drops in-flight work again.)
#
# A DELIVERED assignment does not count: the marker's other job — per-head
# dispatch dedup — has to outlive the work, but busy-ness must not, or one
# 20-minute rework would pin the whole rig's throughput for the rest of the
# TTL while the session idles.
target_busy() {
  for _tb_m in "$markers"/*; do
    [ -f "$_tb_m" ] || continue
    marker_delivered "$_tb_m" && continue
    if marker_fresh "$_tb_m" "$PR_REWORK_ASSIGNMENT_TTL" &&
      [ "$(awk 'NR==1{print $2}' "$_tb_m" 2>/dev/null)" = "$1" ]; then
      return 0
    fi
  done
  for _tb_m in "$repair_markers"/*; do
    [ -f "$_tb_m" ] || continue
    if marker_fresh "$_tb_m" "$REPAIR_ASSIGNMENT_TTL" &&
      [ "$(awk 'NR==1{print $2}' "$_tb_m" 2>/dev/null)" = "$1" ]; then
      return 0
    fi
  done
  return 1
}

now="$(date +%s)"
routed=0
failed=""
suspended_rigs="$(sy_suspended_rigs)"

for rig in $PR_REWORK_RIGS; do
  # A suspended rig is the mayor's explicit stop order (review-sweep's gate).
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

  # A failed list is a FAILURE, never an empty queue: `|| : > queue.json`
  # would make an API outage or an expired gh token read exactly like a rig
  # with no rejected PRs — orphaning every one of them in silence, which is
  # the invariant violation this whole lane exists to end.
  if ! gh pr list --repo "$slug" --state open --base "$PR_REWORK_BASE" --limit 100 \
    --json number,isDraft,labels,createdAt,headRefOid,headRefName,reviewDecision,mergeable \
    > "$TMP/queue.json" 2>/dev/null; then
    failed="$failed $rig(pr-list-failed)"
    continue
  fi

  # DELIVERED PRE-PASS. An assignment marker's dispatch-dedup job is per-head
  # and must outlive the work, but its busy-ness must not: a marker whose
  # recorded head is no longer the PR's current head (the rework pushed), or
  # whose PR has left the open list entirely (merged/closed), is finished
  # work — stamp it so target_busy stops counting it. PARSE-OR-NOTHING: the
  # stamp runs only over a non-empty list that jq actually parsed, because a
  # blank or malformed body read as "no PRs are open" would stamp every LIVE
  # assignment delivered and free a busy session for a double nudge. A
  # genuinely empty list is `[]`, which is non-empty, parses, and stamps
  # everything — correctly. Markers record their PR in field 3 and head in
  # field 4 precisely because the tr'd filename cannot answer either question.
  if [ -s "$TMP/queue.json" ] &&
    jq -r '.[] | "\(.number) \(.headRefOid)"' "$TMP/queue.json" > "$TMP/open-heads" 2>/dev/null; then
    for _dp_m in "$markers"/*; do
      [ -f "$_dp_m" ] || continue
      marker_delivered "$_dp_m" && continue
      _dp_pr="$(awk 'NR==1{print $3}' "$_dp_m" 2>/dev/null)"
      case "${_dp_pr:-}" in "$slug#"*) : ;; *) continue ;; esac
      _dp_head="$(awk 'NR==1{print $4}' "$_dp_m" 2>/dev/null)"
      if ! grep -qx "${_dp_pr##*#} ${_dp_head:-}" "$TMP/open-heads" 2>/dev/null; then
        printf 'delivered %s\n' "$now" >> "$_dp_m" 2>/dev/null || true
      fi
    done
  fi

  # First cut: open, not draft, no hold label, not APPROVED. CHANGES_REQUESTED
  # stays IN — that formal latch is exactly the reject this lane exists to
  # consume (review-sweep excludes it for the opposite reason: a finished
  # review needs no reviewer) — and the decision rides along because the
  # stale-reject gate below needs it.
  jq -r --arg hold "$PR_REWORK_HOLD_LABEL" '
    sort_by(.createdAt)[]
    | select(.isDraft | not)
    | select(([.labels[]?.name] | index($hold)) | not)
    | select((.reviewDecision // "") != "APPROVED")
    | "\(.number)\t\(.headRefOid)\t\(.headRefName)\t\(.mergeable // "UNKNOWN")\t\(.reviewDecision // "")"' \
    "$TMP/queue.json" > "$TMP/queue" 2>/dev/null || : > "$TMP/queue"
  [ -s "$TMP/queue" ] || continue

  # The dispatch target, resolved once per rig. Revival state is decided
  # LAZILY inside the loop — only a candidate that survives every guard proves
  # demand, and repair-sweep documents why spawning on the raw queue is wrong
  # (it staffed rigs whose every item was already settled).
  target=""
  target_known=1
  if ! target="$(sy_live_session_for "$rig/$SY_NS.rework")"; then
    target=""
    target_known=0
  fi
  rework_attempted=0
  rework_warming=0

  TAB="$(printf '\t')"
  while IFS="$TAB" read -r num head branch mergeable decision; do
    [ -n "$num" ] && [ -n "$head" ] || continue

    mkey="$(mkey_for "$slug" "$num" "$head")"
    # A live assignment suppresses re-dispatch; an expired one means the
    # nudged session never delivered (died, drained, wedged) and the PR is
    # dispatched again rather than stranded behind a marker.
    marker_fresh "$mkey" "$PR_REWORK_ASSIGNMENT_TTL" && continue

    # BUSY GATE FIRST, and it ENDS the rig's cycle. The rework agent is
    # max_active_sessions=1, so once its session holds a live job nothing
    # else can dispatch this cycle — and busy-ness can only flip false→true
    # within a cycle (a dispatch below). Checking here, before the per-PR
    # view call, is what keeps a 100-PR queue from spending 99 GraphQL reads
    # on candidates that cannot route. A busy target is not a failure: the
    # queue simply waits, which is the serialization the agent's own pool
    # ceiling already chose.
    if [ "$target_known" -eq 1 ] && [ -n "$target" ] && target_busy "$target"; then
      break
    fi

    # A PR whose metadata cannot be read is a FAILURE for that PR, not a
    # skip: if it is the standing-rejected one, a silent continue here is a
    # clean-looking cycle that orphaned exactly the PR the lane exists for.
    if ! gh pr view "$num" --repo "$slug" --json comments,commits,reviews,mergeable \
      > "$TMP/meta.json" 2>/dev/null || [ ! -s "$TMP/meta.json" ]; then
      failed="$failed $slug#$num(pr-view-failed)"
      continue
    fi

    # Mergeability from the VIEW call when it has an answer, because the list
    # call routinely reads UNKNOWN in the very window this lane keys on: a
    # base move invalidates every open PR's mergeability, GitHub recomputes
    # it asynchronously, and a conflicted PR dispatched during that window
    # would get a brief with no conflict instructions — a rework pushed onto
    # a branch that still cannot merge, with pr-refresh refusing to touch it.
    _mv="$(jq -r '.mergeable // ""' "$TMP/meta.json" 2>/dev/null)"
    [ -n "$_mv" ] && [ "$_mv" != "UNKNOWN" ] && mergeable="$_mv"

    # The newest FINISHED verdict on the PR — a marker comment (either
    # literal) or a formal APPROVED/CHANGES_REQUESTED review — classified
    # against the head's last non-merge commit (review-sweep's exclusion, for
    # the same reason). Emits: STANDING<TAB>AT<TAB>BY where STANDING is
    # reject / approve (verdict stands on the current head), stale-reject /
    # stale-approve (the head moved since), or none.
    ev="$(jq -r --arg a "$REVIEW_LANE_MARKER" --arg r "$REVIEW_LANE_REJECT_MARKER" '
      ([.commits[]?
        | select(.messageHeadline | test("^Merge (branch|remote-tracking branch) ") | not)
        | .committedDate] | max // "") as $t
      | ([.comments[]?
          | select((.body | contains($a)) or (.body | contains($r)))
          | {class: (if (.body | contains($a)) then "approve" else "reject" end),
             at: (.createdAt // ""), by: (.author.login // "unknown")}]
         + [.reviews[]?
          | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")
          | {class: (if .state == "APPROVED" then "approve" else "reject" end),
             at: (.submittedAt // ""), by: (.author.login // "unknown")}])
      | sort_by(.at) | last
      | if . == null then "none\t\t"
        elif .at > $t then "\(.class)\t\(.at)\t\(.by)"
        else "stale-\(.class)\t\(.at)\t\(.by)" end' "$TMP/meta.json" 2>/dev/null)"
    standing="$(printf '%s\n' "$ev" | cut -f1)"
    rej_at="$(printf '%s\n' "$ev" | cut -f2)"
    rej_by="$(printf '%s\n' "$ev" | cut -f3)"

    case "$standing" in
    reject) : ;;
    stale-reject)
      # The head moved since the reject. NEW content is the reviewer's ball
      # (review-sweep re-reviews it); two signals say the reject still
      # STANDS on this head despite its age, and either one routes:
      #
      #   * review-sweep's settled ledger records this exact head as
      #     rejected — a content-identical rebase carried the marker-comment
      #     verdict (the patch-id settle);
      #   * the PR-level reviewDecision latch still reads CHANGES_REQUESTED
      #     — GitHub holds that latch until a re-review or dismissal, and
      #     review-sweep's first cut drops such PRs before its settle path
      #     can ever run, so the ledger STRUCTURALLY cannot answer for a
      #     formal reject. Without this leg a formally-rejected PR is
      #     orphaned forever after its first rebase. The latch also survives
      #     a REAL fix until re-review, so this can cost one redundant nudge
      #     onto an already-fixed head — bounded by the per-head marker, and
      #     the rework session reads the PR before changing anything; the
      #     alternative is unbounded orphaning.
      if [ "$(settled_verdict "$slug" "$num" "$head")" != "reject" ] &&
        [ "$decision" != "CHANGES_REQUESTED" ]; then
        continue
      fi
      ;;
    *) continue ;;
    esac

    # The findings: the newest reject verdict's body, capped so the nudge
    # stays one safe argument (Linux's 128 KiB per-arg limit; macOS hides it).
    findings="$(jq -r --arg r "$REVIEW_LANE_REJECT_MARKER" '
      ([.comments[]? | select(.body | contains($r))
        | {at: (.createdAt // ""), body: (.body // "")}]
       + [.reviews[]? | select(.state == "CHANGES_REQUESTED")
        | {at: (.submittedAt // ""), body: (.body // "")}])
      | sort_by(.at) | last
      | (.body // "")[0:6000]' "$TMP/meta.json" 2>/dev/null)"
    [ -n "$findings" ] || findings="(the reject verdict's body could not be read — read the PR's comments and reviews with gh before you change anything)"

    conflict_note=""
    if [ "$mergeable" = "CONFLICTING" ]; then
      conflict_note="

THIS PR IS CONFLICTING with $PR_REWORK_BASE. pr-refresh cannot rebase it (a
conflicted rebase aborts untouched), so resolving the conflict against
$PR_REWORK_BASE is PART of this rework — rebase first, resolve, then fix the
findings on the rebased branch."
    fi

    # Rework-lane revival (repair-sweep's spawn-then-dispatch ordering): a
    # nudge into a booting or waking pane is lost, and the marker would then
    # suppress the retry for a full TTL — so either revival routes NEXT cycle.
    # A FAILED revival falls through to the failure accumulation below, so a
    # rig whose rework agent is missing or suspended mails the mayor within
    # one cycle instead of spinning a doomed spawn forever.
    if [ "$target_known" -eq 1 ] && [ -z "$target" ] && [ "$rework_attempted" -eq 0 ]; then
      rework_attempted=1
      _rw_agent="$rig/$SY_NS.rework"
      _rw_any="$(sy_session_alias_for "$_rw_agent" "" 2>/dev/null)" || _rw_any=""
      if [ -n "$_rw_any" ]; then
        if gc session wake "$_rw_any" >/dev/null 2>&1; then
          rework_warming=1
          echo "pr-rework-sweep: $rig rework session $_rw_any is asleep; woke it, routing next cycle"
        fi
      elif gc session new "$_rw_agent" --no-attach >/dev/null 2>&1; then
        rework_warming=1
        echo "pr-rework-sweep: $rig has rework demand and no rework session; spawned one, routing next cycle"
      fi
    fi
    if [ "$target_known" -eq 0 ]; then
      failed="$failed $slug#$num(session-lookup-failed)"
      continue
    fi
    if [ -z "$target" ]; then
      if [ "$rework_warming" -eq 1 ]; then
        # The lane is warming — a wake/spawn just succeeded. Not a failure,
        # not routed: the next cycle finds it live and routes.
        continue
      fi
      failed="$failed $slug#$num(no-live-worker)"
      continue
    fi

    if gc session nudge "$target" "PR REWORK $slug#$num (base $PR_REWORK_BASE, head $head, branch $branch)

A finished review REFUSED this pull request${rej_by:+ (by $rej_by${rej_at:+ at $rej_at})}, and its author
session no longer exists — you own the rework. Fix what the review refused
and push to the SAME branch ($branch); the review lane re-reviews the new
head automatically. Never open a second PR, and never post the approve
literal yourself — a rework that reviews itself has approved its own work.
If the head has moved past $head, work from the current head instead.

THE FINDINGS
$findings$conflict_note" </dev/null >/dev/null 2>&1; then
      # Marker AFTER the nudge, never before: a failed dispatch must leave
      # nothing live so the next cycle retries it. A marker that did not
      # persist is a routing failure — nothing suppresses a duplicate next
      # cycle — so it is reported, never swallowed. Fields 3 and 4 (slug#num,
      # head) exist for the delivered pre-pass: the tr'd FILENAME cannot
      # answer which PR or head a marker is about.
      if printf '%s %s %s %s\n' "$now" "$target" "$slug#$num" "$head" > "$mkey" 2>/dev/null; then
        routed=$((routed + 1))
        printf '%s dispatched %s#%s@%s -> %s\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$slug" "$num" "$head" "$target" >> "$LOG" 2>/dev/null || true
      else
        failed="$failed $slug#$num(marker-write-failed)"
        # No marker means nothing marks $target busy, so the next candidate
        # would nudge the same singleton session again THIS cycle — and
        # wake_mode "fresh" would drop the PR it was just handed. Stop
        # dispatching into this rig for the cycle instead; the mail already
        # carries the fault and the next cycle retries.
        break
      fi
    else
      failed="$failed $slug#$num(nudge-failed:$target)"
    fi
  done < "$TMP/queue"
done

# SILENT-FAILURE INVARIANT (pack.toml): a standing reject nobody was routed to
# is a rejected PR with no owner and nobody watching — precisely the orphaning
# this order removes — so it becomes mail within the cycle.
if [ -n "$failed" ]; then
  gc mail send mayor \
    --subject "pr-rework-sweep: could not dispatch every rework" \
    --body "This cycle found a standing reject verdict on each of these PRs and could not put a rework session on it:$failed

Routed $routed rework assignment(s) successfully this cycle.

pr-list-failed means 'gh pr list' failed for that rig — an API outage, an expired gh token, or lost repo permission — so NO rejected PR there could even be seen this cycle.
pr-view-failed means the PR list was read but that PR's metadata could not be — its standing verdict is UNKNOWN and it was not dispatched.
session-lookup-failed means 'gc session list --json' could not be read, so whether that rig has a live rework session is UNKNOWN — check gc and jq first.
no-live-worker means the roster was read fine and the sweep's own wake/spawn of '<rig>/$SY_NS.rework' FAILED — the agent is not imported into that rig, is suspended, or the city is at its session cap. Fix that registration rather than waiting on more cycles.
nudge-failed means the session alias resolved but 'gc session nudge' returned non-zero — check the session with 'gc session peek'.
marker-write-failed means the session WAS nudged but the assignment could not be recorded, so nothing suppresses a duplicate dispatch next cycle: fix the pack state directory's writability.

Until this clears, those PRs stay rejected with nobody reworking them." \
    >/dev/null 2>&1 || true
fi

exit 0
