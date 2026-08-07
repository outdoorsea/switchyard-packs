#!/bin/sh
# build-launch: the ONE launch path for a `sy-build-from-prd` factory run, with
# the double-launch guard fused into it (switchyard PRD #269, crit:f18752fdb362).
#
# WHY THIS EXISTS. A factory run claims a PRD's pool beads under lease, mints a
# convoy, and drains them in parallel worktrees. Launching a SECOND run for a PRD
# that already has one running is not a harmless duplicate: the two runs race for
# the same pool beads, so one of them loses every claim it tries to take and
# drains nothing, while both mint convoys and both spend tokens. The lease is
# per-`claimed_by` (one identity per bead), so the loser does not even fail
# loudly — it reads a busy pool and idles. A duplicate run is therefore an
# expensive silent no-op, which is exactly the failure this guard exists to make
# impossible.
#
# GUARD AND LAUNCH ARE ONE COMMAND, DELIBERATELY. An advisory guard — a separate
# "check first" step a caller is asked to run — is a guard that gets skipped the
# first time someone is in a hurry, and skipping it leaves no trace. Fusing the
# check to the launch means there is no way to start a factory run that does not
# pass the guard: the check is not a step before the launch, it IS the launch.
#
# FAIL CLOSED, AND WHY THAT DIRECTION. When run state cannot be determined this
# script REFUSES to launch (exit 4) rather than launching on an unreadable
# ledger. The two errors are not symmetrical: refusing a legitimate launch costs
# one cycle's delay and says so on stdout, while a duplicate launch burns a full
# parallel drain and corrupts the lease picture. switchyard-ops already has the
# scar that proves the point in the other direction — lane-ensure's "is one
# already running?" guard failed OPEN on an unreadable roster, and spawned an
# extra session every sweep forever: 18 live judges against a max of 1, 139
# registered sessions. A guard that cannot confirm absence must not act.
#
# WHAT COUNTS AS AN ACTIVE RUN. The launcher stamps a deterministic RUN TAG into
# the run's root bead title, and the guard looks for that same tag on any bead
# the rig ledger still considers unfinished. The tag is bracketed —
# `[sy-build/prd-269]` — because an unbracketed `sy-build/prd-26` is a prefix of
# `sy-build/prd-269`, so a substring match on the bare form would let PRD 26's
# run block PRD 269's. The brackets make the match exact without needing a word
# boundary regex that `jq`'s `contains` does not offer.
#
# The tag rides the TITLE because that is the only field `gc sling` can stamp
# deterministically through its supported CLI: it takes `-t/--title`, and has no
# `--metadata` flag. The launch also passes `--scope-kind prd --scope-ref <id>`,
# gc's own logical-scope labelling for a v2 formula launch, so the run is
# correctly labelled for anything that later learns to query scope directly; the
# guard does not read it back, because no `gc` read surface exposes it today and
# a guard must not depend on a field it cannot verify.
#
# NO STATE FILE, SO NOTHING GOES STALE. "Active" is derived from the LIVE ledger
# every time, never from a marker this script wrote. That is what keeps the guard
# from becoming a permanent lockout: when a run finishes — or dies and its beads
# are closed — the tag stops matching an unfinished bead and the PRD is
# launchable again, with no cleanup step to forget and no marker to reap. A
# guard whose only failure mode is "refuses while the run is genuinely alive" is
# the correct shape; one that can refuse forever is worse than none.
#
# CONTRACT — the exit codes are the interface, and each is a DIFFERENT answer.
# "No run is active" and "I could not tell" must never share a code, the same
# rule roster.sh's sy_live_session_for documents: a caller that conflates them
# retries a launch that should have escalated.
#
#   0  launched      — no active run for this PRD; the sling was dispatched
#   3  REFUSED       — an active factory run for this PRD already exists
#   4  REFUSED       — run state is UNKNOWN (unreadable/unparseable ledger)
#   2  usage error   — bad or missing arguments; nothing was read or launched
#   1  launch failed — the guard passed but `gc sling` itself returned non-zero
#
# Usage:  build-launch.sh <rig> <prd-id> [target]
#
#   target defaults to $SY_BUILD_TARGET. There is deliberately NO built-in
#   default: routing a formula to the wrong target is not a recoverable mistake,
#   and this script has no way to verify a guess. A caller that knows its build
#   target passes it; one that does not gets a usage error rather than a run
#   dispatched somewhere arbitrary.
set -u

. "$(dirname "$0")/../lib/roster.sh"

# The formula a factory run instantiates. Overridable so the self-test can drive
# the real code path without depending on the formula being installed.
SY_BUILD_FORMULA="${SY_BUILD_FORMULA:-sy-build-from-prd}"

