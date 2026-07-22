#!/bin/sh
# scratch-reaper: report orphaned gc-scratch directories at the CITY ROOT.
#
# WHAT THEY ARE. Each one is the work_dir of an ephemeral agent session, left
# behind when that session drained. An ephemeral session derives its work_dir
# from its SCOPE ROOT, so an agent scoped to the city (the dog pool) lands
# directly in the city root — creating gff-<bead>[-<formula>]/ there, each
# holding only a .gc/ — and nothing removes that directory when the session
# ends (seen: mol-dog-* leaving ~25 of them). Removing it at drain time is a
# gas-town core change, tracked separately; this sweep contains the symptom.
#
# That origin is the whole reason for the gates below: these directories are
# not the debris of a stray process, they are what a session's working
# directory looks like — and a RUNNING session's work_dir has the identical
# shape. Anything this script proposes for removal is therefore a directory it
# must first prove is nobody's. See the live-session gate further down.
#
# They are not worktrees and hold no data (no Dolt store) — just session
# scratch — but they pile up as clutter. stray-reaper reports stray SESSIONS;
# this reports stray gc-SCRATCH dirs. Same invariant: a leftover becomes mail
# to the mayor.
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

# --- process liveness gate (switchyard PRD #175) -----------------------------
#
# The session roster answers "who OWNS this directory". This answers a different
# question — "is anything actually working inside it right now" — and so covers
# the case the roster cannot: a live process left behind by a session whose bead
# has already closed.
#
# The probe has to be NARROW, and that is the whole difficulty. The first draft
# ran `lsof +D` and read ANY line of output as in-use. But `gc supervisor` leaks
# read-only DIR handles across the entire city root, so once it has scanned,
# every candidate looks busy and the reaper silently collects nothing, for ever.
# That is not a fixed reaper, only a quieter broken one. Exactly two things count
# as use:
#
#   - a process's working directory is the candidate or something below it (the
#     cwd / twd / rtd descriptors), or
#   - a process holds a descriptor on a path STRICTLY DEEPER than the candidate.
#
# A bare handle on the candidate's own directory inode is a scan artifact and
# counts for nothing, however many of them pile up.
LSOF_TIMEOUT="${SCRATCH_REAPER_LSOF_TIMEOUT:-15}"

# sy_dir_users DIR — read lsof output on stdin; print "<command> (pid N)" for the
# first process that genuinely uses DIR, and nothing at all when none does.
#
# Deliberately split from the lsof call: classification is the part that can be
# wrong in a way nobody notices, so it must be exercisable against fixture output
# rather than live process state (scripts/scratch-reaper.test.sh).
sy_dir_users() {
  awk -v dir="$1" '
    $1 == "COMMAND" { next }              # header
    NF < 9 { next }                       # not a file line
    {
      name = $9                           # NAME runs to end of line (paths may hold spaces)
      for (i = 10; i <= NF; i++) name = name " " $i
      deeper = (index(name, dir "/") == 1)
      if (!deeper && name != dir) next
      # A working directory at or below DIR is real use. Any other descriptor
      # counts only when it points strictly deeper — a handle on DIR itself is
      # the leaked read-only scan artifact this gate exists to ignore.
      if ($4 == "cwd" || $4 == "twd" || $4 == "rtd" || deeper) {
        printf "%s (pid %s)\n", $1, $2
        exit
      }
    }'
}

# sy_busy_user DIR — the process working inside DIR, if any.
#
# No lsof (it is absent on plenty of hosts) means this probe contributes no
# signal — NOT that everything is in use. Failing closed here would make the
# reaper a permanent no-op on those hosts, which is the very failure the narrow
# classification above exists to prevent; the authoritative ownership gate is the
# session roster, and that one does fail closed.
#
# lsof's exit status is not a failure signal either — it exits non-zero simply
# because nothing matched — so it is ignored and whatever was printed is parsed.
sy_busy_user() {
  command -v lsof >/dev/null 2>&1 || return 0
  _phys="$(cd "$1" 2>/dev/null && pwd -P)" || return 0
  [ -n "$_phys" ] || return 0
  sy_timeout "$LSOF_TIMEOUT" lsof +D "$_phys" 2>/dev/null | sy_dir_users "$_phys"
}

# sy_prune_dir DIR — remove DIR, but only if EVERY gate still holds at this
# instant. The scan-time verdict is deliberately NOT trusted here: the session
# roster is re-read and the shape/contents re-tested immediately before the rm,
# so a directory that has become a live session's work_dir since the scan is
# refused, not deleted. Fail closed — an unreadable roster refuses the removal.
# Prints the outcome: ok | gone | failed | "live <owner>" | "busy <user>" |
# "content <entries>" | unverified.
sy_prune_dir() {
  _d="$1"
  [ -d "$_d" ] && [ -d "$_d/.gc" ] || { printf 'gone\n'; return; }
  if [ -e "$_d/.git" ]; then printf 'content %s\n' '.git'; return; fi

  _fresh="$(sy_session_dirs)" || { printf 'unverified\n'; return; }
  sessions="$_fresh"                       # later candidates get the fresher roster too
  _owner="$(sy_live_owner "$_d")"
  if [ -n "$_owner" ]; then printf 'live %s\n' "$_owner"; return; fi

  _user="$(sy_busy_user "$_d")"
  if [ -n "$_user" ]; then printf 'busy %s\n' "$_user"; return; fi

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
busy=""
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

  # Nor is a directory a process is working inside — even one no session claims.
  # Checked before the contents test for the same reason: a busy work_dir
  # usually holds only .gc/ and so looks collectable.
  busy_user="$(sy_busy_user "$d")"
  if [ -n "$busy_user" ]; then
    busy="$busy
- $d (in use by: $busy_user)"
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
    busy\ *) busy="$busy
- $d (in use by: ${outcome#busy }; became busy after the scan — not removed)" ;;
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

[ -z "$found$pruned$kept$live$busy$unverified" ] && exit 0

body="Orphaned gc-scratch directories at the city root — work_dirs of ephemeral agent sessions, left behind when the session drained. They hold session scratch, not data."
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
[ -n "$busy" ] && body="$body

SKIPPED (in use — a process is working inside; never removed):$busy"
[ -n "$unverified" ] && body="$body

UNVERIFIED (could not read the session records — treated as possibly live, never removed):$unverified"

gc mail send mayor -s "scratch-reaper: orphaned gc-scratch dirs at the city root" -m "$body" >/dev/null 2>&1
exit 0
