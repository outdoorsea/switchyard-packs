#!/bin/sh
# pool-spawn: detect each non-suspended rig's CLAIMABLE brakeman demand
# (switchyard PRD #185, crit:0993a1e5c8c1).
#
# WHY THIS ORDER EXISTS. Pool-based worker dispatch in a switchyard Gas City
# rides gastown's gc controller (scale_check + sling-claim + the formula
# compiler), and three defects there kill dispatch silently: a molecule root
# that self-blocks reads as demand that is never claimable (gff-56lh), the
# scale_check that will not spawn (gff-g8kr), and config-routed beads nothing
# can claim (gff-fd33). The fix ships the supported way — a pack-authored order
# that does the controller's job itself — and this is its FIRST half: honestly
# identifying what demand a rig actually has, so a spawn decision is never made
# on a phantom.
#
# SCOPE (detection only). This order ENUMERATES non-suspended rigs and IDENTIFIES
# each rig's claimable pool demand. It is read-only: it spawns no session,
# assigns no bead, and mails no one. The remaining halves of PRD #185 —
# spawning a brakeman via `gc session new --no-attach` and direct-assigning the
# demand bead (crit:d275220f711a), the live-assignee reassign guard
# (crit:65a9b77b2d30), idempotency/bounding (crit:87f8482bb54f), the
# silent-failure mail (crit:90116a548d3b), and the pack.toml manifest listing +
# end-to-end demonstration (crit:c9141ec577e5) — are their own criteria/beads
# and BUILD ON the demand set this order computes. Keeping detection a separate,
# testable unit is deliberate: a wrong demand read here is a log line, but a
# wrong spawn/assign steals a running worker's work.
#
# WHAT COUNTS AS CLAIMABLE DEMAND (per rig). A bead is demand a fresh brakeman
# could actually claim iff ALL hold:
#   - it is OPEN,
#   - it is routed to the rig's worker pool (`gc.routed_to` ends `.brakeman`,
#     the same selector merge-gate trusts),
#   - it is UNASSIGNED (no `.assignee` — an assigned bead is already someone's),
#   - it is REAL WORK, the work bead itself and not a self-blocked molecule root:
#     a directly-slung work bead carries no `gc.kind` (workflow roots/steps all
#     do), and it is not blocked by an open dependency (a molecule root is
#     blocked by its own children — the gff-56lh phantom).
# ...and the rig must have a free WIP slot: fewer LIVE brakeman sessions than the
# pool's max_active_sessions. Demand a full pool cannot take is reported, but not
# as spawn-ready.
#
# Every read is tolerant: no gc, no jq, an unreadable rig, or a malformed answer
# yields no demand for that rig rather than a false positive. Detection fails
# toward "nothing to spawn", never toward spawning on noise.
set -u

. "$(dirname "$0")/../lib/roster.sh"

# The pool this order serves. A rig's worker pool is `<rig>/switchyard-ops.brakeman`;
# routing stamps that qualified name onto a bead's `gc.routed_to`.
POOL_SUFFIX=".brakeman"

# Session states that OCCUPY a WIP slot. A slot is free only when a rig's live
# brakeman count is below max_active_sessions. This is the same "live" definition
# the sibling reassign-guard (crit:65a9b77b2d30) uses, kept in one place so the
# two never drift: a session in any of these is doing (or about to do) work.
POOL_LIVE_STATES="active start-pending start_pending creating draining"

