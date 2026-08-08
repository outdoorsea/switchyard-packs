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
# TWO DISPATCH TOPOLOGIES, AND THE CLOUD ONE DELETES MOST OF THIS FILE
# (switchyard PRD #327, crit:53605636a114). Everything described above serves the
# LOCAL-`bd` topology (docs/dispatch-topologies.md, topology B): demand lives in a
# rig's `bd` ledger, and because a `bd` hand-off is NOT atomic — the order spawns a
# worker, then writes an assignee, racing anyone else reading the same ledger — it
# needs the direct-assign, the reassign guard that re-verifies the holder in the
# instant before that write, and a cursor file remembering last cycle's hand-offs
# so one that silently did not take can be caught a cycle later.
#
# Switchyard's managed CLOUD claim pool (topology A) is the documented default and
# has none of that shape. Its claim is ATOMIC and server-side: a worker claims for
# itself over MCP, and a second claimant is refused 409. So the cloud path does not
# port the triad above, it DELETES it. For a rig cut over to cloud dispatch this
# order does exactly one thing — ask the project's pool how deep it is, and, if it
# has work and the rig has a free WIP slot, spawn one brakeman to go claim it:
#   - NO `gc bd` read or write (that is the "bd bridge" the cutover removes),
#   - NO direct-assign and no reassign guard (nothing is handed off to race over),
#   - NO cursor file (there is no cross-cycle hand-off to remember).
# That is the whole of "a project can be cut over to cloud-pool dispatch without
# the bd bridge, and the builder lane requires no cursor file or local ledger".
#
# OPT-IN, PER RIG, ALWAYS. `CLOUD_POOL_RIGS` in the city's roster.conf names the
# rigs cut over; unset (the default) means every rig keeps the `bd` path below,
# byte for byte. PRD #327 puts this out of scope in as many words — "Changing the
# dispatch topology of any project already running the local-bd bridge. The
# cutover is opt-in per project" — so the opt-in is not a convenience, it is the
# criterion. A city with no roster.conf sees no behaviour change at all.
#
# THE CLOUD PROBE FAILS CLOSED, INVERTING THE READ LIBRARY'S DEFAULT, and that is
# deliberate. switchyard-api.sh is advisory and fails OPEN: an unreadable answer
# means "proceed as if the check did not exist", because there the check only ever
# WITHHOLDS a spawn some other signal already justified. Here it is the SOLE
# evidence of demand — there is no other signal to fall back on — so failing open
# would not be "proceed as before", it would be "spawn an LLM session against a
# queue we could not read", every minute, up to the pool's max. PRD #327 forbids
# exactly that ("a lane with an empty queue must not spawn"), so an unreadable
# probe spawns NOTHING and MAILS instead — the silent stall becomes a signal,
# which is this pack's standing invariant rather than a new rule invented here.
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
# IDEMPOTENCY & BOUNDING (crit:87f8482bb54f). Because this order runs on a tight
# 1-minute cooldown, it re-runs constantly against a moving ledger, so it must be
# safe to repeat. Three invariants make it so:
#   - BOUNDED. At most ONE brakeman per rig per cycle, and only while the rig's
#     LIVE brakeman count is below max_active_sessions — where "live" counts every
#     start-pending/creating session (POOL_LIVE_STATES), so the worker a previous
#     cycle just spawned already occupies the slot it filled. Repeated runs
#     therefore fill a pool up to its max and then stop; they never overshoot it.
#   - NO SECOND WORKER FOR HELD DEMAND. The demand set already excludes assigned
#     beads, so a target a prior cycle handed off drops out of the next cycle's
#     demand entirely. And for the narrow race where a bead is claimed AFTER the
#     snapshot but BEFORE the write, the target's current holder is re-verified
#     right before the spawn (`sy_pool_holder_is_live`): a live holder means no
#     spawn at all this cycle. So demand a live worker already holds never draws a
#     second worker.
#   - NO WEDGED ROOTS. The order only `session new`s a worker and direct-assigns
#     an EXISTING work bead; it mints no molecule root or workflow step, so a
#     repeated run can leave no wedged in_progress root behind — the gff-56lh
#     phantom this whole order exists to route around.
#
# SILENT FAILURE BECOMES MAIL (crit:90116a548d3b). switchyard-ops holds one
# invariant across every order: a failure the loop cannot self-heal is MAILED to
# the mayor within the cycle, never left as a mere log line nobody reads. This
# order replaces the controller's dead sling-claim, so a hand-off that does not
# happen means work is stalled — exactly the silent stall the invariant exists to
# surface. Three ways a hand-off fails, all escalated here:
#   - no session id returned / adhoc identity unresolved (the spawn produced no
#     owner to assign to),
#   - the direct-assign was rejected (a spawned worker left with nothing to claim),
#   - a bead this order direct-assigned a FULL CYCLE AGO is STILL claimable demand
#     (the hand-off silently did not take — the assignee never stuck, or the
#     worker died and released it). This last one is cross-cycle by nature, so it
#     rides a small state file remembering last cycle's hand-offs.
# A rig with no free WIP slot is NOT a failure — its demand persists because the
# pool is busy (saturation), so it is never tracked for the still-unclaimed check.
# Nor is a spawn the idempotency guard declines, or an assign refused because a
# live worker already holds the target (exit 2): that guard firing is the correct
# outcome, not a stall, so it escalates nothing.
#
# WHAT COUNTS AS CLAIMABLE DEMAND (per rig). A bead is demand a fresh brakeman
# could actually claim iff ALL hold:
#   - it is OPEN,
#   - it is routed to the rig's worker pool (`gc.routed_to` ends `.brakeman`,
#     the same selector publish-gate trusts),
#   - it is UNASSIGNED (no `.assignee` — an assigned bead is already someone's),
#   - it is REAL WORK, the work bead itself and not a self-blocked molecule root:
#     a directly-slung work bead carries no `gc.kind` (workflow ROOTS carry
#     `gc.kind=workflow`), and it is not blocked by an open dependency (a molecule
#     root is blocked by its own children — the gff-56lh phantom),
#   - its molecule ROOT is still alive (`gc.root_bead_id` names a bead that is not
#     closed), and
#   - nothing it waits on is outstanding: no `blocks` / `waits-for` /
#     `conditional-blocks` dependency pointing at a bead that has not closed.
#
# THE LAST TWO EXIST BECAUSE THE FIRST FOUR LEAKED 72 PHANTOMS (gff-1d2y, sw-ghad).
# A molecule STEP is not a root: it carries `gc.step_ref` and NO `gc.kind`, so the
# `gc.kind` test above — written believing "roots/steps all carry it" — never
# excluded one. Steps are chained (step N+1 `blocks`-depends on step N), so all six
# of a molecule counted as six demand units when at most the head was claimable;
# and when a root was reaped its orphaned steps stayed open forever, re-reported
# every cycle with nothing left to reap them. Neither leak was visible to the old
# guards: `.blocked_by` and `.blocked` are fields `bd` DOES NOT EMIT, so
# `(.blocked_by // [])` and `(.blocked // false)` took their defaults and admitted
# every row. They are kept below only because the self-test's fixtures assert them;
# the two guards added underneath are the ones with teeth. If you tighten this
# classifier again, verify it against `bd ready` — an independent implementation of
# unblocked semantics that cannot be edited from here — and not against a fixture
# you wrote yourself.
# ...and the rig must have a free WIP slot: fewer LIVE brakeman sessions than the
# pool's max_active_sessions. Demand a full pool cannot take is reported, but not
# as spawn-ready.
#
# Every read is tolerant: no gc, no jq, an unreadable rig, or a malformed answer
# yields no demand for that rig rather than a false positive. Detection fails
# toward "nothing to spawn", never toward spawning on noise.
set -u

