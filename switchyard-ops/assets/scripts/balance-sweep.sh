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
# own city.toml ceiling, and the hysteresis rule is a sibling criterion layered
# on top. Keeping the publish step ignorant of it is what lets a consumer treat
# this file as advisory data rather than as a command.
#
# IT ALSO OWNS ITS OWN CLOCK. gc gives an order 60 seconds, and this pass makes
# several forge and controller reads per rig, so it bounds each read AND keeps a
# whole-cycle budget inside that deadline. A cycle that cannot finish abandons
# its publish and names the stages it never measured — see THE CYCLE BUDGET.
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

# How long any ONE external read may take. The `gh` and `gc` reads are wrapped
# in sy_timeout with it; the switchyard reads carry curl's own equivalent inside
# sy_api_get. Same name and default as the sibling measurement pass, so an
# operator retuning read patience moves both rather than discovering a second
# knob.
DEFAULT_READ_TIMEOUT=15

# THE CYCLE BUDGET. gc kills an order at 60 seconds, and bounding each read
# individually does not bound their SUM: one rig costs a backpressure probe plus
# a demand read per lane, and several rigs multiply that. Without a whole-cycle
# bound the pass dies mid-loop and the operator sees only
# `order exec balance-sweep failed: context deadline exceeded` — naming neither
# the rig nor the read, which is the condition this budget exists to replace.
#
# 45 sits deliberately inside the 60s deadline. Affordability is checked as
# elapsed + DEFAULT_READ_TIMEOUT <= budget, NOT as elapsed <= budget, so the
# budget bounds where a read may END rather than where it may begin: the last
# affordable start is 45 - 15 = 30s, and a read taken there runs its bound to
# 45s. The worst case is therefore the budget itself, leaving the remaining 15s
# as headroom under the deadline — raising the budget toward 60 spends exactly
# that headroom. 0 disables the cap for hand-run debugging, matching
# POOL_SPAWN_BUDGET_SECONDS.
DEFAULT_BUDGET=45

# HYSTERESIS: how many CONSECUTIVE cycles a demand signal must persist before
# the target it asks for is actually published. Raising is cheap and reversible;
# losing a worker mid-queue is neither, so the two directions are deliberately
# asymmetric and are NOT operator knobs — the criterion fixes them at 2 and 6,
# and a knob here would let an operator tune the flapping back in.
#
# WHAT COUNTS AS PERSISTING is the DIRECTION, not the exact number. Demand that
# reads 7, 6, 8 against a published 3 is three cycles of the same answer — the
# lane is under-provisioned — and a gate keyed on the exact value would never
# raise under any real load, which is the failure mode of requiring too much
# agreement. The value published when the gate opens is the CURRENT cycle's, not
# the one that opened the streak: it is the freshest measurement available.
RAISE_CYCLES=2
LOWER_CYCLES=6

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

# sy_read_timeout / sy_cycle_budget — the two clock knobs, validated.
#
# Split accessor + _malformed predicate, exactly as the backpressure knob is:
# the fallback stays silent in the computation and loud in the report, because
# a typo in a tuning knob must not take a lane down.
#
# VALIDATION IS LOAD-BEARING HERE, not hygiene. sy_affords does ARITHMETIC on
# both values, and the failure is not a bad answer, it is an aborted cycle:
# $(( )) on a non-numeric string is a fatal shell error, and a LEADING ZERO is
# the case that actually reaches production. `test -gt` reads 08 as decimal 8
# and passes it happily along; $(( )) reads it as octal, where 08 does not
# exist. So a knob that merely looks odd kills the pass mid-loop — the exact
# silent death this budget exists to replace. sy_timeout and pool-spawn's
# sy_pool_bounded_uint reject 0[0-9]* for this same reason.
#
# The upper bound is sy_timeout's own: it refuses anything past 3600, so a
# larger value would not stretch read patience, it would fail EVERY read and
# blind the pass while looking like a forge outage.
sy_bounded_secs() { # VALUE MIN — echoes VALUE when usable, else nothing
  case "$1" in '' | *[!0-9]* | 0[0-9]*) return 1 ;; esac
  [ "$1" -ge "$2" ] 2>/dev/null || return 1
  [ "$1" -le 3600 ] 2>/dev/null || return 1
  printf '%s' "$1"
}

