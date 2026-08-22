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
# One page of open PRs, newest-first. The size is load-bearing for the
# departed-marker cleanup below: absence from the page is read as departure,
# so a page that OVERFLOWS the limit — a truncated view of a longer queue —
# must clear nothing. Operator-settable, so validated like every other
# numeric knob here: a malformed value would fail the gh call itself and
# read as an empty queue — the lane down with nothing accounted.
REVIEW_LANE_LIST_LIMIT="${REVIEW_LANE_LIST_LIMIT:-100}"
case "$REVIEW_LANE_LIST_LIMIT" in '' | *[!0-9]* | 0*) REVIEW_LANE_LIST_LIMIT=100 ;; esac
# This lane is the FALLBACK reviewer, and a fallback that outdraws the primary
# is just a second reviewer: with the repo's standing reviewer (CodeRabbit)
# healthy, dispatching on the first cycle after a push would double-review
# every PR. So a head younger than the grace window is left for the primary —
# UNLESS the primary has already said it cannot review (its rate-limit banner
# on this head), in which case waiting serves nobody and the grace is skipped.
# 0 disables the wait entirely.
REVIEW_LANE_GRACE_SECONDS="${REVIEW_LANE_GRACE_SECONDS:-1200}"
# The literal that identifies the primary reviewer's own "cannot review"
# notice. CodeRabbit's Fair Usage banner carries this heading verbatim.
REVIEW_LANE_PRIMARY_LIMIT_MARKER="${REVIEW_LANE_PRIMARY_LIMIT_MARKER:-Review limit reached}"

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

# rs_settle MKEY VERDICT PATCHID — record a finished review of one exact head.
#
# The settled marker used to be an empty touch-file; it now carries
# `<epoch> <verdict> <patch-id>` so two consumers can read it back:
#   * THIS sweep's rebase short-circuit below, which needs the patch-id to
#     recognise the same content under a new head sha;
#   * pr-rework-sweep, which needs the VERDICT to know a rebased head is
#     standing-rejected (its comment predates the rebase, so no comment-time
#     gate can show it).
# `-` stands for "patch-id unavailable" so the line always has three fields.
# Existing empty markers keep working: every reader treats a missing field as
# absent, which costs one re-review at worst, never a wrong verdict.
rs_settle() {
  printf '%s %s %s\n' "$now" "$2" "${3:--}" > "$1.settled" 2>/dev/null || true
}

# rs_base_ready — resolve the rig's base tip ONCE per rig, cached in
# $rig_base_sha (reset at the top of the rig loop). rc=0 with the cache
# populated, rc=1 when the base cannot be resolved this cycle.
#
# One fetch per rig, not per candidate: the base tip cannot change the
# answer within a run, and a post-base-move cycle is exactly when many
# candidates need a patch-id at once — per-candidate fetches multiplied a
# constant read into real repo rate-limit pressure. The sha is read from
# the remote-tracking ref when the clone's refspec maintains one (immune to
# another process overwriting the shared FETCH_HEAD file between our fetch
# and our read — this runs in the rig's LIVE clone), falling back to
# FETCH_HEAD for exotic clone shapes. A failed resolve is cached too
# ($rig_base_failed), so a broken origin costs one attempt per cycle, not
# one per candidate.
rs_base_ready() {
  [ -n "${rig_base_sha:-}" ] && return 0
  [ "${rig_base_failed:-0}" -eq 1 ] && return 1
  if git -C "$rig_root" fetch --quiet origin "$REVIEW_LANE_BASE" >/dev/null 2>&1; then
    rig_base_sha="$(git -C "$rig_root" rev-parse --verify --quiet "refs/remotes/origin/$REVIEW_LANE_BASE" 2>/dev/null)"
    [ -n "${rig_base_sha:-}" ] || rig_base_sha="$(git -C "$rig_root" rev-parse --verify --quiet FETCH_HEAD 2>/dev/null)"
  fi
  [ -n "${rig_base_sha:-}" ] && return 0
  rig_base_failed=1
  return 1
}