. "$(dirname "$0")/../lib/roster.sh"
. "$(dirname "$0")/../lib/switchyard-api.sh"

# CLOUD_POOL_RIGS — the rigs cut over to cloud-pool dispatch, space-separated, from
# the city's roster.conf. Defaulted to empty HERE rather than in sy_load_conf: this
# order is its only consumer, and roster.sh is shared by a dozen others whose
# hermetic tests should not have to absorb a new global for a setting they ignore.
# The default is what makes the cutover opt-in — unset means every rig takes the
# `bd` path exactly as before.
CLOUD_POOL_RIGS=""
sy_load_conf

# The pool this order serves. A rig's worker pool is `<rig>/switchyard-ops.brakeman`;
# routing stamps that qualified name onto a bead's `gc.routed_to`.
POOL_SUFFIX=".brakeman"

# Session states that OCCUPY a WIP slot. A slot is free only when a rig's live
# brakeman count is below max_active_sessions. This is the same "live" definition
# the sibling reassign-guard (crit:65a9b77b2d30) uses, kept in one place so the
# two never drift: a session in any of these is doing (or about to do) work.
POOL_LIVE_STATES="active start-pending start_pending creating draining"

# sy_pool_nonsuspended_rigs — the name of every rig gc is not suspending, one per
# line. Mirrors publish-gate's rig enumeration, minus suspended rigs (checked two
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
#
# TWO OF THESE GUARDS ARE QUESTIONS ABOUT *OTHER* BEADS — is this step's molecule
# root still alive, and are the steps it waits on finished? — so the program takes
# the WHOLE ledger (`--all`, closed rows included) and indexes it into `$status`
# first. That keeps the order at exactly ONE `gc bd list` per rig: resolving each
# root with its own `gc` call would multiply a ~20s subprocess by the rig count,
# which is what pushed the judging lane's sweep past its deadline (sw-jqrx), and
# this order runs on a 1-minute cadence.
#
# An id MISSING from `$status` is read pessimistically in both places — an unknown
# root counts as closed, an unknown blocker as unfinished — so a bead this order
# cannot fully account for is dropped from demand rather than spawned on. That is
# the same fail-toward-nothing direction the rest of the file takes.
POOL_DEMAND_JQ='
  (if type=="array" then . else (.beads // []) end)
  | . as $all
  | (reduce $all[] as $b ({}; .[$b.id] = ($b.status // "open"))) as $status
  | $all[]
  | select((.status // "open") == "open")
  | select((.assignee // "") == "")
  | select((.metadata["gc.routed_to"] // "") | endswith("'"$POOL_SUFFIX"'"))
  | select((.metadata["gc.kind"] // "") == "")
  | select(((.blocked_by // []) | length) == 0)
  | select((.blocked // false) | not)
  | select(
      ((.metadata["gc.root_bead_id"] // "") as $root
       | $root == "" or (($status[$root] // "closed") != "closed"))
    )
  | select(
      ([ .dependencies[]?
         | ((.type // .dependency_type // "") as $t
            | select($t == "blocks" or $t == "waits-for" or $t == "conditional-blocks"))
         | ((.depends_on_id // .id // "") as $dep
            | select($dep != "" and (($status[$dep] // "open") != "closed")))
       ] | length) == 0
    )
  | .id'

# sy_pool_rig_demand RIG — ids of RIG's claimable brakeman demand, one per line.
# `gc bd list` from the city root sees only the town ledger, so the rig is named
# explicitly (the same rule publish-gate follows).
# `--all` rather than `--status open`: the classifier needs the CLOSED rows to tell
# a finished blocker from an outstanding one and a reaped molecule root from a live
# one. Without them every closed id reads as absent, and absent is the pessimistic
# branch — a correct-but-useless demand set of nothing. The rows are cheap (the
# switchyard ledger measures 428 open / 89 closed) and still cost a single call.
sy_pool_rig_demand() {
  gc bd list --rig "$1" --all --json 2>/dev/null \
    | jq -r "$POOL_DEMAND_JQ" 2>/dev/null \
    | awk 'NF'
}

# sy_pool_rig_is_cloud RIG — 0 when RIG is opted into cloud-pool dispatch.
#
# The space-padded `case`, the same idiom the still-unclaimed check below uses, and
# not `for _r in $CLOUD_POOL_RIGS`. Iterating the bare expansion would word-split as
# intended but ALSO pathname-expand: a rig name holding a glob character would be
# replaced by whatever files happen to sit in the order's working directory. Here
# both operands stay quoted, so the only pattern characters are the two `*` written
# literally, and the padding makes the match whole-token — a rig `forge` is never
# matched by a cut-over `forge-staging`, nor the reverse. No subprocess either,
# which matters on a 1-minute cadence.
sy_pool_rig_is_cloud() {
  case " ${CLOUD_POOL_RIGS:-} " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# sy_pool_cloud_depth RIG — how many beads wait in RIG's CLOUD claim pool. Prints a
# count (possibly 0), or NOTHING when the answer is not confidently known.
#
# `?limit=1` because this asks a QUESTION, not for the work: `total` is the pool's
# full claimable depth regardless of the page bound, so bounding the page keeps the
# answer one bead wide while staying exact. The count needs no client-side
# classification the way the `bd` demand set does — the server already excludes
# claimed beads, applies the cross-lane criterion exclusion (PRD #154) and honours
# PRD-level admission control (PRD #179), so `total` is by construction "beads a
# fresh worker could actually claim right now".
#
# EMPTY IS NOT ZERO, and the caller must not conflate them. Empty means the probe
# could not answer — no token, no reachable switchyard, an ambiguous rig→project
# mapping, a body jq could not read — and the caller escalates rather than spawning.
# A real `0` is a confident "the queue is empty", which is silence.
sy_pool_cloud_depth() {
  [ -n "$cloud_token" ] || return 0

  _pcd_project="$(sy_project_for_rig "$1" "$cloud_projects")"
  [ -n "$_pcd_project" ] || return 0

  _pcd_body="$(sy_api_get "/api/v1/projects/$_pcd_project/pool?limit=1" "$cloud_token")"
  [ -n "$_pcd_body" ] || return 0

  # `.total` and not `.beads | length`: the page is bounded to 1, so the array's
  # length answers a different question (how many did you send me) than the one
  # asked (how much is there). `// empty` so an unexpected shape yields nothing and
  # is caught by the digit check rather than reaching a numeric guard as `null`.
  _pcd_n="$(printf '%s' "$_pcd_body" | jq -r '.total // empty' 2>/dev/null | awk 'NF' | head -n1)"
  case "${_pcd_n:-}" in
    '' | *[!0-9]*) return 0 ;;
  esac
  printf '%s' "$_pcd_n"
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
#
# JOIN ON .template. For a POOL this is not merely the more robust key, it is the
# ONLY one that can ever match. Pool sessions are named from namepool.txt —
# `<rig>/switchyard-ops.fireman`, `.switchman`, `.shunter` — and that file
# deliberately does NOT contain `brakeman`, so a pool member's `agent_name` never
# contains the agent's own name in any form. No comparison against $q, exact or
# suffix-stripped or prefix-matched, can succeed. `gc session list --json`
# (schema_version 1) reports `template` on every row and it holds the unsuffixed
# agent name, so it is the honest join key here and everywhere else:
#   template=<rig>/switchyard-ops.brakeman   agent_name=<rig>/switchyard-ops.fireman
#   template=bd.dog                          agent_name=bd.dog-1
# The agent_name clauses are kept only as a fallback for gc builds that might
# omit .template. Note the second line above: .template also resolves the numeric
# pool suffix correctly, so no suffix-stripping is needed to handle it.
sy_pool_brakeman_live() {
  _states_json="$(printf '%s' "$POOL_LIVE_STATES" | jq -Rc 'split(" ")')"
  gc session list --json --state all 2>/dev/null | jq -r --arg q "$1/switchyard-ops.brakeman" --argjson live "$_states_json" '
    [ (.sessions // [])[]
      | (.agent // .agent_name // .qualified_name // "") as $n
      | select( (.template // "") == $q
                or $n == $q
                or ($n | startswith($q + "-adhoc-")) )
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
# ledger, so the write names its rig explicitly (the same rule publish-gate
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

# Cross-cycle memory of the beads this order direct-assigned LAST cycle, one
# `<rig> <bead>` per line. A bead still in the demand set a full cycle after we
# handed it off means the hand-off silently did not take — the fourth failure
# mode the immediate spawn/assign checks cannot see. Only successful hand-offs are
# tracked (a bead on a full-slot rig is busy, not stalled), so a persistently
# saturated pool never mails.
ASSIGNED_LAST="$(sy_state_dir)/pool-spawn.assigned-last"
prev_assigned=""
[ -f "$ASSIGNED_LAST" ] && prev_assigned="$(cat "$ASSIGNED_LAST" 2>/dev/null)"

# The switchyard credential and project list, resolved ONCE per cycle and ONLY when
# some rig is actually cut over. A `bd`-only city (the default) must pay no network
# call at all on a 1-minute cadence, and a cloud city must not let a mid-cycle blip
# answer differently for two rigs in the same sweep.
cloud_token=""
cloud_projects=""
if [ -n "${CLOUD_POOL_RIGS:-}" ]; then
  cloud_token="$(sy_api_token)"
  cloud_projects="$(sy_api_projects "$cloud_token")"
fi

report=""
escalations=""    # per-rig silent failures to mail the mayor this cycle
assigned_now=""   # `<rig> <bead>` hand-offs made this cycle, for next cycle's check
bd_rigs_seen=""   # did the local-`bd` path run for ANY rig this cycle?
for rig in $(sy_pool_nonsuspended_rigs); do
  # CLOUD-POOL DISPATCH (crit:53605636a114) — probe, then spawn, and nothing else.
  # No `bd` read, no direct-assign, no cursor entry: the worker claims for itself
  # over MCP, atomically, so there is no hand-off here to race, guard or remember.
  if sy_pool_rig_is_cloud "$rig"; then
    depth="$(sy_pool_cloud_depth "$rig")"

    # Unreadable probe: spawn NOTHING and mail. This is the sole demand signal in
    # cloud mode, so "unknown" cannot degrade to "spawn anyway" — that would wake an
    # LLM session against a queue we could not read, every cycle. Mailing is what
    # keeps the resulting quiet from being silent.
    if [ -z "$depth" ]; then
      report="$report
- $rig: cloud pool UNREADABLE (no token, unreachable switchyard, or the rig's project could not be resolved unambiguously)
    action: none (no spawn on an unread queue)"
      escalations="$escalations
- $rig: is cut over to cloud-pool dispatch (CLOUD_POOL_RIGS) but its claim pool could not be read — no token, an unreachable switchyard, or a rig name that does not resolve to exactly one project. No brakeman was spawned, so any work waiting in that pool is stalled until this is fixed."
      continue
    fi

    [ "$depth" -gt 0 ] || continue   # a confidently empty queue is the silent case

    max="$(sy_pool_brakeman_max "$rig")"; case "$max" in ''|*[!0-9]*) max=0 ;; esac
    live="$(sy_pool_brakeman_live "$rig")"; case "$live" in ''|*[!0-9]*) live=0 ;; esac

    if [ "$max" -gt "$live" ]; then
      sess="$(sy_pool_spawn_brakeman "$rig")"
      if [ -z "$sess" ]; then
        action="spawn FAILED (no session identity captured)"
        escalations="$escalations
- $rig: brakeman spawn returned no session identity — $depth claimable cloud-pool bead(s) left unclaimed."
      else
        action="spawned $sess (claims from the cloud pool itself; no direct-assign)"
      fi
      slot="free ($live/$max)"
    else
      slot="full ($live/$max)"
      action="none (no WIP slot)"
    fi

    report="$report
- $rig: $depth claimable cloud-pool bead(s), WIP slot $slot
    dispatch: cloud pool (no bd ledger, no cursor file)
    action: $action"
    continue
  fi

  bd_rigs_seen=1
  demand="$(sy_pool_rig_demand "$rig")"
  [ -n "$demand" ] || continue            # silence is the success case

  count=$(printf '%s\n' "$demand" | awk 'NF' | wc -l | tr -d ' ')
  ids="$(printf '%s\n' "$demand" | awk 'NF' | tr '\n' ' ' | sed 's/ *$//')"

  # Silent-failure mode 4 — a bead we direct-assigned last cycle is STILL claimable
  # demand: the hand-off did not take. Check the ids we handed THIS rig against the
  # current demand set (bead ids are single tokens, so word-splitting is safe).
  for pb in $(printf '%s\n' "$prev_assigned" | awk -v r="$rig" '$1==r {print $2}'); do
    case " $ids " in
      *" $pb "*) escalations="$escalations
- $rig: bead $pb was direct-assigned last cycle but is STILL claimable demand — the hand-off did not take (unclaimed after a full cycle)." ;;
    esac
  done

  max="$(sy_pool_brakeman_max "$rig")"; case "$max" in ''|*[!0-9]*) max=0 ;; esac
  live="$(sy_pool_brakeman_live "$rig")"; case "$live" in ''|*[!0-9]*) live=0 ;; esac

  if [ "$max" -gt "$live" ]; then
    slot="free ($live/$max)"; ready="$ids"
    # Spawn-ready: a free WIP slot means no live worker is already holding it, so
    # spawn exactly ONE brakeman and hand it this rig's NEXT demand bead. The
    # assign follows the spawn immediately, inside the start-pending window.
    target="$(printf '%s\n' "$demand" | awk 'NF' | head -n1)"

    # IDEMPOTENCY / BOUNDING (crit:87f8482bb54f). The demand set is a snapshot,
    # read a moment ago; between that read and this write a PRIOR cycle's spawn —
    # or a rival worker — may already have claimed this target. Re-verify the
    # target's CURRENT holder BEFORE spawning (not only before the assign): if a
    # live worker already holds it, spawn NOTHING. This is the guarantee that
    # makes repeated runs idempotent — demand a live worker already holds never
    # draws a second spawn — and keeps the pool bounded: a raced cycle costs zero
    # idle sessions instead of the earlier spawn-then-refuse. The spawn is also
    # capped at one per rig per cycle and gated on live < max_active_sessions
    # (the WIP-slot check above, which counts every start-pending/creating
    # session), so a spawn from the previous cycle occupies the slot it filled
    # and the next cycle cannot overshoot the pool's max. The order only ever
    # `session new`s a worker and direct-assigns an EXISTING work bead — it mints
    # no molecule root or workflow step, so it can leave no wedged in_progress
    # root behind (the gff-56lh phantom it exists to route around).
    #
    # SILENT FAILURE BECOMES MAIL (crit:90116a548d3b). A spawn or assign that
    # genuinely FAILS records an escalation (mailed once, below). A spawn the
    # idempotency guard declines — a live worker already holds the target — is
    # NOT a failure and escalates nothing; nor is an assign refused because the
    # target was raced by a live worker (exit 2), which is that same guard firing
    # inside sy_pool_assign_bead. A successful hand-off is remembered in
    # $assigned_now so the NEXT cycle can catch one that silently did not take.
    if sy_pool_holder_is_live "$rig" "$target" ""; then
      action="none ($target already held by a live worker — no spawn)"
    else
      sess="$(sy_pool_spawn_brakeman "$rig")"
      if [ -z "$sess" ]; then
        action="spawn FAILED (no session identity captured)"
        escalations="$escalations
- $rig: brakeman spawn returned no session identity — $count claimable bead(s) left unclaimed (demand: $ids)."
      else
        sy_pool_assign_bead "$rig" "$target" "$sess"
        case $? in
          0) action="spawned $sess, direct-assigned $target"
             assigned_now="$assigned_now
$rig $target" ;;
          2) action="spawned $sess, REFUSED to reassign $target (raced by a live worker)" ;;
          *) action="spawned $sess, but direct-assign of $target FAILED"
             escalations="$escalations
- $rig: spawned $sess but the direct-assign of $target was rejected — the fresh worker has nothing to claim." ;;
        esac
      fi
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

# Remember this cycle's hand-offs so the NEXT cycle can catch one that silently did
# not take. Rewritten every cycle (even to empty) so a bead that WAS claimed drops
# out of the memory and is never re-flagged.
#
# ONLY WHEN THE `bd` PATH ACTUALLY RAN (crit:53605636a114). A cursor file exists to
# remember a hand-off, and cloud dispatch makes none — so a city whose every rig is
# cut over must not merely stop USING this file, it must never create it. Gating on
# "did any rig take the `bd` path" and not on "were there hand-offs" keeps the
# rewrite-to-empty semantics intact for a mixed city: a `bd` rig present means the
# file is still rewritten every cycle, exactly as before.
if [ -n "$bd_rigs_seen" ]; then
  mkdir -p "$(dirname "$ASSIGNED_LAST")" 2>/dev/null
  printf '%s\n' "$assigned_now" | awk 'NF' > "$ASSIGNED_LAST" 2>/dev/null
fi

# What this order detected AND did is observed through its own log (gc captures
# order stdout) — the per-rig `action:` line records each spawn + direct-assign.
if [ -n "$report" ]; then
  printf 'pool-spawn: claimable brakeman demand by rig:%s\n' "$report"
fi

# Silent-failure-becomes-mail invariant (crit:90116a548d3b): any dispatch failure
# this cycle — no session identity, a rejected assign, a hand-off still unclaimed a
# full cycle later, or (crit:53605636a114) a cut-over rig whose cloud pool could not
# be read at all — is mailed to the mayor, not left as a log line. ONE consolidated
# mail per cycle (never one per rig) so a wide outage does not flood the mayor's box
# the way a chronically noisy order would.
if [ -n "$escalations" ]; then
  gc mail send mayor \
    -s "pool-spawn: brakeman dispatch failure — demand left unclaimed" \
    -m "The switchyard-ops pool-spawn order could not get claimable brakeman demand into a worker's hands this cycle. This order replaces the controller's dead sling-claim, so each line below is stalled work — a rig whose demand a spawn, an assign, or an unreadable cloud-pool probe left unclaimed, which nothing else will pick up until the next cycle clears it or a human intervenes:$escalations" \
    >/dev/null 2>&1
fi

exit 0