# Minimum 1: sy_timeout treats 0 as unusable and returns 124, so a read timeout
# of 0 would fail every read rather than disable the bound.
sy_read_timeout() {
  sy_bounded_secs "${BALANCER_READ_TIMEOUT:-}" 1 ||
    printf '%s' "$DEFAULT_READ_TIMEOUT"
}

sy_read_timeout_malformed() {
  [ -n "${BALANCER_READ_TIMEOUT:-}" ] || return 1
  sy_bounded_secs "${BALANCER_READ_TIMEOUT:-}" 1 >/dev/null && return 1
  return 0
}

# Minimum 0, because unlike the read timeout 0 is a legitimate setting here: it
# disables the cap. (0 does not match 0[0-9]*, which needs a second digit.)
sy_cycle_budget() {
  sy_bounded_secs "${BALANCE_SWEEP_BUDGET_SECONDS:-}" 0 ||
    printf '%s' "$DEFAULT_BUDGET"
}

sy_cycle_budget_malformed() {
  [ -n "${BALANCE_SWEEP_BUDGET_SECONDS:-}" ] || return 1
  sy_bounded_secs "${BALANCE_SWEEP_BUDGET_SECONDS:-}" 0 >/dev/null && return 1
  return 0
}

# sy_now — current Unix time, or 0 when the clock is unreadable.
sy_now() { date +%s 2>/dev/null || printf '0'; }

# sy_affords SECONDS — can this cycle still start a stage that may cost SECONDS?
#
# Asks about STARTING work rather than about having overspent, which is the
# distinction that makes the budget fit the deadline: a 15s read begun at second
# 44 of a 45s budget is not over budget when it starts and is dead at the
# runner's deadline when it ends. Checking affordability up front is what keeps
# the cycle inside 60s rather than merely noticing afterwards that it was not.
#
# FAILS TOWARD "ALLOWED" on a disabled cap or an unreadable clock, matching
# pool-spawn's sy_pool_budget_allows: a balancer that stopped measuring because
# `date` hiccuped would be a worse outage than the one this guards.
sy_affords() {
  [ "$BUDGET" -gt 0 ] || return 0
  [ "$CYCLE_STARTED" -gt 0 ] || return 0
  _aff_now="$(sy_now)"
  [ "$_aff_now" -gt 0 ] || return 0
  [ "$(( _aff_now - CYCLE_STARTED + $1 ))" -le "$BUDGET" ]
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
  _mb_body="$(sy_timeout "$READ_TIMEOUT" gh pr list --repo "$_mb_slug" \
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
  _dr_body="$(sy_timeout "$READ_TIMEOUT" gh pr list --repo "$_dr_slug" \
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
# Hysteresis
# ---------------------------------------------------------------------------

# sy_hist_load RIG LANE — load the (rig, lane) demand streak into HIST_PREV,
# HIST_DIR and HIST_COUNT. HIST_PREV is empty when the pair has never been
# published, which is the first-publish case.
#
# THE HISTORY FILE, NOT THE TARGETS FILE, REMEMBERS WHAT WAS PUBLISHED, and the
# distinction is load-bearing. A lane whose probe fails writes NO target line at
# all — deliberately, so consumers fall back to their city.toml ceiling — so
# reading the previous target back out of balancer.targets would forget the lane
# after a single unreadable cycle and let the next one apply a raise instantly,
# with the gate silently skipped. Keeping the memory here leaves the published
# file's meaning exactly as the measure-and-clamp pass defined it.
#
# It sets globals rather than printing because a command substitution runs in a
# subshell: three values would have to be re-split by the caller, and a
# malformed line would then be indistinguishable from an absent one.
sy_hist_load() {
  HIST_PREV=""
  HIST_DIR=none
  HIST_COUNT=0
  [ -f "$HIST" ] || return 0
  while read -r _hl_kind _hl_rig _hl_lane _hl_prev _hl_dir _hl_count; do
    [ "$_hl_kind" = hist ] || continue
    [ "$_hl_rig" = "$1" ] || continue
    [ "$_hl_lane" = "$2" ] || continue
    HIST_PREV="$_hl_prev"
    HIST_DIR="$_hl_dir"
    HIST_COUNT="$_hl_count"
    break
  done <"$HIST"

  # A hand-edited or truncated line is treated as NO history rather than as a
  # zero: reverting to first-publish behaviour republishes the measured target,
  # where a zero would read as "we last published 0" and gate a six-cycle
  # climb out of a number nobody ever published.
  case "${HIST_PREV:-}" in '' | *[!0-9]*) HIST_PREV=""; HIST_DIR=none; HIST_COUNT=0 ;; esac
  case "${HIST_COUNT:-}" in '' | *[!0-9]*) HIST_COUNT=0 ;; esac
  return 0
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
READ_TIMEOUT="$(sy_read_timeout)"
BUDGET="$(sy_cycle_budget)"

