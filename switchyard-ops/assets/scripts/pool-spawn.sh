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
# SCOPE (detect, then spawn + direct-assign, guarded). This order ENUMERATES
# non-suspended rigs and IDENTIFIES each rig's claimable pool demand, and — for a
# rig that is spawn-ready (demand plus a free WIP slot, so no live worker is
# already holding that slot) — it SPAWNS exactly one brakeman via `gc session new
# --no-attach`, captures the resulting adhoc session identity, and direct-assigns
# that rig's next demand bead to it (crit:d275220f711a), all within the
# start-pending window: the `--no-attach` spawn returns with the session
# start-pending, and the assign follows immediately in the same order cycle.
# Exactly one brakeman per rig per cycle — the singular hand-off the controller's
# dead sling-claim would have made.
#
# THE REASSIGN GUARD (crit:65a9b77b2d30). The demand set is a snapshot, read a
# spawn ago; a rival worker can claim a demand bead in the interval between that
# read and this write. So the direct-assign RE-VERIFIES the target bead's CURRENT
# holder in the instant before the write (`sy_pool_holder_is_live`, folded into
# `sy_pool_assign_bead` so no caller can bypass it) and REFUSES the reassign when
# the bead is already held by an assignee whose session is live — active,
# start-pending, creating, or draining (the shared POOL_LIVE_STATES). The order
# can therefore never steal work out from under a running worker. The re-verify
# fails CLOSED on an unverifiable holder (a session roster it cannot read is
# treated as live, refusing rather than stealing), while an UNASSIGNED bead or one
# whose holder's session is confirmably dead — an abandoned claim — is still
# assigned, so a genuinely-freed bead is not stranded.
#
# Still deliberately OUT of this order, left to sibling criteria that build on the
# same demand set: idempotency/bounding across cycles (crit:87f8482bb54f), the
# silent-failure mail (crit:90116a548d3b), and the pack.toml manifest listing +
# end-to-end demonstration (crit:c9141ec577e5). Detection stays a separate,
# hermetically tested unit: a wrong demand read is only a log line, but a wrong
# spawn/assign steals a running worker's work, so the classification is pinned
# before the act.
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