# sy_pool_nonsuspended_rigs — the name of every rig gc is not suspending, one per
# line. Mirrors merge-gate's rig enumeration, minus suspended rigs (checked two
# ways so a differently-spelled suspend signal still excludes; excluding an
# active rig only under-reports, which is the safe direction for detection).
sy_pool_nonsuspended_rigs() {
  gc rig list --json 2>/dev/null | jq -r '
    (if type=="array" then . else (.rigs // []) end)
    | .[]
    | select((.suspended // false) | not)
    | select((.state // "") != "suspended")
    | .name' 2>/dev/null
}

# POOL_DEMAND_JQ — a jq program over a `gc bd list --json` array (or {beads:[...]})
# on stdin, emitting the id of every bead that is claimable brakeman demand.
# Factored out as a named program so scripts/pool-spawn.test.sh can exercise the
# classification against fixture bead JSON directly — the part that can be subtly
# wrong (an included self-blocked root becomes a phantom spawn) is the part a
# hermetic test must pin.
POOL_DEMAND_JQ='
  (if type=="array" then . else (.beads // []) end)
  | .[]
  | select((.status // "open") == "open")
  | select((.assignee // "") == "")
  | select((.metadata["gc.routed_to"] // "") | endswith("'"$POOL_SUFFIX"'"))
  | select((.metadata["gc.kind"] // "") == "")
  | select(((.blocked_by // []) | length) == 0)
  | select((.blocked // false) | not)
  | .id'

# sy_pool_rig_demand RIG — ids of RIG's claimable brakeman demand, one per line.
# `gc bd list` from the city root sees only the town ledger, so the rig is named
# explicitly (the same rule merge-gate follows).
sy_pool_rig_demand() {
  gc bd list --rig "$1" --status open --json 2>/dev/null \
    | jq -r "$POOL_DEMAND_JQ" 2>/dev/null \
    | awk 'NF'
}

# sy_pool_brakeman_max RIG — the rig brakeman pool's max_active_sessions, from the
# reconciler's own agent record. 0 when the pool is unknown here, which reads as
# "no free slot" — detection must not claim a slot it cannot size.
sy_pool_brakeman_max() {
  gc agent list --json 2>/dev/null | jq -r --arg q "$1/switchyard-ops.brakeman" '
    (if type=="array" then . else (.agents // []) end)
    | .[]
    | select((.qualified_name // "") == $q)
    | ((.pool.max) // .max_active_sessions // 0)' 2>/dev/null \
    | awk 'NF' | head -n1
}

# sy_pool_brakeman_live RIG — count of RIG's brakeman sessions in a live state.
# The live-state set is passed in as a jq array so the shell constant above is
# the single source of truth.
sy_pool_brakeman_live() {
  _states_json="$(printf '%s' "$POOL_LIVE_STATES" | jq -Rc 'split(" ")')"
  gc session list --json --state all 2>/dev/null | jq -r --arg q "$1/switchyard-ops.brakeman" --argjson live "$_states_json" '
    [ (.sessions // [])[]
      | select( ((.agent // .agent_name // .qualified_name // "") == $q) )
      | select( (.state // "") as $st | ($live | index($st)) != null )
    ] | length' 2>/dev/null \
    | awk 'NF' | head -n1
}

# --- main: enumerate rigs, identify claimable demand -------------------------

command -v jq >/dev/null 2>&1 || exit 0   # every read below is jq-shaped

report=""
for rig in $(sy_pool_nonsuspended_rigs); do
  demand="$(sy_pool_rig_demand "$rig")"
  [ -n "$demand" ] || continue            # silence is the success case

  count=$(printf '%s\n' "$demand" | awk 'NF' | wc -l | tr -d ' ')
  ids="$(printf '%s\n' "$demand" | awk 'NF' | tr '\n' ' ' | sed 's/ *$//')"

  max="$(sy_pool_brakeman_max "$rig")"; case "$max" in ''|*[!0-9]*) max=0 ;; esac
  live="$(sy_pool_brakeman_live "$rig")"; case "$live" in ''|*[!0-9]*) live=0 ;; esac

  if [ "$max" -gt "$live" ]; then
    slot="free ($live/$max)"; ready="$ids"
  else
    slot="full ($live/$max)"; ready="none (no WIP slot)"
  fi

  report="$report
- $rig: $count claimable bead(s), WIP slot $slot; spawn-ready: $ready
    demand: $ids"
done

# Detection is observed through the order's own log (gc captures order stdout);
# it never mails — surfacing persistent unclaimed demand to the mayor is the
# sibling silent-failure criterion (crit:90116a548d3b).
if [ -n "$report" ]; then
  printf 'pool-spawn: claimable brakeman demand by rig:%s\n' "$report"
fi

exit 0
