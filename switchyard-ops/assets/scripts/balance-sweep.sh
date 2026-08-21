#!/bin/sh
#
# balance-sweep — the factory balancer's measure-and-clamp pass (switchyard
# PRD #397).
#
# Every lane in this pipeline runs at a hand-set parallelism: max_active_sessions
# in city.toml, changed only when a human notices a queue backing up. This order
# measures each lane's queue depth, turns it into a concurrency TARGET inside
# operator-set bounds, and publishes those targets where the spawn sites can read
# them. The operator keeps the hard bounds; the balancer turns the dial within
# them.
#
# WHAT THIS PASS OWNS, and what it deliberately does not. It computes and
# publishes. It does not spawn: the spawn sites honour the file beneath their
# own city.toml ceiling, and the hysteresis and cycle-budget rules are sibling
# criteria layered on top. Keeping the publish step ignorant of them is what
# lets a consumer treat this file as advisory data rather than as a command.
#
# BACKPRESSURE IS THE ONE PLACE A DOWNSTREAM STAGE REACHES BACK. merge-lane and
# staging-promote are serial BY DESIGN — each merge moves the base under every
# other PR — so they are never scaled. When the queue they drain runs deep, the
# answer is not more mergers but fewer producers: the two upstream lanes clamp
# to their operator floors until it drains. That is the whole interaction, and
# it only ever scales lanes DOWN.
#
# THE SAFETY DIRECTION IS "DO NOTHING". Three separate paths lead to writing no
# targets at all — the balancer not being opted in, a rig resolving to nothing,
# and a lane whose demand or capacity cannot be read. All three leave the
# consumers on their existing behaviour, because a missing lane line means the
# consumer falls back to its city.toml ceiling exactly as it does today. That
# asymmetry is deliberate: publishing a target computed from a queue nobody
# could actually read is how a balancer scales a lane on imaginary demand.

set -u

. "$(dirname "$0")/../lib/roster.sh"
. "$(dirname "$0")/../lib/switchyard-api.sh"

: "${SY_NS:=switchyard-ops}"

# The lanes this pass balances. Both are PARALLEL stages — several workers on
# one queue is simply more throughput. The serial stages (merge-lane,
# staging-promote) are absent on purpose and must stay absent: they are ordered
# for correctness, and "scaling" them means two sessions merging into one branch.
BALANCE_LANES="brakeman reviewer"

# Default bounds for a lane BALANCER_BOUNDS does not name: no floor, and a
# ceiling of the lane agent's own resolved capacity. That makes BALANCER_BOUNDS
# purely a NARROWING knob — an operator who sets nothing gets a balancer that
# may range over exactly the capacity they already granted in city.toml, and
# never past it.
#
# The floor is 0 rather than 1 because a floor is a guarantee of PRESENCE, which
# costs a session whether or not there is work. An operator who wants a lane
# warm says so; the default keeps an idle factory idle.
DEFAULT_FLOOR=0

# The reviewed-but-unmerged backlog at which the upstream lanes clamp to their
# floors. merge-lane merges ONE pull request per rig per run on a 10m cadence,
# so this default is one hour of its drain: a backlog it can clear inside the
# hour is the lane working, and a deeper one is work arriving faster than the
# stage can absorb it. 0 switches backpressure off entirely.
DEFAULT_BACKPRESSURE=6

# The `gh` reads have no bound of their own — the switchyard reads carry curl's
# inside sy_api_get. Same name and default as the sibling measurement pass, so
# an operator retuning read patience moves both rather than discovering a
# second knob.
BALANCER_READ_TIMEOUT="${BALANCER_READ_TIMEOUT:-15}"

# ---------------------------------------------------------------------------
# Bounds
# ---------------------------------------------------------------------------

