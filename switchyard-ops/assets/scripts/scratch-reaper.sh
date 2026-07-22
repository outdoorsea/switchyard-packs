#!/bin/sh
# scratch-reaper: report orphaned gc-scratch directories at the CITY ROOT. When a
# formula runs `gc` from the wrong cwd, gc creates a stunted .gc/ there (seen:
# mol-dog-* leaving gff-<bead>[-<formula>]/ dirs, each holding only .gc/). They are
# not worktrees and hold no data (no Dolt store) — just session scratch — but they
# pile up as clutter. stray-reaper reports stray SESSIONS; this reports stray
# gc-SCRATCH dirs. Same invariant: a leftover becomes mail to the mayor.
#
# Signature (city-agnostic): a root dir with a .gc/ but no .git/ — rig checkouts
# have .git and are excluded; config/compiled dirs have no .gc/.
#
# Report-only by default. SCRATCH_REAPER_PRUNE=1 also removes the ones whose ONLY
# top-level entry is .gc/ (guaranteed no build/work artifacts); anything with
# extra content is reported, never deleted. SCRATCH_REAPER_ONLY=<dir> narrows the
# sweep to a single city-root directory — the form the report hands back, so a
# human acts on one candidate through the gates instead of a blanket rm -rf.
set -u

. "$(dirname "$0")/../lib/roster.sh"

# Absolute path to this script, resolved BEFORE the cd below, so the report can
# hand back a command that runs from anywhere.
SELF="$0"
case "$SELF" in
/*) ;;
*) SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
esac

CITY="$(sy_city)"
PRUNE="${SCRATCH_REAPER_PRUNE:-0}"

# Optional single-candidate scope. Accepts the bare name the report prints, and
# tolerates a trailing slash or a full path pasted back.
ONLY="${SCRATCH_REAPER_ONLY:-}"
ONLY="${ONLY%/}"
case "$ONLY" in
"$CITY"/*) ONLY="${ONLY#"$CITY"/}" ;;
esac

cd "$CITY" 2>/dev/null || exit 0

# --- live-session gate (switchyard PRD #175) --------------------------------
#
# A "directory whose only entry is .gc/" is ALSO the exact shape of a healthy,
# running agent's work_dir — an ephemeral session derives its work_dir from its
# scope root, so a city-scoped agent lands directly in the city root. Without
# this gate the sweep listed the working directory of a live session under
# "SAFE TO REMOVE" (observed in gc-fremont-fresh, six processes cwd'd inside).
#
# The authoritative signal is the session RECORD, not process state: gc stores a
# session's directory on its session bead as `gc.work_dir`, and `gc session list`
# projects it. Until that bead closes, the session owns its directory — an asleep
# session holds nothing open yet must never be collected. Only the work_dir of a
# CLOSED session bead is a candidate at all.
#
# Fail CLOSED: if the session records can't be read we cannot prove a directory
# is dead, so it is reported unverified rather than offered for removal. One
# uncollected directory is cheap; one deleted live agent is not.
sessions=""            # "<work_dir>\t<session>" per line — open session beads only
sessions_unavailable=""

# A lookup can also fail by NOT RETURNING. `gc session list` reads the city's
# store, and a wedged store makes it block rather than exit non-zero — so an
# unbounded `$(gc ...)` hangs the whole sweep, and the directories this gate
# exists to protect get no verdict, no report, and no mail at all. That is a
# lookup that "cannot be completed" just as much as a parse failure is, so it
# must land in the same fail-closed path: bound the call and treat the timeout
# as unavailable. 30s is far above a healthy list and far below the sweep's
# cadence; hitting it costs one uncollected directory.
SESSION_LOOKUP_TIMEOUT="${SCRATCH_REAPER_SESSION_TIMEOUT:-30}"

# sy_session_dirs — emit the tab-separated (work_dir, session) pairs of every
# session whose bead is NOT closed. Non-zero exit = the lookup failed.
sy_session_dirs() {
  command -v jq >/dev/null 2>&1 || return 1
  # --state all + an explicit `closed` filter, so a state this gc spells
  # differently (asleep/suspended/quarantined) can never be read as collectable;
  # fall back to the default listing for a gc without --state.
  #
  # Discard the output of any non-zero probe (`|| _raw=""`): a timeout kills gc
  # mid-write, and truncated JSON must never be parsed as a partial session
  # list — half a roster reads as "these sessions don't exist", i.e. as license
  # to delete them.
  _raw="$(sy_timeout "$SESSION_LOOKUP_TIMEOUT" gc session list --json --state all 2>/dev/null)" || _raw=""
  if ! printf '%s\n' "$_raw" | jq -e '(.ok != false) and ((.sessions|type) == "array")' >/dev/null 2>&1; then
    _raw="$(sy_timeout "$SESSION_LOOKUP_TIMEOUT" gc session list --json 2>/dev/null)" || _raw=""
    printf '%s\n' "$_raw" | jq -e '(.ok != false) and ((.sessions|type) == "array")' >/dev/null 2>&1 || return 1
  fi
  printf '%s\n' "$_raw" | jq -r '
    .sessions[]
    | select((.closed // false) | not)
    | select((.work_dir // "") != "")
    | [.work_dir, (.name // .agent_name // .session_name // .id // "unknown")]
    | @tsv' 2>/dev/null || return 1
}

sessions="$(sy_session_dirs)" || sessions_unavailable=1

# sy_live_owner DIR — print the owning session when DIR is (or contains) the
# work_dir of an open session; print nothing otherwise. Containment counts: a
# session rooted one level down still makes the parent live.
sy_live_owner() {
  _plain="$CITY/$1"
  _phys="$(cd "$1" 2>/dev/null && pwd -P)"
  printf '%s\n' "$sessions" | awk -F'\t' -v plain="$_plain" -v phys="$_phys" '
    $1 == "" { next }
    {
      if ($1 == plain || index($1, plain "/") == 1) { print $2; exit }
      if (phys != "" && ($1 == phys || index($1, phys "/") == 1)) { print $2; exit }
    }'
}

# sy_prune_dir DIR — remove DIR, but only if EVERY gate still holds at this
# instant. The scan-time verdict is deliberately NOT trusted here: the session
# roster is re-read and the shape/contents re-tested immediately before the rm,
# so a directory that has become a live session's work_dir since the scan is
# refused, not deleted. Fail closed — an unreadable roster refuses the removal.
# Prints the outcome: ok | gone | failed | "live <owner>" | "content <entries>" |
# unverified.
sy_prune_dir() {
  _d="$1"
  [ -d "$_d" ] && [ -d "$_d/.gc" ] || { printf 'gone\n'; return; }
  if [ -e "$_d/.git" ]; then printf 'content %s\n' '.git'; return; fi

  _fresh="$(sy_session_dirs)" || { printf 'unverified\n'; return; }
  sessions="$_fresh"                       # later candidates get the fresher roster too
  _owner="$(sy_live_owner "$_d")"
  if [ -n "$_owner" ]; then printf 'live %s\n' "$_owner"; return; fi

  _others=$(ls -A "$_d" 2>/dev/null | grep -vxF '.gc')
  if [ -n "$_others" ]; then
    printf 'content %s\n' "$(printf '%s' "$_others" | tr '\n' ' ')"
    return
  fi

  rm -rf -- "$_d" 2>/dev/null || { printf 'failed\n'; return; }
  printf 'ok\n'
}

found=""
guidance=""
pruned=""
kept=""
live=""
unverified=""

for entry in */; do
  d="${entry%/}"
  [ -d "$d" ] || continue
  [ -n "$ONLY" ] && [ "$d" != "$ONLY" ] && continue
  [ -d "$d/.gc" ] || continue      # gc-scratch present
  [ -e "$d/.git" ] && continue     # rig checkout — never touch

  # An open session's work_dir is off limits — never reported removable, never
  # pruned, regardless of what it contains. Checked BEFORE the contents test,
  # because a live work_dir usually holds only .gc/ and so looks collectable.
  if [ -n "$sessions_unavailable" ]; then
    unverified="$unverified