# rs_patch_id NUM HEAD BASE_SHA — the PR's merge-base diff patch-id, or rc=1.
#
# `git patch-id --stable` hashes the diff's hunks with line numbers ignored,
# so a clean rebase of UNCHANGED hunks onto a moved base yields the same id —
# while a rebase whose hunks actually interacted with the new base yields a
# different one, which is exactly the case that deserves a fresh review.
#
# The PR head is fetched per call and read back through FETCH_HEAD,
# cross-checked against the sha we are judging: refs/pull/N/head may have
# moved since the list call, and a patch-id of some OTHER head would be
# attributed to this one. The base sha arrives as an argument (rs_base_ready,
# once per rig). Every failure (fetch, moved head, empty diff) returns rc=1
# and the caller falls through to a normal dispatch: the cost of degrading is
# one review, the old behaviour, never a wrong settle.
rs_patch_id() {
  git -C "$rig_root" fetch --quiet origin "refs/pull/$1/head" >/dev/null 2>&1 || return 1
  [ "$(git -C "$rig_root" rev-parse --verify --quiet FETCH_HEAD 2>/dev/null)" = "$2" ] || return 1
  _rpi_out="$(git -C "$rig_root" diff "$3...$2" 2>/dev/null \
    | git patch-id --stable 2>/dev/null | awk '{print $1; exit}')"
  [ -n "${_rpi_out:-}" ] || return 1
  printf '%s' "$_rpi_out"
}

# rs_prior_has_pid SLUG NUM — does ANY settled marker for this PR carry a real
# patch-id? The cheap existence probe that gates the rebase short-circuit: a
# fresh PR with no settled history must not cost a fetch. The candidate's OWN
# head cannot appear here (its settled marker would have skipped it earlier),
# so every match is a PRIOR head. The key prefix is mkey_for's transform of
# `slug#num@`, so the two cannot drift apart without drifting mkey_for itself.
rs_prior_has_pid() {
  _rph_pfx="$(printf '%s' "$1#$2@" | tr -c 'A-Za-z0-9' '-')"
  for _rph_f in "$markers/$_rph_pfx"*.settled; do
    [ -f "$_rph_f" ] || continue
    _rph_pid="$(awk 'NR==1{print $3}' "$_rph_f" 2>/dev/null)"
    [ -n "${_rph_pid:-}" ] && [ "$_rph_pid" != "-" ] && return 0
  done
  return 1
}