# WHETHER THE OPERATOR MISTYPED IT IS CAPTURED HERE, BEFORE THE VALUE IS
# NORMALIZED BELOW, because the two are different questions asked of the same
# name: the diagnostic reports what was TYPED, the bound is what is in force.
# Reading the raw knob later would answer the first question with the second
# and silently delete the note telling an operator their value was rejected.
if sy_read_timeout_malformed; then
  READ_TIMEOUT_MALFORMED=1
else
  READ_TIMEOUT_MALFORMED=0
fi

# THE VALIDATED BOUND IS PUBLISHED BACK UNDER THE KNOB'S OWN NAME, and as early
# as possible — before ANY stage runs, not merely before this pass's own loop.
#
# THE CALLER THIS SERVES IS NOT IN THE TREE YET. The sibling six-stage snapshot
# (crit:29c92346d300, branch prd-397-29c92346d300-six-stage-snapshot) bounds its
# forge reads as `sy_timeout "$BALANCER_READ_TIMEOUT"` — the roster knob's own
# name — from its own call sites in THIS file, further down. That criterion is
# unmerged as this lands, so grepping the tree for those call sites finds only
# this comment and its twin in the test: the shim is live-but-unexercised until
# that branch arrives, not dead. Said plainly because the alternative reading —
# that the shim is already load-bearing — is the one a reader would reach for.
#
# sy_timeout treats an empty or non-numeric bound as unusable and returns 124
# WITHOUT running the command, so an unset or mistyped knob would not loosen
# those reads, it would REFUSE them: the stages they feed would report unknown
# on every cycle while the sweep looked healthy. Normalizing at the point the
# bound is decided keeps "every external read carries a bounded timeout" true of
# the whole pass however the passes are later ordered.
#
# KEEPING BOTH NAMES IS THE CHOICE, not a merge artifact. After the sibling
# lands this file holds READ_TIMEOUT (this pass's internal name) and
# BALANCER_READ_TIMEOUT (the roster knob callers name), both live and kept equal
# here. The alternative — have the sibling adopt READ_TIMEOUT when it rebases
# and drop this line — couples a co-resident pass to an internal name it has no
# reason to know, and would silently unbind its reads the day that name changes.
# One line of aliasing is the cheaper half of that trade.
#
# THE ASSIGNMENT IS THE LOAD-BEARING HALF: those call sites are in this same
# shell, so the plain assignment is what binds them. The export adds only
# descendants that shell out — no current child reads this knob, so it is
# belt-and-braces rather than the mechanism.
BALANCER_READ_TIMEOUT="$READ_TIMEOUT"
export BALANCER_READ_TIMEOUT