- $d"
    continue
  fi
  owner="$(sy_live_owner "$d")"
  if [ -n "$owner" ]; then
    live="$live
- $d (session: $owner)"
    continue
  fi

  # Is .gc/ the ONLY top-level entry? Then it holds no work/build artifacts.
  others=$(ls -A "$d" 2>/dev/null | grep -vxF '.gc')
  if [ -z "$others" ]; then
    if [ "$PRUNE" != "1" ]; then
      found="$found
- $d"
      guidance="$guidance
  SCRATCH_REAPER_PRUNE=1 SCRATCH_REAPER_ONLY='$d' $SELF"
      continue
    fi
    # Every gate is re-evaluated inside sy_prune_dir, immediately before the rm.
    outcome="$(sy_prune_dir "$d")"
    case "$outcome" in
    ok) pruned="$pruned
- $d" ;;
    gone) : ;;                     # collected or renamed between scan and prune
    live\ *) live="$live
- $d (session: ${outcome#live }; became live after the scan — not removed)" ;;
    content\ *) kept="$kept
- $d (also contains: ${outcome#content })" ;;
    unverified) unverified="$unverified
- $d" ;;
    *) found="$found
- $d"
      guidance="$guidance
  SCRATCH_REAPER_PRUNE=1 SCRATCH_REAPER_ONLY='$d' $SELF" ;;
    esac
  else
    kept="$kept
- $d (also contains: $(printf '%s' "$others" | tr '\n' ' '))"
  fi
done

[ -z "$found$pruned$kept$live$unverified" ] && exit 0

body="Orphaned gc-scratch directories at the city root — a formula ran gc from the wrong cwd and left a stray .gc/. They hold session scratch, not data."
[ -n "$pruned" ] && body="$body

PRUNED (contained only .gc/):$pruned"
[ -n "$found" ] && body="$body

COLLECTABLE AT SCAN TIME (only .gc/, no artifacts):$found
This verdict is already stale by the time you read it — any of these can become a
live session's work_dir before you act, so no blanket delete command is offered.
Remove them one at a time by re-running the reaper, which re-checks every gate
(rig checkout, open session, contents) against the state at that instant and
refuses anything that has since come alive:$guidance
Or sweep every candidate that still qualifies: SCRATCH_REAPER_PRUNE=1 $SELF"
[ -n "$kept" ] && body="$body

KEPT (have other content — review before removing):$kept"
[ -n "$live" ] && body="$body

SKIPPED (live session — the work_dir of a session whose bead is not closed; never removed):$live"
[ -n "$unverified" ] && body="$body

UNVERIFIED (could not read the session records — treated as possibly live, never removed):$unverified"

gc mail send mayor -s "scratch-reaper: orphaned gc-scratch dirs at the city root" -m "$body" >/dev/null 2>&1
exit 0