# POOL_SESSION_ID_JQ — pull a session identity out of whatever `gc session new`
# prints. gc builds differ (some emit a bare session object, some a
# `{"session":{...}}` envelope), so try the common identity fields; a non-JSON
# answer just yields nothing here and the shell falls back to a plain-text scan.
POOL_SESSION_ID_JQ='
  (if type=="object" then (.session // .) else empty end)
  | (.qualified_name // .name // .session_name // .id // .session_id // "")'

# sy_pool_spawn_brakeman RIG — spawn ONE adhoc brakeman for RIG and echo its
# session identity (empty when the identity cannot be captured). Uses the exact
# invocation loop-health already relies on (`gc session new <agent> --no-attach`,
# no extra flags, so an unknown-flag build can't silently turn the spawn into a
# no-op) and reads the identity back from its stdout. An adhoc session is named
# for its pool (`<rig>/switchyard-ops.brakeman-adhoc-<suffix>`, the scratch-reaper
# convention), so the plain-text fallback accepts only a token that begins with
# `<rig>/` — never `[]`, a usage line, or human prose.
sy_pool_spawn_brakeman() {
  _out="$(gc session new "$1/switchyard-ops.brakeman" --no-attach 2>/dev/null)"
  _id="$(printf '%s' "$_out" | jq -r "$POOL_SESSION_ID_JQ" 2>/dev/null | awk 'NF' | head -n1)"
  if [ -z "$_id" ]; then
    _id="$(printf '%s\n' "$_out" | tr ' \t' '\n\n' | awk -v r="$1/" 'index($0,r)==1 {print; exit}')"
  fi
  printf '%s' "$_id"
}

# sy_pool_assignee_live ASSIGNEE — succeeds (exit 0, "hands off") when ASSIGNEE
# names a gc session in a live state, fails (exit 1, "not live") only when the
# session roster is readable AND shows no live session for ASSIGNEE. The liveness
# half of the reassign guard: a live holder is a running worker whose bead must
# not be stolen; a dead/absent holder is an abandoned claim whose bead is free
# again. Matches ASSIGNEE against every session-identity field gc builds vary over
# (as sy_pool_spawn_brakeman does), and counts ONLY the shared POOL_LIVE_STATES as
# live. Fails CLOSED: an empty ASSIGNEE aside, an unreadable/malformed session
# roster cannot CONFIRM the holder is dead, so it is treated as live and the
# reassign is refused — never stolen on an unverifiable roster.
sy_pool_assignee_live() {
  [ -n "$1" ] || return 1
  _raw="$(gc session list --json --state all 2>/dev/null)"
  [ -n "$_raw" ] || return 0                       # can't read the roster → refuse
  _states_json="$(printf '%s' "$POOL_LIVE_STATES" | jq -Rc 'split(" ")')"
  _n="$(printf '%s' "$_raw" | jq -r --arg a "$1" --argjson live "$_states_json" '
    [ (.sessions // [])[]
      | select( ((.agent // "") == $a) or ((.agent_name // "") == $a)
                or ((.qualified_name // "") == $a) or ((.name // "") == $a)
                or ((.id // "") == $a) or ((.session_id // "") == $a) )
      | select( (.state // "") as $st | ($live | index($st)) != null )
    ] | length' 2>/dev/null)"
  case "$_n" in ''|*[!0-9]*) return 0 ;; esac       # malformed count → refuse
  [ "$_n" -gt 0 ]
}

# sy_pool_holder_is_live RIG BEAD SELF — the reassign guard's verdict, re-read in
# the instant BEFORE the assign write. Succeeds (exit 0, "hands off") when BEAD is
# already held by a live worker or by a holder that cannot be verified dead; fails
# (exit 1, "clear to assign") only when BEAD is confirmably free — unassigned,
# held by SELF, or held by a session confirmed not-live. The holder is re-read
# from the CURRENT ledger (`gc bd list` with no status filter, so an in-progress
# claim is seen, not only an open one), never trusting the demand snapshot taken a
# spawn ago. Fail direction is deliberate: an unreadable holder re-read degrades
# to snapshot-trust (returns "clear" — the same behaviour as no guard, no worse),
# while an unverifiable *liveness* fails closed inside sy_pool_assignee_live.
sy_pool_holder_is_live() {
  _raw="$(gc bd list --rig "$1" --json 2>/dev/null)"
  printf '%s' "$_raw" | jq -e . >/dev/null 2>&1 || return 1   # unreadable → snapshot-trust
  _holder="$(printf '%s' "$_raw" | jq -r --arg id "$2" '
    (if type=="array" then . else (.beads // []) end)
    | .[] | select((.id // "") == $id) | (.assignee // "")' 2>/dev/null | awk 'NF' | head -n1)"
  [ -n "$_holder" ] || return 1        # unassigned → clear to assign
  [ "$_holder" = "$3" ] && return 1    # already ours → not a steal
  sy_pool_assignee_live "$_holder"     # a real other holder → live? then hands off
}

# sy_pool_assign_bead RIG BEAD SESSION — direct-assign BEAD to SESSION, the
# hand-off gastown's dead sling-claim would have made, GUARDED by the reassign
# re-verify above. `gc bd list`/`update` from the city root see only the town
# ledger, so the write names its rig explicitly (the same rule merge-gate
# follows). Return codes let the caller report the outcome honestly:
#   0 — assigned; 2 — REFUSED (bead held by a live/unverifiable worker, so the
#   order stood down rather than steal it); other — the write itself failed.
sy_pool_assign_bead() {
  if sy_pool_holder_is_live "$1" "$2" "$3"; then
    return 2
  fi
  gc bd update --rig "$1" "$2" --assignee "$3" >/dev/null 2>&1
}

# --- main: enumerate rigs, identify claimable demand, spawn + assign ----------

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
    # Spawn-ready: a free WIP slot means no live worker is already holding it, so
    # spawn exactly ONE brakeman and hand it this rig's NEXT demand bead. The
    # assign follows the spawn immediately, inside the start-pending window.
    # (Bounding this across cycles, and the finer live-assignee guard, are the
    # sibling criteria — here we make the single hand-off and report its outcome.)
    target="$(printf '%s\n' "$demand" | awk 'NF' | head -n1)"
    sess="$(sy_pool_spawn_brakeman "$rig")"
    if [ -z "$sess" ]; then
      action="spawn FAILED (no session identity captured)"
    else
      sy_pool_assign_bead "$rig" "$target" "$sess"
      case $? in
        0) action="spawned $sess, direct-assigned $target" ;;
        2) action="spawned $sess, REFUSED to reassign $target (already held by a live worker)" ;;
        *) action="spawned $sess, but direct-assign of $target FAILED" ;;
      esac
    fi
  else
    slot="full ($live/$max)"; ready="none (no WIP slot)"
    action="none (no WIP slot)"
  fi

  report="$report
- $rig: $count claimable bead(s), WIP slot $slot; spawn-ready: $ready
    demand: $ids
    action: $action"
done

# What this order detected AND did is observed through its own log (gc captures
# order stdout) — the per-rig `action:` line records each spawn + direct-assign.
# It still never mails: surfacing a persistently unclaimed or failed hand-off to
# the mayor is the sibling silent-failure criterion (crit:90116a548d3b).
if [ -n "$report" ]; then
  printf 'pool-spawn: claimable brakeman demand by rig:%s\n' "$report"
fi

exit 0