# A READ TIMEOUT ABOVE THE WHOLE BUDGET IS A CONFIG FAULT, and a fault must FAIL
# rather than slip out as a quiet success. No read would ever be affordable, so
# every stage would be skipped and no target published — on every cycle, for
# ever. Under the order runner an exit 0 with no publish is indistinguishable
# from a healthy quiet cycle, so a silent exit here would park the balancer with
# nothing to escalate. Same rule, and the same reasoning, as pool-spawn's config
# faults. Checked BEFORE the temp file exists, so a refused cycle cannot disturb
# the generation the consumers are already reading.
if [ "$BUDGET" -gt 0 ] && [ "$READ_TIMEOUT" -gt "$BUDGET" ]; then
  printf 'balance-sweep: config fault: BALANCER_READ_TIMEOUT (%ss) exceeds BALANCE_SWEEP_BUDGET_SECONDS (%ss) — no read could ever fit the cycle budget, so no target could ever be published; refusing to run\n' \
    "$READ_TIMEOUT" "$BUDGET" >&2
  exit 1
fi

# Started before the first read, so every external read this cycle makes is
# inside the budget it is measured against.
CYCLE_STARTED="$(sy_now)"

STATE="$(sy_state_dir)"
mkdir -p "$STATE" 2>/dev/null || :
OUT="$STATE/balancer.targets"
HIST="$STATE/balancer.history"
LOG="$STATE/balancer.log"

# Fetched ONCE per cycle, not per rig: it is a gc invocation, and re-reading it
# per rig would also let a mid-cycle roster change answer differently for two
# rigs in the same sweep.
AGENTS="$(sy_timeout "$READ_TIMEOUT" gc agent list --json 2>/dev/null)"
TOKEN="$(sy_api_token 2>/dev/null)"
PROJECTS="$(sy_api_projects "$TOKEN" 2>/dev/null)"

TMP="$(mktemp "$OUT.XXXXXX" 2>/dev/null)" || exit 0
HTMP="$(mktemp "$HIST.XXXXXX" 2>/dev/null)" || { rm -f "$TMP" 2>/dev/null; exit 0; }
LTMP="$(mktemp "$LOG.XXXXXX" 2>/dev/null)" || { rm -f "$TMP" "$HTMP" 2>/dev/null; exit 0; }
# The temp file is created BESIDE the target, not in /tmp, because the publish
# below is a rename and a rename is only atomic within one filesystem. A temp in
# /tmp would silently degrade to a copy — the half-written read this whole
# mechanism exists to prevent.
trap 'rm -f "$TMP" "$HTMP" "$LTMP" 2>/dev/null' EXIT INT TERM

notes=""
throttled=""
decided=""

# The cycle stamp is captured ONCE and used twice: it stamps the published file
# and it is what each log entry cites as the snapshot that justified the change.
# Re-reading the clock for the log would let an entry name a generation that was
# never published, which is precisely the correlation the citation exists for.
CYCLE="$(date +%s)"

# Stages the budget stopped this cycle from measuring. Kept apart from `notes`
# because they mean something categorically different: a note reports a stage
# that WAS measured and could not be read, while this reports one that was never
# attempted — and only the latter abandons the publish.
skipped=""
over_budget=0
{
  printf 'version 1\n'
  printf 'generated_at %s\n' "$CYCLE"
} >"$TMP"

if sy_backpressure_malformed; then
  notes="$notes backpressure(malformed,using-$BACKPRESSURE)"
fi

if [ "$READ_TIMEOUT_MALFORMED" = 1 ]; then
  notes="$notes read-timeout(malformed,using-$READ_TIMEOUT)"
fi

if sy_cycle_budget_malformed; then
  notes="$notes cycle-budget(malformed,using-$BUDGET)"
fi