# Bead states that mean a run is STILL GOING. `closed` is deliberately absent —
# a finished run must not block the next one (see NO STATE FILE above).
#
# `blocked` and `deferred` count as active on purpose: a wedged or parked run
# still owns its convoy and its leases, so starting a second one against the
# same beads is the very race this guard prevents. The remedy for a wedged run
# is to resolve or close it, not to launch a rival past it.
#
# Comma-separated in ONE flag: `gc bd list` silently OVERWRITES on a repeated
# `--status`, so the repeated-flag spelling would quietly narrow the query to
# whichever status came last — pr-gate.sh documents the same trap.
SY_BUILD_ACTIVE_STATUSES="open,in_progress,blocked,deferred"

# sy_build_run_tag PRD — the exact, bracketed token that marks a run's root bead
# as belonging to PRD's factory run. Single source of truth: the launcher stamps
# it and the guard matches it, so the two can never drift apart.
sy_build_run_tag() {
  printf '[sy-build/prd-%s]' "$1"
}

# sy_build_run_title PRD — the run root bead's title. Carries the machine-matched
# tag first and human prose after, so `gc bd list` output stays readable.
sy_build_run_title() {
  printf '%s switchyard-build factory run for PRD %s' "$(sy_build_run_tag "$1")" "$1"
}

# sy_build_run_active RIG PRD — is a factory run for PRD already going on RIG?
#
#   rc=0  ACTIVE  — an unfinished bead carries this PRD's run tag
#   rc=1  CLEAR   — the ledger was read and parsed, and holds no such bead
#   rc=2  UNKNOWN — the ledger could not be read or parsed
#
# rc=2 is a distinct answer, not a flavour of CLEAR. The caller refuses on it.
# Both `gc` failing and `jq` rejecting the payload land here: an empty string and
# a malformed one are equally "I could not tell", and neither is evidence of
# absence. Note the explicit `jq -e .` parse check BEFORE the query — a bare
# query pipeline would turn malformed JSON into an empty result set, which is
# indistinguishable from a genuinely empty ledger and would fail OPEN.
sy_build_run_active() {
  _sbra_raw="$(gc bd list --rig "$1" --status "$SY_BUILD_ACTIVE_STATUSES" --json 2>/dev/null)" \
    || return 2
  [ -n "$_sbra_raw" ] || return 2
  printf '%s' "$_sbra_raw" | jq -e . >/dev/null 2>&1 || return 2

  _sbra_n="$(printf '%s' "$_sbra_raw" | jq -r --arg tag "$(sy_build_run_tag "$2")" '
    [ (if type=="array" then . else (.beads // []) end)[]
      | select(((.title // "") | contains($tag))
               or ((.metadata["sy.build.run"] // "") == $tag))
    ] | length' 2>/dev/null)"

  # A count that is not a number means the query itself did not run cleanly —
  # UNKNOWN, never "none found".
  case "$_sbra_n" in ''|*[!0-9]*) return 2 ;; esac
  [ "$_sbra_n" -gt 0 ]
}

# --- main ---------------------------------------------------------------------

rig="${1:-}"
prd="${2:-}"
target="${3:-${SY_BUILD_TARGET:-}}"

if [ -z "$rig" ] || [ -z "$prd" ]; then
  echo "usage: build-launch.sh <rig> <prd-id> [target]   (or set SY_BUILD_TARGET)" >&2
  exit 2
fi

# The PRD id indexes a tag that is matched by substring, so a non-numeric value
# could smuggle bracket characters into the tag and match the wrong run. Reject
# anything that is not a plain number rather than sanitising it.
case "$prd" in ''|*[!0-9]*)
  echo "build-launch: PRD id must be numeric, got '$prd'" >&2
  exit 2 ;;
esac

if [ -z "$target" ]; then
  echo "build-launch: no sling target — pass one as the 3rd argument or set SY_BUILD_TARGET" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || {
  echo "build-launch: REFUSED — jq is not on PATH, so run state is UNKNOWN" >&2
  exit 4
}

sy_build_run_active "$rig" "$prd"
case $? in
  0)
    # The guard firing is the SUCCESS case for this order's purpose, so it says
    # so plainly on stdout and exits non-zero for the caller's branch. It is not
    # an error to be escalated: a coordinator that asks twice in one cycle is
    # exactly who this is for.
    echo "build-launch: REFUSED — PRD $prd already has an active factory run on $rig $(sy_build_run_tag "$prd"); not launching a second one"
    exit 3 ;;
  2)
    echo "build-launch: REFUSED — could not determine whether PRD $prd has an active factory run on $rig (ledger unreadable); refusing rather than risk a duplicate launch" >&2
    exit 4 ;;
esac

# Clear to launch. `--scope-kind/--scope-ref` label the workflow with its logical
# PRD scope; `-t` carries the run tag the guard above matches on.
if gc sling "$target" "$SY_BUILD_FORMULA" --formula \
     -t "$(sy_build_run_title "$prd")" \
     --var prd_id="$prd" \
     --scope-kind prd --scope-ref "$prd" \
     >/dev/null 2>&1; then
  echo "build-launch: launched $SY_BUILD_FORMULA for PRD $prd on $rig -> $target $(sy_build_run_tag "$prd")"
  exit 0
fi

echo "build-launch: launch FAILED — gc sling returned non-zero for PRD $prd on $rig -> $target" >&2
exit 1
