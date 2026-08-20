#!/bin/sh
# city-lane-ensure AGENT SUBJECT — keep exactly one live session of the
# CITY-SCOPED switchyard-ops agent AGENT alive.
#
# The city-scoped sibling of lane-ensure.sh. Same contract, one difference that
# matters: a city agent's qualified name has NO rig prefix, so there is no rig
# set to iterate and exactly one session to keep alive city-wide.
#
#   token-audit    -> city-lane-ensure token-auditor  "token auditor"
#   refactor-scan  -> city-lane-ensure refactor-scout "refactor scout"
#
# Do NOT point lane-ensure.sh at a city-scoped agent: it derives its rig set from
# agents whose qualified_name ENDS WITH "/switchyard-ops.<agent>". A city agent
# never matches, so the sweep would find zero rigs, report success, and silently
# never spawn anything — the exact failure mode lane-ensure's own comments
# describe having already been bitten by.
#
# Judgment lives in the session (agents/<AGENT>/prompt.template.md); this script
# only decides WHETHER to start one.
#
# SILENT-FAILURE INVARIANT: a spawn that returns no session identity leaves the
# lane unowned with nobody watching, so it mails the mayor within the cycle. A
# session already running is a legitimate quiet state: say nothing.
set -u

AGENT="${1:?city-lane-ensure: AGENT (e.g. token-auditor) is required}"
SUBJECT="${2:-$AGENT}"

. "$(dirname "$0")/../lib/roster.sh"
sy_load_conf

QUALIFIED="$SY_NS.$AGENT"

# Mirrors lane-ensure/pool-spawn so "is one already running?" is answered the
# same way pack-wide.
LANE_LIVE_STATES="active start-pending start_pending creating draining"

LANE_SESSION_ID_JQ='
  (if type=="object" then (.session // .) else empty end)
  | (.qualified_name // .name // .session_name // .id // .session_id // "")'

# How many live sessions of this city agent already exist. An unreadable or
# non-numeric answer yields EMPTY (treated as "cannot confirm absent" -> no
# spawn), never a false zero that would stack a second session on top of a live
# one. Failing closed here is deliberate: a duplicate auditor double-files every
# finding, which is worse than a skipped cycle.
#
# JOIN ON .template, exactly as lane-ensure.sh and pool-spawn.sh do. A spawned
# session's agent_name carries an instance suffix — `switchyard-ops.judge-adhoc-
# 1788c6f978` — while $q is the bare qualified name, so the original `== $q`
# matched NOTHING and returned a confident 0 no matter how many sessions were
# live. That is the fail-OPEN case the "cannot confirm absent" rule above does
# not cover: it guards an UNREADABLE roster, but a confidently-wrong ZERO sails
# straight through, and every sweep then spawns another session, forever.
#
# This is the CITY-scoped variant and it was the site everyone missed: the same
# defect was fixed in the rig-scoped counter and in the pool counter while this
# copy was left comparing a bare name. Three copies of one predicate is the real
# defect; until they are unified, fix them together.
lane_live_count() {
  _states_json="$(printf '%s' "$LANE_LIVE_STATES" | jq -Rc 'split(" ")')"
  gc session list --json --state all 2>/dev/null \
    | jq -r --arg q "$QUALIFIED" --argjson live "$_states_json" '
        [ (.sessions // [])[]
          | (.agent // .agent_name // .qualified_name // "") as $n
          | select( (.template // "") == $q
                    or $n == $q
                    or ($n | startswith($q + "-adhoc-")) )
          | select( (.state // "") as $st | ($live | index($st)) != null )
        ] | length' 2>/dev/null \
    | awk 'NF' | head -n1
}

# Spawn ONE adhoc session and echo its identity (empty when uncapturable). Uses
# the bare invocation pool-spawn/loop-health rely on, so an unknown-flag build
# cannot silently no-op the spawn.
lane_spawn() {
  _out="$(gc session new "$QUALIFIED" --no-attach 2>/dev/null)"
  _id="$(printf '%s' "$_out" | jq -r "$LANE_SESSION_ID_JQ" 2>/dev/null | awk 'NF' | head -n1)"
  # Fallback 1 — a human sentence: "Session gf-wisp-1zvxzd created from template …"
  # Prefer it: field 2 is the real identity, not merely the template name.
  if [ -z "$_id" ]; then
    _id="$(printf '%s\n' "$_out" | awk '/^[Ss]ession [^ ]+ created/{print $2; exit}')"
  fi
  # Fallback 2 — any token naming the agent. Strip surrounding punctuation FIRST:
  # the template name arrives quoted, and the leading double quote is what made
  # lane-ensure's equivalent match fail and mail a false alert on every spawn.
  if [ -z "$_id" ]; then
    _id="$(printf '%s\n' "$_out" | tr ' \t' '\n\n' \
      | sed 's/^[^A-Za-z0-9_]*//; s/[^A-Za-z0-9_/.-]*$//' \
      | awk -v a="$QUALIFIED" 'index($0,a)==1 {print; exit}')"
  fi
  printf '%s' "$_id"
}

# The agent must actually be defined in this city — a pack imported without this
# lane, or the agent suspended, is a legitimate "nothing to do", not a failure.
defined="$(gc agent list --json 2>/dev/null \
  | jq -r --arg q "$QUALIFIED" '(if type=="array" then . else (.agents // []) end)
           | .[]
           | select((.suspended // false) | not)
           | .qualified_name
           | select(. == $q)' 2>/dev/null | awk 'NF' | head -n1)"
[ -n "$defined" ] || exit 0

live="$(lane_live_count)"

# Non-numeric (probe unreadable) -> fail closed, say nothing. A roster we cannot
# read is not a roster showing zero.
case "$live" in
  ''|*[!0-9]*) exit 0 ;;
esac

[ "$live" -gt 0 ] && exit 0

id="$(lane_spawn)"

if [ -z "$id" ]; then
  gc mail send mayor -s "city-lane-ensure: $SUBJECT spawn returned no identity" \
    -m "Tried to start the city-scoped $SUBJECT ($QUALIFIED) because none was live, but the spawn returned no session identity.

That means the lane may be unowned with nobody watching it, OR a session may have started that this script cannot see. Check:
  gc session list --state=all | grep $AGENT

If a session is running, this is a spawn-output parsing gap, not a dead lane." >/dev/null 2>&1
  exit 0
fi

exit 0