for rig in $BALANCER_RIGS; do
  # THE RIG'S FIRST READ IS THE BACKPRESSURE PROBE, so the whole rig is gated
  # here rather than at that probe. `continue` and not `break`: every remaining
  # rig fails this same check, and naming each one is the difference between a
  # report an operator can act on and a truncated list they have to guess past.
  if ! sy_affords "$READ_TIMEOUT"; then
    over_budget=1
    skipped="$skipped $rig(budget)"
    continue
  fi

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
      # Gated only on THIS branch. A throttled lane takes its floor without
      # reading anything, so charging it against a read budget would skip work
      # that costs nothing — and would do it precisely when the factory is
      # already under strain.
      if ! sy_affords "$READ_TIMEOUT"; then
        over_budget=1
        skipped="$skipped $rig/$lane(budget)"
        continue
      fi
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

    # THE HYSTERESIS GATE. The clamp above says where the lane SHOULD be; this
    # says whether it has been asking long enough to be moved there. A raise
    # needs RAISE_CYCLES consecutive cycles, a lower LOWER_CYCLES, and a
    # suppressed change republishes the previous target unchanged rather than
    # dropping the line — a dropped line means "unreadable" to the consumers,
    # which would spend the lane's ceiling every time the gate merely held.
    sy_hist_load "$rig" "$lane"
    published="$target"
    ndir=none
    ncount=0
    changed=0
    reason=""

    if [ "$throttle" = 1 ]; then
      # BACKPRESSURE IS AN OVERRIDE, NOT A DEMAND SIGNAL, so the gate does not
      # apply to it. This pass states above that a throttled lane is not
      # measured; with no demand read there is nothing to persist, and the gate
      # is defined over exactly that signal. Making the clamp wait six cycles
      # would leave the factory producing into a jammed merge stage for half an
      # hour — the backpressure rule undone by the smoothing rule.
      reason=backpressure
      [ "${HIST_PREV:-}" = "$target" ] || changed=1
    elif [ -z "$HIST_PREV" ]; then
      # Nothing was ever published for this pair, so there is no change to damp.
      reason=first-publish
      changed=1
    elif [ "$target" = "$HIST_PREV" ]; then
      # The lane is where it should be. Any part-built streak is spent: the
      # signal that opened it is no longer being made.
      published="$HIST_PREV"
    elif [ "$target" -gt "$HIST_PREV" ]; then
      if [ "$HIST_DIR" = up ]; then ncount=$((HIST_COUNT + 1)); else ncount=1; fi
      if [ "$ncount" -ge "$RAISE_CYCLES" ]; then
        reason="raise-after-${ncount}c"
        changed=1
        ndir=none
        ncount=0
      else
        published="$HIST_PREV"
        ndir=up
      fi
    else
      if [ "$HIST_DIR" = down ]; then ncount=$((HIST_COUNT + 1)); else ncount=1; fi
      if [ "$ncount" -ge "$LOWER_CYCLES" ]; then
        reason="lower-after-${ncount}c"
        changed=1
        ndir=none
        ncount=0
      else
        published="$HIST_PREV"
        ndir=down
      fi
    fi

    printf 'target %s %s %s\n' "$rig" "$lane" "$published" >>"$TMP"
    printf 'hist %s %s %s %s %s\n' "$rig" "$lane" "$published" "$ndir" "$ncount" >>"$HTMP"
    decided="$decided $rig/$lane"

    # ONLY AN APPLIED CHANGE IS LOGGED. Recording every cycle would make "every
    # target change is logged" unfalsifiable — the entry an operator needs is
    # the one that moved a lane, next to the reading that moved it.
    if [ "$changed" = 1 ]; then
      printf '%s %s %s %s -> %s reason=%s snapshot=cycle:%s demand=%s floor=%s ceiling=%s max=%s\n' \
        "$CYCLE" "$rig" "$lane" "${HIST_PREV:-none}" "$published" "$reason" \
        "$CYCLE" "$demand" "$floor" "$ceiling" "$max" >>"$LTMP"
    fi
  done
done

