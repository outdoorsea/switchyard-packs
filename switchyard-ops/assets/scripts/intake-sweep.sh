#!/bin/sh
# intake-sweep: wake each coordinator into a triage pass over its switchyard
# project. Judgment lives in the session, not here — this script only decides
# WHO to nudge; assets/prompts/intake-sweep.md decides WHAT they do.
set -u

. "$(dirname "$0")/../lib/roster.sh"

PROMPT="$(dirname "$0")/../prompts/intake-sweep.md"
[ -r "$PROMPT" ] || exit 0
MSG="$(cat "$PROMPT")"

# A city with no coordinators is a legitimate state (all rigs suspended, or a
# fresh city). Say nothing — silence is the correct output for an idle city.
# This test must come FIRST and stand on its own: the old code inferred it from
# a zero success count, which made an idle city and a city where EVERY NUDGE
# FAILED produce byte-identical output (silence, rc=0). They are opposite
# conditions and only one of them is healthy.
coords="$(sy_coordinators | awk 'NF')"
[ -n "$coords" ] || exit 0

nudged=0
failed=""
for agent in $coords; do
  # Resolve the agent's qualified name to a live SESSION alias — `gc session
  # nudge` cannot resolve an agent name (see sy_live_session_for).
  #
  # Three outcomes, three categories. A FAILED lookup is not an absent session:
  # reporting it as no-live-session would send the operator to spawn a session
  # when the actual fault is that the roster could not be read.
  if ! target="$(sy_live_session_for "$agent")"; then
    failed="$failed $agent(session-lookup-failed)"
    continue
  fi
  if [ -z "$target" ]; then
    failed="$failed $agent(no-live-session)"
    continue
  fi
  if gc session nudge "$target" "$MSG" >/dev/null 2>&1; then
    nudged=$((nudged + 1))
  else
    failed="$failed $agent(nudge-failed)"
  fi
done

# SILENT-FAILURE INVARIANT (same contract as pool-spawn and lane-ensure): a
# coordinator that could not be reached leaves its intake backlog untriaged with
# nobody watching, so it becomes mail within the cycle. Reaching every
# coordinator is the quiet path.
if [ -n "$failed" ]; then
  gc mail send mayor \
    -s "intake-sweep: could not reach $(printf '%s' "$failed" | wc -w | tr -d ' ') of $(printf '%s' "$coords" | wc -w | tr -d ' ') coordinator(s)" \
    -m "intake-sweep could not deliver its triage prompt to:$failed

Reached $nudged of $(printf '%s' "$coords" | wc -w | tr -d ' ') coordinators this cycle.

session-lookup-failed means 'gc session list --json' could not be run or its output could not be parsed, so whether that agent has a live session is UNKNOWN. Do not spawn on this one — check gc and jq first.
no-live-session means the roster was read fine and names an agent with no active session to nudge: check the agent is imported and not suspended, then spawn one.
nudge-failed means the session alias resolved but gc session nudge returned non-zero.

Until this clears, that rig's switchyard intake queue is not being triaged." \
    >/dev/null 2>&1
fi

exit 0
