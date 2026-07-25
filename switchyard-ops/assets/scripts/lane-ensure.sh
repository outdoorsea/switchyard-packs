#!/bin/sh
# lane-ensure AGENT SUBJECT — keep exactly one live session of the switchyard-ops
# agent AGENT alive for each rig that drives a switchyard project.
#
# This is the shared spawner behind the self-directed lanes — agents whose queue
# is switchyard's (read over the MCP inside the session), not the gc bead ledger,
# so there is no demand bead to detect and no hand-off to make. Its whole job is
# "ensure a <AGENT> is running for each rig that has a coordinator"; the session
# itself reads its switchyard queue and exits IDLE when there is nothing to do.
#
#   judge-sweep   -> lane-ensure judge     "judging-validator"
#   answer-sweep  -> lane-ensure answerer   "answerer"
#
# That self-directed model sidesteps the pool-spawn assign bug entirely (sw-xjk):
# there is no bead to hand off, only a session to start.
#
# Judgment lives in the session, not here — agents/<AGENT>/prompt.template.md
# decides WHAT it does; this script only decides WHETHER to start one.
#
# SILENT-FAILURE INVARIANT: a spawn that returns no session identity leaves that
# lane's backlog unowned with nobody watching, so — like pool-spawn — it mails the
# mayor within the cycle. A session already running, or a city with no
# coordinators, is a legitimate quiet state: say nothing.
set -u

AGENT="${1:?lane-ensure: AGENT (e.g. judge) is required}"
SUBJECT="${2:-$AGENT}"          # human label for the escalation mail

. "$(dirname "$0")/../lib/roster.sh"

QUALIFIED="switchyard-ops.$AGENT"

# Session states that count as a live session — mirrors pool-spawn's
# POOL_LIVE_STATES so "is one already running?" is answered the same way pack-wide.
LANE_LIVE_STATES="active start-pending start_pending creating draining"

# LANE_SESSION_ID_JQ — pull a session identity out of whatever `gc session new`
# prints (gc builds vary between a bare session object and a {"session":{...}}
# envelope). A non-JSON answer yields nothing and the caller falls back to a
# plain-text scan. Identical shape to pool-spawn's POOL_SESSION_ID_JQ.
LANE_SESSION_ID_JQ='
  (if type=="object" then (.session // .) else empty end)
  | (.qualified_name // .name // .session_name // .id // .session_id // "")'

# lane_live_count RIG — how many live sessions of this agent RIG already has. A
# readable roster showing none is the only case that spawns; an unreadable or
# non-numeric answer yields nothing (treated as "cannot confirm absent" → no
# spawn), never a false zero that would stack a second session.
lane_live_count() {
  _states_json="$(printf '%s' "$LANE_LIVE_STATES" | jq -Rc 'split(" ")')"
  gc session list --json --state all 2>/dev/null \
    | jq -r --arg q "$1/$QUALIFIED" --argjson live "$_states_json" '
        [ (.sessions // [])[]
          | select( ((.agent // .agent_name // .qualified_name // "") == $q) )
          | select( (.state // "") as $st | ($live | index($st)) != null )
        ] | length' 2>/dev/null \
    | awk 'NF' | head -n1
}

# lane_spawn RIG — spawn ONE adhoc session for RIG and echo its session identity
# (empty when the identity cannot be captured). Uses the exact bare invocation
# pool-spawn/loop-health rely on (`gc session new <agent> --no-attach`, no extra
# flags, so an unknown-flag build cannot silently no-op the spawn) and reads the
# identity back from stdout, with the plain-text fallback accepting only a token
# that begins with `<rig>/`.
lane_spawn() {
  _out="$(gc session new "$1/$QUALIFIED" --no-attach 2>/dev/null)"
  _id="$(printf '%s' "$_out" | jq -r "$LANE_SESSION_ID_JQ" 2>/dev/null | awk 'NF' | head -n1)"
  if [ -z "$_id" ]; then
    _id="$(printf '%s\n' "$_out" | tr ' \t' '\n\n' | awk -v r="$1/" 'index($0,r)==1 {print; exit}')"
  fi
  printf '%s' "$_id"
}

# The rigs to cover are exactly those with a switchyard coordinator (a coordinator
# ⇒ a switchyard project is driven there ⇒ it has a queue for this lane). Derive
# the rig from each coordinator's qualified name and dedupe.
rigs="$(sy_coordinators | sed 's#/.*$##' | awk 'NF' | sort -u)"

# No coordinators is a legitimate state (all rigs suspended, or a fresh city).
[ -n "$rigs" ] || exit 0

failed=""
for rig in $rigs; do
  n="$(lane_live_count "$rig")"
  case "$n" in
    ''|*[!0-9]*) continue ;;      # cannot confirm absent → do not stack a second
    0) : ;;                       # confirmed none live → spawn below
    *) continue ;;                # already running → leave it
  esac

  id="$(lane_spawn "$rig")"
  [ -n "$id" ] && continue        # spawned cleanly → done for this rig
  failed="$failed $rig"           # spawn returned no identity → escalate
done

if [ -n "$failed" ]; then
  gc mail send mayor \
    -s "$AGENT-sweep: could not start a $SUBJECT" \
    -m "\`gc session new <rig>/$QUALIFIED --no-attach\` returned no session identity for:$failed. The $SUBJECT lane for these rigs' switchyard projects has no session running. Check the $AGENT agent is imported into the rig and that switchyard-mcp is available in its session, then re-run or spawn one by hand." \
    >/dev/null 2>&1
fi

exit 0