# AN OVER-BUDGET CYCLE PUBLISHES NOTHING. Targets accumulate in the temp file
# lane by lane, so a cycle that stopped early and published anyway would ship a
# PARTIAL generation — and to a consumer a missing lane line does not read as
# "unknown", it reads as "fall back to your city.toml ceiling". A truncated file
# would therefore silently un-scale every lane the cycle never reached, which is
# a louder change than publishing nothing at all. The previous generation stands
# instead, and goes stale on its own timestamp if this repeats.
#
# Over budget means at least one stage was SKIPPED: the flag is set only where a
# stage was passed over, never merely because the clock ran on. A cycle that
# measured every stage publishes, however long it took — there is nothing left
# it could have skipped, and the publish itself is a rename.
#
# THE STREAK HISTORY IS LEFT EXACTLY AS IT WAS, for the same reason. $HIST is
# only ever replaced by the rename below, so abandoning here leaves the previous
# generation's streaks standing whole — which is what the hysteresis gate wants:
# a cycle that measured nothing is not evidence that demand moved, and letting it
# reset the streaks would reopen the gate on a reading that never happened.
#
# CHECKED BEFORE THE CARRY-FORWARD BELOW, so an abandoned cycle does not spend
# the pass rebuilding a history it is about to delete. $HTMP and $LTMP are
# removed here with $TMP: the trap is cleared on the next line, so anything left
# behind would be left for good, beside $HIST and $LOG in the state dir rather
# than in /tmp. An over-budget cycle is by definition the repeating condition.
if [ "$over_budget" = 1 ]; then
  rm -f "$TMP" "$HTMP" "$LTMP" 2>/dev/null
  trap - EXIT INT TERM
  printf 'balance-sweep: hit its %ss cycle budget and published no targets — the previous generation stands. Not measured:%s. This bound belongs to the order itself and sits deliberately inside the 60s gc order-exec deadline, so this notice replaces the silent "order exec balance-sweep failed: context deadline exceeded" that would otherwise name neither rig nor read. Raise BALANCE_SWEEP_BUDGET_SECONDS, lower BALANCER_READ_TIMEOUT, or investigate which read is slow.%s\n' \
    "$BUDGET" "$skipped" "${notes:+ — also unreadable:$notes}" >&2
  exit 0
fi

# A PAIR THIS CYCLE DID NOT DECIDE KEEPS ITS STREAK. A lane skipped for an
# unreadable probe, a rig dropped from BALANCER_RIGS for one cycle, a lane whose
# capacity could not be read: none of those is a demand signal, and rewriting
# the history without them would silently reset the gate every time the forge
# hiccuped. The whole file is rebuilt each cycle, so what is not carried here is
# forgotten.
if [ -f "$HIST" ]; then
  while read -r _cf_kind _cf_rig _cf_lane _cf_rest; do
    [ "$_cf_kind" = hist ] || continue
    [ -n "$_cf_rest" ] || continue
    case " $decided " in *" $_cf_rig/$_cf_lane "*) continue ;; esac
    printf 'hist %s %s %s\n' "$_cf_rig" "$_cf_lane" "$_cf_rest" >>"$HTMP"
  done <"$HIST"
fi

# THE PUBLISH. One rename, so a consumer reading concurrently sees either the
# whole previous generation or the whole new one. It also replaces rather than
# appends: two targets for one (rig, lane) would be a file whose meaning depends
# on which line the reader stopped at.
#
# THE STREAK AND THE LOG FOLLOW THE PUBLISH, and only a successful one. An
# advanced streak behind a failed rename would count cycles against a generation
# no consumer ever read — the gate would open on evidence that never existed —
# and a log entry for it would describe a target change that did not happen.
# Leaving the old history in place instead costs at most a repeated cycle.
if mv "$TMP" "$OUT" 2>/dev/null; then
  trap - EXIT INT TERM
  mv "$HTMP" "$HIST" 2>/dev/null || rm -f "$HTMP" 2>/dev/null
  if [ -s "$LTMP" ]; then
    cat "$LTMP" >>"$LOG" 2>/dev/null || :
  fi
  rm -f "$LTMP" 2>/dev/null
else
  rm -f "$TMP" "$HTMP" "$LTMP" 2>/dev/null
  printf 'balance-sweep: could not publish %s\n' "$OUT" >&2
  exit 0
fi

printf 'balance-sweep: published %s%s%s\n' "$OUT" \
  "${throttled:+ — backpressure:$throttled}" "${notes:+ — skipped:$notes}"