# sy_bound LANE WHICH DEFAULT — one edge of a lane's operator bounds, read from
# BALANCER_BOUNDS ("brakeman=1:6 reviewer=1:3"). WHICH is floor|ceiling.
#
# A malformed entry falls back to DEFAULT rather than refusing to run, the rule
# SY_FANOUT_THRESHOLD already documents for this file: a typo in a tuning knob
# must not take a lane down. It is reported by the caller so the operator learns
# of it, because a silently corrected knob is one nobody ever fixes.
sy_bound() {
  _bl_lane="$1"; _bl_which="$2"; _bl_default="$3"
  _bl_spec=""
  for _bl_entry in ${BALANCER_BOUNDS:-}; do
    case "$_bl_entry" in
      "$_bl_lane"=*) _bl_spec="${_bl_entry#*=}" ;;
    esac
  done
  [ -n "$_bl_spec" ] || { printf '%s' "$_bl_default"; return 0; }

  case "$_bl_which" in
    floor)   _bl_val="${_bl_spec%%:*}" ;;
    ceiling) _bl_val="${_bl_spec#*:}" ;;
    *)       _bl_val="" ;;
  esac
  # A spec with no colon leaves floor and ceiling equal to the whole string;
  # that is malformed, not a shorthand, so it takes the default like any other
  # unreadable value.
  case "$_bl_spec" in *:*) : ;; *) _bl_val="" ;; esac
  case "${_bl_val:-}" in
    '' | *[!0-9]*) printf '%s' "$_bl_default" ;;
    *)             printf '%s' "$_bl_val" ;;
  esac
}

# sy_bounds_malformed LANE — true when BALANCER_BOUNDS names LANE with a value
# this pass could not read. Kept separate from sy_bound so the fallback stays
# silent in the computation and loud in the report.
sy_bounds_malformed() {
  _bm_lane="$1"
  for _bm_entry in ${BALANCER_BOUNDS:-}; do
    case "$_bm_entry" in
      "$_bm_lane"=*) : ;;
      *) continue ;;
    esac
    _bm_spec="${_bm_entry#*=}"
    case "$_bm_spec" in
      *:*) : ;;
      *) return 0 ;;
    esac
    case "${_bm_spec%%:*}" in '' | *[!0-9]*) return 0 ;; esac
    case "${_bm_spec#*:}" in '' | *[!0-9]*) return 0 ;; esac
  done
  return 1
}

# sy_backpressure — the reviewed-but-unmerged depth above which the upstream
# lanes clamp to their floors.
#
# A malformed value takes the default rather than the lane, the same rule
# BALANCER_BOUNDS follows above: a typo in a tuning knob must not be what
# decides whether the factory throttles. The caller reports the fallback.
sy_backpressure() {
  case "${BALANCER_MERGE_BACKPRESSURE:-}" in
    '')            printf '%s' "$DEFAULT_BACKPRESSURE" ;;
    *[!0-9]*)      printf '%s' "$DEFAULT_BACKPRESSURE" ;;
    *)             printf '%s' "$BALANCER_MERGE_BACKPRESSURE" ;;
  esac
}

# sy_backpressure_malformed — true when the knob is set to something this pass
# could not read. Split from sy_backpressure so the fallback stays silent in
# the computation and loud in the report.
sy_backpressure_malformed() {
  case "${BALANCER_MERGE_BACKPRESSURE:-}" in
    '')       return 1 ;;
    *[!0-9]*) return 0 ;;
    *)        return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Capacity
# ---------------------------------------------------------------------------

