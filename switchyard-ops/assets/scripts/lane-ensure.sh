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
#
# The identity test must accept the ADHOC name, not just the template name. A
# session started by lane_spawn is rostered as `<rig>/<agent>-adhoc-<hash>`
# (that is what `gc session list --json` reports in .agent_name), never the bare
# `<rig>/<agent>`. The original `== $q` therefore matched NOTHING, counted 0
# every cycle, and spawned an extra session every sweep forever: 18 live judges
# at a 1h sweep and 3 answerers at a 6h sweep — a leak rate that tracked the
# cooldown exactly, because the guard never once fired. This is the fail-OPEN
# case the "cannot confirm absent" rule above does not cover: that rule guards an
# UNREADABLE roster, but a confidently-wrong ZERO passes straight through it.
# Suffix is matched as the literal `-adhoc-` rather than a bare prefix so a lane
# named `judge` can never absorb one named `judgement`.
#
# Left the same leak running longer on this city: measured 2026-07-30, 0 reported
# against 20 live judges, which is what drove 139 registered sessions and 111
# concurrent `claude` processes on one credential — the 429 storm.
#
# `.template` is tested FIRST, because it is the field that actually answers the
# question. `gc session list --json` (schema_version 1) reports it on every row
# and it holds the UNSUFFIXED agent name, so matching it needs no knowledge of
# how gc spells an instance suffix and keeps working if that spelling changes
# again:
#   template=<rig>/switchyard-ops.judge   agent_name=<rig>/…judge-adhoc-ae51b3d1
#   template=bd.dog                       agent_name=bd.dog-1
# The agent_name clauses below are a fallback for builds that might omit it.
#
# The second line is why an earlier local fix's extra `sub("-[0-9]+$")` strip is
# NOT carried here: `.template` already resolves the numeric suffix correctly, so
# the strip bought nothing and cost precision — it collapsed a legitimately
# distinct lane named `worker-2` onto `worker`, counting a different lane as live
# and suppressing a spawn that should have happened.
#
# All three clauses fail CLOSED in the same direction: an extra match raises the
# count, which suppresses a spawn. That is the safe side of this particular bug.
lane_live_count() {
  _states_json="$(printf '%s' "$LANE_LIVE_STATES" | jq -Rc 'split(" ")')"
  gc session list --json --state all 2>/dev/null \
    | jq -r --arg q "$1/$QUALIFIED" --argjson live "$_states_json" '
        [ (.sessions // [])[]
          | (.agent // .agent_name // .qualified_name // "") as $n
          | select( (.template // "") == $q
                    or $n == $q
                    or ($n | startswith($q + "-adhoc-")) )
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
  # Plain-text fallback 1 — this gc build answers with a human sentence:
  #   Session gff-wisp-1zvxzd created from template "<rig>/<agent>" (reconciler …)
  # so the SESSION ID is field 2. Prefer it: it is the actual identity, whereas
  # the rig-token fallback below can only ever recover the TEMPLATE name.
  if [ -z "$_id" ]; then
    _id="$(printf '%s\n' "$_out" | awk '/^[Ss]ession [^ ]+ created/{print $2; exit}')"
  fi
  # Plain-text fallback 2 — any token naming the rig. Surrounding punctuation is
  # stripped FIRST: the template name arrives quoted ("<rig>/<agent>"), so the
  # leading double quote put the rig at index 2 and `index($0,r)==1` never
  # matched. Every spawn therefore looked identity-less and mailed the mayor a
  # false silent-failure alert even when the session had started fine.
  if [ -z "$_id" ]; then
    _id="$(printf '%s\n' "$_out" | tr ' \t' '\n\n' \
      | sed 's/^[^A-Za-z0-9_]*//; s/[^A-Za-z0-9_/.-]*$//' \
      | awk -v r="$1/" 'index($0,r)==1 {print; exit}')"
  fi
  printf '%s' "$_id"
}

# The rigs to cover are exactly those where THIS LANE'S OWN AGENT is defined —
# the rig has the switchyard-ops pack imported for this lane, which is what "this
# rig drives a switchyard project and therefore has a queue here" actually means.
#
# It deliberately NO LONGER derives from sy_coordinators. That set is
# `pool.min >= 1`, a LIVENESS-PINNING signal, and this code was reusing it as a
# HAS-A-QUEUE signal. The two diverge, and the divergence was silent and total:
# switchyard's own rig runs its conductor on demand (`pool.min: 0`), so it was
# absent from every judge and answer sweep ever run, while carrying the largest
# validation backlog in the city (34 unvalidated criteria, oldest 24 days). The
# sweep reported success throughout, because a rig that is never in `rigs` is
# never checked and so can never fail. A rig may legitimately have a lane queue
# with no pinned coordinator; having the lane's agent is the honest test.
lane_rigs() {
  gc agent list --json 2>/dev/null \
    | jq -r --arg q "$QUALIFIED" '(if type=="array" then . else (.agents // []) end)
             | .[]
             | select((.suspended // false) | not)
             | .qualified_name
             | select(endswith("/" + $q))
             | rtrimstr("/" + $q)' 2>/dev/null \
    | awk 'NF' | sort -u
}
rigs="$(lane_rigs)"

# Fall back to the old coordinator derivation when the agent probe yields nothing
# (an older gc build, or one whose `agent list` lacks --json). Covering the rigs
# we can still name beats silently covering none — which is the exact failure
# this whole change exists to end.
[ -n "$rigs" ] || rigs="$(sy_coordinators | sed 's#/.*$##' | awk 'NF' | sort -u)"

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