# rs_settled_verdict_for_pid SLUG NUM PID — the verdict of any settled marker
# for this PR whose patch-id equals PID, or nothing. EQUALITY against every
# sibling, not "the newest": a PR whose content returns to an EARLIER head's
# content (a reverted fixup) still matches the marker that actually judged
# that content — a newest-only pick missed it and burned a full re-review of
# content already on the record.
rs_settled_verdict_for_pid() {
  _rvp_pfx="$(printf '%s' "$1#$2@" | tr -c 'A-Za-z0-9' '-')"
  # One patch-id can match SEVERAL settled markers (the same content judged
  # under different head shas), and glob order is head-sha order — arbitrary.
  # An approve among them wins outright: the only caller acts on "reject",
  # and carrying a reject that a sibling approve of the SAME content
  # supersedes would rework a PR the record already cleared. With no approve,
  # the NEWEST matching marker (field 1, the settle epoch) speaks for the
  # content, so a stale sibling cannot outvote the latest judgement.
  _rvp_verdict='' _rvp_best=0
  for _rvp_f in "$markers/$_rvp_pfx"*.settled; do
    [ -f "$_rvp_f" ] || continue
    [ "$(awk 'NR==1{print $3}' "$_rvp_f" 2>/dev/null)" = "$3" ] || continue
    _rvp_v="$(awk 'NR==1{print $2}' "$_rvp_f" 2>/dev/null)"
    if [ "$_rvp_v" = "approve" ]; then
      printf 'approve'
      return 0
    fi
    _rvp_at="$(awk 'NR==1{print $1}' "$_rvp_f" 2>/dev/null)"
    case "${_rvp_at:-}" in '' | *[!0-9]*) _rvp_at=0 ;; esac
    if [ "$_rvp_at" -ge "$_rvp_best" ]; then
      _rvp_best="$_rvp_at"
      _rvp_verdict="$_rvp_v"
    fi
  done
  printf '%s' "$_rvp_verdict"
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

  # Per-rig patch-id base cache (rs_base_ready): reset so one rig's base — or
  # one rig's failed resolve — can never answer for the next rig's.
  rig_base_sha=""
  rig_base_failed=0

  # owner/repo straight off the rig's own remote (merge-lane's pattern).
  slug=$(git -C "$rig_root" remote get-url origin 2>/dev/null \
    | sed -e 's#^git@github.com:##' -e 's#^https://github.com/##' -e 's#\.git$##')
  case "$slug" in
    */*) : ;;
    *)   continue ;;
  esac

  # Fetch ONE more than the limit: a count past the limit then proves the
  # page is a truncated view of a longer queue, while a complete queue of
  # exactly the limit still counts at most the limit and cleans up normally.
  gh pr list --repo "$slug" --state open --base "$REVIEW_LANE_BASE" \
    --limit "$((REVIEW_LANE_LIST_LIMIT + 1))" \
    --json number,isDraft,labels,createdAt,headRefOid,reviewDecision \
    > "$TMP/queue.json" 2>/dev/null || : > "$TMP/queue.json"

  # CLEAR DEPARTED PRs' MARKERS BEFORE ANYTHING READS THEM. The verdict settle
  # below iterates only PRs still in the open queue, so a PR approved and then
  # MERGED between sweeps kept its marker live and its reviewer reading busy
  # for the full REVIEW_ASSIGNMENT_TTL while idle — dispatch moved in waves
  # exactly one TTL apart with qualified PRs waiting hours (observed
  # 2026-08-21). A marker names its PR in field 3; one whose PR is absent
  # from a trustworthy open list is done HERE — so the marker is DELETED,
  # never `.settled`: departure is reversible (a mistaken close can be
  # reopened, a retargeted base restored — same head, same key), and a
  # durable settle for a returning head would suppress its dispatch for the
  # 7-day GC window with no alarm, where deletion just lets the PR re-enter
  # every gate. The cost of deletion is a possible SECOND review when a
  # departure flaps mid-review (retargeted away and back inside one
  # assignment) — accepted deliberately: a duplicate review is loud and
  # cheap, a suppressed one is silent and unbounded. repair-sweep's
  # rm-on-settle states the same rationale. Only a VERDICT may settle
  # durably, because only a verdict cannot un-happen.
  # Two guards decide "trustworthy":
  #   - parse-or-nothing: a failed `gh pr list` leaves an EMPTY file, and jq
  #     accepts empty input as zero documents at rc=0, so the count check
  #     also rejects emptiness — a fetch blip must never read as "no PRs are
  #     open" and free every busy reviewer at once. A genuinely empty list
  #     is `[]`: parses, counts 0, clears everything — correctly.
  #   - a count past the limit means the page is a truncated view of a
  #     longer queue (newest-first fetch, oldest-first dispatch — the PRs
  #     beyond the page are exactly the ones old enough to hold
  #     assignments): absence from it proves nothing, so cleanup is
  #     suspended AND the mayor is mailed once, because a queue that STAYS
  #     past the limit would otherwise reinstate the one-TTL waves silently,
  #     forever, on the busiest repos.
  # (Markers from before field 3 existed are skipped and age out on the TTL,
  # exactly as before.)
  _open_count="$(jq 'if type == "array" then length else -1 end' "$TMP/queue.json" 2>/dev/null)"
  case "${_open_count:-x}" in *[!0-9]*) _open_count="" ;; esac
  _rs_slug_key="$(printf '%s' "$slug" | tr -c 'A-Za-z0-9' '-')"
  if [ -n "$_open_count" ] && [ "$_open_count" -gt "$REVIEW_LANE_LIST_LIMIT" ]; then
    rs_mail_once "list-truncated-$_rs_slug_key" \
      "review-sweep: $slug has more open PRs than one page" \
      "gh pr list returned more than REVIEW_LANE_LIST_LIMIT ($REVIEW_LANE_LIST_LIMIT) open PRs against $REVIEW_LANE_BASE for $slug, so departed-PR marker cleanup is suspended (absence from a truncated page proves nothing) and reviewer busy-ness recovers only on the assignment TTL. Raise REVIEW_LANE_LIST_LIMIT in roster.conf or drain the queue."
  elif [ -n "$_open_count" ]; then
    # Clear the standing-overflow alert only on a TRUSTWORTHY in-limit
    # count; an unreadable fetch says nothing about the queue draining, and
    # clearing on it would re-arm the once-mail across every fetch blip.
    rm -f "$state/review-sweep.alert.list-truncated-$_rs_slug_key" 2>/dev/null
  fi
  if [ -n "$_open_count" ] && [ "$_open_count" -le "$REVIEW_LANE_LIST_LIMIT" ] \
    && jq -r '.[].number' "$TMP/queue.json" > "$TMP/open-nums" 2>/dev/null; then
    for _m in "$markers"/*; do
      [ -f "$_m" ] || continue
      case "$_m" in *.settled) continue ;; esac
      [ -f "$_m.settled" ] && continue
      _mpr="$(awk 'NR==1{print $3}' "$_m" 2>/dev/null)"
      case "${_mpr:-}" in "$slug#"*) : ;; *) continue ;; esac
      grep -qx "${_mpr##*#}" "$TMP/open-nums" && continue
      rm -f "$_m" 2>/dev/null || true
    done
  fi

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
    # The touch is load-bearing, not hygiene: the 7-day marker prune above
    # keys on mtime, and a settled marker skipped here every cycle otherwise
    # keeps its FIRST-write mtime — on day 8 the prune would delete a live
    # PR's entire verdict history and re-arm one full re-review per week for
    # any long-lived rejected PR. Refreshing on each skip means aging only
    # starts once the PR leaves the open list.
    [ -f "$mkey.settled" ] && { touch "$mkey.settled" 2>/dev/null || true; continue; }

    gh pr view "$num" --repo "$slug" --json comments,commits,statusCheckRollup \
      > "$TMP/meta.json" 2>/dev/null
    [ -s "$TMP/meta.json" ] || continue

    # A verdict after the head's last authored commit = reviewed. Same
    # merge-from-base exclusion as merge-lane, for the same starvation reason.
    # This runs BEFORE the live-assignment skip on purpose: a verdict on an
    # assigned head is that assignment DELIVERED, and checking freshness first
    # meant the delivery was not noticed — and its reviewer not freed — until
    # the TTL expired. The view call this spends per in-flight assignment per
    # cycle is bounded by the reviewer pool, and buys the busy set its
    # accuracy.
    #
    # The NEWEST matching comment decides WHICH verdict stands (the reviewer
    # prompt forbids a reject containing the approve literal, so a comment
    # carrying both classifies as approve by that contract). The old form
    # only counted matches — "reviewed or not" — which was all this lane
    # needed; the ledger now records which, because pr-rework-sweep routes on
    # a standing REJECT and must never read an approve as one.
    last_commit=$(jq -r '
      [.commits[]
       | select(.messageHeadline | test("^Merge (branch|remote-tracking branch) ") | not)
       | .committedDate] | max // ""' "$TMP/meta.json")
    verdict=$(jq -r --arg a "$REVIEW_LANE_MARKER" --arg r "$REVIEW_LANE_REJECT_MARKER" --arg t "$last_commit" '
      [.comments[]? | select((.body | contains($a)) or (.body | contains($r)))
       | select(.createdAt > $t)]
      | sort_by(.createdAt) | last
      | if . == null then ""
        elif (.body | contains($a)) then "approve"
        else "reject" end' "$TMP/meta.json")
    if [ -n "${verdict:-}" ]; then
      _sp_pid=""
      if rs_base_ready; then
        _sp_pid="$(rs_patch_id "$num" "$head" "$rig_base_sha")" || _sp_pid=""
      fi
      rs_settle "$mkey" "$verdict" "$_sp_pid"
      continue
    fi

    # A live assignment suppresses re-dispatch; an expired one means the
    # nudged session never delivered (died, drained, wedged) and the PR is
    # dispatched again rather than stranded behind a marker.
    marker_fresh "$mkey" "$REVIEW_ASSIGNMENT_TTL" && continue

    # REBASE-IDENTICAL SHORT-CIRCUIT — REJECTS ONLY. A rebase rewrites
    # committer dates, so a verdict that was on the head's last commit
    # yesterday predates it today — while the CONTENT may be byte-identical
    # (pr-refresh rebases open PRs whenever the base moves, and a clean
    # rebase changes nothing but shas). Without this, the same content is
    # re-reviewed after every base move: the verdict comment predates the new
    # head, the sweep re-dispatches, a full review's tokens are spent
    # producing the same verdict, forever. If a PRIOR head of this PR was
    # settled with a patch-id and the current head's patch-id matches a
    # REJECTED one, the reject carries over: settle this head with it (which
    # is what pr-rework-sweep reads) and dispatch nothing.
    #
    # It runs AFTER the live-assignment skip deliberately: a head already
    # carrying a fresh assignment has a reviewer working on it right now, and
    # settling under them would tell the busy set that reviewer is free —
    # earning it a second PR while it is mid-review. The carry loses nothing
    # by waiting: the first cycle after a rebase mints a NEW head key, which
    # has no assignment marker at all, so the short-circuit fires there.
    #
    # AN APPROVE NEVER CARRIES, deliberately. merge-lane's approve evidence
    # is a formal APPROVED review or a marker COMMENT newer than the head's
    # last commit — it does not read this ledger — so a carried approve would
    # suppress exactly the re-dispatch that regenerates the comment the merge
    # needs: the PR would sit settled-approved, unmergeable and
    # un-re-reviewable, until the marker prune. A rebased approved PR falls
    # through to a fresh dispatch instead; the re-review it costs is the one
    # that makes the approval mergeable again.
    #
    # Any failure to compute falls through to a normal dispatch — one review,
    # the old behaviour, never a wrong settle.
    if rs_prior_has_pid "$slug" "$num"; then
      cur_pid=""
      if rs_base_ready; then
        cur_pid="$(rs_patch_id "$num" "$head" "$rig_base_sha")" || cur_pid=""
      fi
      if [ -n "$cur_pid" ] && [ "$(rs_settled_verdict_for_pid "$slug" "$num" "$cur_pid")" = "reject" ]; then
        rs_settle "$mkey" "reject" "$cur_pid"
        printf '%s settled-by-patch-id %s#%s@%s (reject)\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$slug" "$num" "$head" >> "$LOG" 2>/dev/null || true
        continue
      fi
    fi

    # Grace window: a young head belongs to the primary reviewer first. The
    # age is judged from the head's last authored commit (already in hand),
    # in jq because POSIX sh has no portable ISO-8601 parser. The primary's
    # own rate-limit banner on this head waives the wait — it has told us it
    # is not coming. No marker is written either way: a waived or expired
    # grace simply falls through to dispatch on this or a later cycle.
    if [ "${REVIEW_LANE_GRACE_SECONDS:-0}" -gt 0 ]; then
      in_grace=$(jq -r --arg t "$last_commit" --arg lim "$REVIEW_LANE_PRIMARY_LIMIT_MARKER"         --argjson g "$REVIEW_LANE_GRACE_SECONDS" '
        if ($t | length) == 0 then 0
        elif ([.comments[]? | select(.body | contains($lim)) | select(.createdAt > $t)] | length) > 0 then 0
        elif (now - ($t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) < $g then 1
        else 0 end' "$TMP/meta.json" 2>/dev/null)
      [ "${in_grace:-0}" = "1" ] && continue
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
  # that gates the PR side — but only a marker whose PR is still open WITHOUT
  # a verdict counts. A verdict-settled marker is finished work, and a
  # departed PR's marker was deleted by the pre-pass above: counting either
  # kept the reviewer idle-but-busy for the rest of the TTL after every
  # review it completed. The TTL itself stays what it was — the recovery
  # window for a nudge that never produced a verdict OR a departure.
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
      [ -f "$_m.settled" ] && continue
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
      # Marker line: routed-at epoch, target alias, slug#num. Field 3 exists
      # because the FILENAME cannot answer "which PR is this marker about" —
      # tr is lossy and one slug can be a prefix of another (acme/app,
      # acme/app-packs), so the departed-PR cleanup pre-pass keys on this
      # field, exactly, never on the name.
      mkey="$(mkey_for "$slug" "$num" "$head")"
      if ! printf '%s %s %s\n' "$now" "$target" "$slug#$num" > "$mkey" 2>/dev/null; then
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
    # Lower the ceiling to the balancer's reviewer target when it has
    # published a fresh, well-formed one (switchyard PRD #397). The cap lands
    # on pool_max rather than on the slot count below, so the target governs
    # TOTAL reviewer concurrency — live sessions included — instead of how
    # many may be added on top of a pool that already exceeds it. With no
    # target to honour this returns pool_max unchanged, which is the whole
    # fall-back: an unopted city, or one whose balancer stopped writing,
    # spawns exactly as it does today.
    pool_max="$(sy_balancer_capped "$rig" reviewer "$pool_max")"
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