# sy_lane_max RIG LANE AGENTS_JSON — the lane agent's resolved
# max_active_sessions, or empty when it cannot be read.
#
# FAILS CLOSED, and the empty answer is load-bearing: this value is the cap the
# criterion says a target may never exceed, so a lane whose capacity is unknown
# gets no target at all rather than an unbounded one. `.pool.max` first, then
# `max_active_sessions`, matching how pool-spawn and review-sweep each resolve
# their own ceiling — a city patch is then honoured without a second knob.
#
# A name matching zero or several agents is unreadable rather than a guess: two
# records for one qualified name mean the roster is ambiguous, and picking one
# would publish a target for a capacity that may not be the one that applies.
sy_lane_max() {
  _lm_rig="$1"; _lm_lane="$2"; _lm_raw="$3"
  [ -n "$_lm_raw" ] || return 1
  _lm_val="$(printf '%s' "$_lm_raw" | jq -r --arg q "$_lm_rig/$SY_NS.$_lm_lane" '
    [(if type=="array" then . else (.agents // []) end)[]
      | select((.qualified_name // .name // "") == $q)] as $m
    | if ($m|length) != 1 then empty
      else ($m[0] | ((.pool.max) // .max_active_sessions // empty)
        | select(type=="number" and floor==. and .>=0 and .<=10000))
      end' 2>/dev/null | head -n1)"
  case "${_lm_val:-}" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s' "$_lm_val"
}

# ---------------------------------------------------------------------------
# Demand
# ---------------------------------------------------------------------------

# sy_demand_brakeman PROJECT TOKEN — claimable beads waiting in the rig's cloud
# pool. Empty when the pool cannot be read.
#
# `limit=1` because only the COUNT is wanted: `total` is the pool's full depth
# regardless of the page size, so a one-row page answers the question without
# dragging the whole queue over the wire every cycle.
sy_demand_brakeman() {
  _db_body="$(sy_api_get "/api/v1/projects/$1/pool?limit=1" "$2")"
  [ -n "$_db_body" ] || return 1
  _db_n="$(printf '%s' "$_db_body" | jq -r '
    select(type=="object") | .total
    | select(type=="number" and floor==. and .>=0)' 2>/dev/null | head -n1)"
  case "${_db_n:-}" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s' "$_db_n"
}

# sy_rig_slug RIG — the owner/repo the rig's origin remote points at, or empty.
#
# ONE resolution shared by both forge reads. Two copies of this sed would be two
# chances for the reviewer queue and the backpressure probe to disagree about
# which repository they are counting, which is the one thing that would make the
# clamp fire against the wrong queue.
sy_rig_slug() {
  _rs_slug="$(git -C "$(sy_city)/$1" remote get-url origin 2>/dev/null |
    sed -e 's#.*[:/]\([^/]*/[^/]*\)$#\1#' -e 's#\.git$##')"
  [ -n "$_rs_slug" ] || return 1
  printf '%s' "$_rs_slug"
}

# sy_merge_backlog RIG — the reviewed-but-unmerged depth: open, non-draft pull
# requests against the merge lane's base carrying an APPROVED verdict. Empty
# when the queue cannot be read.
#
# ONLY THE APPROVED ONES. This is the queue the merge lane actually drains, not
# the review lane's own backlog — counting every open PR would read a busy
# review queue as a jammed merge lane and throttle the factory on demand it was
# handling perfectly well. Drafts are excluded for the same reason nobody is
# asked to merge one.
#
# The empty-body/`[]` distinction is the same trap sy_demand_reviewer documents,
# and it bites harder here: an empty read taken as a depth of 0 would silently
# withdraw backpressure at exactly the moment the forge is struggling.
sy_merge_backlog() {
  _mb_slug="$(sy_rig_slug "$1")" || return 1
  _mb_body="$(sy_timeout "$BALANCER_READ_TIMEOUT" gh pr list --repo "$_mb_slug" \
    --base "$BALANCER_MERGE_BASE" --state open \
    --json number,isDraft,reviewDecision --limit 100 2>/dev/null)"
  printf '%s' "$_mb_body" | jq -e 'type=="array"' >/dev/null 2>&1 || return 1
  _mb_n="$(printf '%s' "$_mb_body" | jq -r '
    [ .[]
      | select((.isDraft // false) | not)
      | select((.reviewDecision // "") == "APPROVED")
    ] | length' 2>/dev/null | head -n1)"
  case "${_mb_n:-}" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s' "$_mb_n"
}

# sy_demand_reviewer RIG — open PRs against the review lane's base that carry no
# finished review. Empty when the queue cannot be read.
#
# An EMPTY BODY IS NOT AN EMPTY QUEUE. `gh` prints nothing on failure and `[]`
# on a genuinely empty list, and the two mean opposite things here: one is "do
# not publish a target", the other is "publish zero". Parsing through jq -e
# separates them, so a forge blip cannot read as a drained queue and scale the
# lane to its floor.
sy_demand_reviewer() {
  _dr_slug="$(sy_rig_slug "$1")" || return 1
  _dr_body="$(gh pr list --repo "$_dr_slug" \
    --base "${REVIEW_LANE_BASE:-staging}" --state open \
    --json number --limit 100 2>/dev/null)"
  printf '%s' "$_dr_body" | jq -e 'type=="array"' >/dev/null 2>&1 || return 1
  printf '%s' "$_dr_body" | jq -r 'length'
}

# ---------------------------------------------------------------------------
# The clamp
# ---------------------------------------------------------------------------

# sy_clamp DEMAND FLOOR CEILING MAX — one lane's published target.
#
# ORDER MATTERS, and this is the criterion's sharpest edge. The bounds are the
# operator's preference; max_active_sessions is the capacity the lane actually
# has. So the bounds are applied first and the capacity cap LAST, which is what
# makes a floor set above capacity resolve to capacity rather than to a target
# the lane can never reach. Applying the floor last would publish that
# unreachable number and leave the spawn site chasing it every cycle.
sy_clamp() {
  _c_t="$1"
  [ "$_c_t" -ge "$2" ] || _c_t="$2"
  [ "$_c_t" -le "$3" ] || _c_t="$3"
  [ "$_c_t" -le "$4" ] || _c_t="$4"
  printf '%s' "$_c_t"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

sy_load_conf

# THE OPT-IN GATE. Unset BALANCER_RIGS exits before any read and before any
# write, so an unopted city behaves byte-for-byte as it does today — including
# leaving an existing targets file exactly as it found it. Retiring a stale file
# is the consumers' staleness check, not a deletion here: a balancer that
# deleted on its way out would erase the very evidence an operator needs to see
# why a lane was scaled before it was switched off.
[ -n "${BALANCER_RIGS:-}" ] || exit 0

# Read AFTER sy_load_conf so roster.conf wins. The merge base falls back to the
# merge lane's own key rather than to a second literal, so the balancer and the
# lane it throttles for can never disagree about which branch is under
# discussion when an operator retunes one.
BALANCER_MERGE_BASE="${BALANCER_MERGE_BASE:-${MERGE_LANE_BASE:-staging}}"
BACKPRESSURE="$(sy_backpressure)"

STATE="$(sy_state_dir)"
mkdir -p "$STATE" 2>/dev/null || :
OUT="$STATE/balancer.targets"

# Fetched ONCE per cycle, not per rig: it is a gc invocation, and re-reading it
# per rig would also let a mid-cycle roster change answer differently for two
# rigs in the same sweep.
AGENTS="$(gc agent list --json 2>/dev/null)"
TOKEN="$(sy_api_token 2>/dev/null)"
PROJECTS="$(sy_api_projects "$TOKEN" 2>/dev/null)"

TMP="$(mktemp "$OUT.XXXXXX" 2>/dev/null)" || exit 0
# The temp file is created BESIDE the target, not in /tmp, because the publish
# below is a rename and a rename is only atomic within one filesystem. A temp in
# /tmp would silently degrade to a copy — the half-written read this whole
# mechanism exists to prevent.
trap 'rm -f "$TMP" 2>/dev/null' EXIT INT TERM

notes=""
throttled=""
{
  printf 'version 1\n'
  printf 'generated_at %s\n' "$(date +%s)"
} >"$TMP"

if sy_backpressure_malformed; then
  notes="$notes backpressure(malformed,using-$BACKPRESSURE)"
fi

for rig in $BALANCER_RIGS; do
  project="$(sy_project_for_rig "$rig" "$PROJECTS" 2>/dev/null)" || project=""

  # THE BACKPRESSURE DECISION, made once per rig. It is a property of the stage
  # downstream of both lanes, so asking it per lane would be the same question
  # twice and could answer differently within one cycle.
  #
  # AN UNREADABLE PROBE IS NOT A DEEP QUEUE. Throttling the whole factory to its
  # floors because one `gh` call timed out is the outage this order exists to
  # prevent, so it changes no target and is named in the report instead — the
  # same direction every other unreadable leg here takes.
  throttle=0
  if [ "$BACKPRESSURE" -gt 0 ]; then
    if backlog="$(sy_merge_backlog "$rig")"; then
      if [ "$backlog" -gt "$BACKPRESSURE" ]; then
        throttle=1
        throttled="$throttled $rig($backlog>$BACKPRESSURE)"
      fi
    else
      notes="$notes $rig(backpressure-unreadable)"
    fi
  fi

  for lane in $BALANCE_LANES; do
    if sy_bounds_malformed "$lane"; then
      notes="$notes $rig/$lane(bounds-malformed)"
    fi

    max="$(sy_lane_max "$rig" "$lane" "$AGENTS")" || {
      notes="$notes $rig/$lane(capacity-unreadable)"
      continue
    }

    floor="$(sy_bound "$lane" floor "$DEFAULT_FLOOR")"
    ceiling="$(sy_bound "$lane" ceiling "$max")"

    # A THROTTLED LANE IS NOT MEASURED. Its own demand cannot change the answer
    # once the stage it feeds has stopped draining, so backpressure sends it
    # straight to its floor and the demand reads are skipped rather than taken
    # and discarded — which also spares two forge round-trips per rig in exactly
    # the cycle where the factory is already under strain.
    #
    # The floor is assigned HERE and nowhere else. An earlier draft initialised
    # demand to 0 and relied on the clamp binding upward to the floor, which
    # gives the same number by accident: two mechanisms for one intent, either
    # removable without a test noticing.
    if [ "$throttle" = 1 ]; then
      case "$lane" in brakeman | reviewer) : ;; *) continue ;; esac
      demand="$floor"
    else
      case "$lane" in
        brakeman)
          [ -n "$project" ] || { notes="$notes $rig(unbound)"; continue; }
          demand="$(sy_demand_brakeman "$project" "$TOKEN")" || {
            notes="$notes $rig/$lane(demand-unreadable)"
            continue
          }
          ;;
        reviewer)
          demand="$(sy_demand_reviewer "$rig")" || {
            notes="$notes $rig/$lane(demand-unreadable)"
            continue
          }
          ;;
        *) continue ;;
      esac
    fi

    # Whatever set it, the target goes through the SAME clamp: max_active_sessions
    # beats the floor as surely as it beats the ceiling. Publishing the floor raw
    # would put a target the lane can never reach on the file at exactly the
    # moment the factory is under strain, leaving the spawn site chasing it every
    # cycle until the queue drains.
    target="$(sy_clamp "$demand" "$floor" "$ceiling" "$max")"
    printf 'target %s %s %s\n' "$rig" "$lane" "$target" >>"$TMP"
  done
done

# THE PUBLISH. One rename, so a consumer reading concurrently sees either the
# whole previous generation or the whole new one. It also replaces rather than
# appends: two targets for one (rig, lane) would be a file whose meaning depends
# on which line the reader stopped at.
if mv "$TMP" "$OUT" 2>/dev/null; then
  trap - EXIT INT TERM
else
  rm -f "$TMP" 2>/dev/null
  printf 'balance-sweep: could not publish %s\n' "$OUT" >&2
  exit 0
fi

printf 'balance-sweep: published %s%s%s\n' "$OUT" \
  "${throttled:+ — backpressure:$throttled}" "${notes:+ — skipped:$notes}"
