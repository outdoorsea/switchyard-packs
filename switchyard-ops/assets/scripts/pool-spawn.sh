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
# safe to repeat. Four invariants make it so:
#   - SERIALIZED. A city-local atomic lock covers the complete census → spawn →
#     identity-reconcile → assign transaction. A slow cycle can overlap the next
#     one on the one-minute schedule, but only one may act on capacity.
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
# Session capacity is tri-state, not numeric-by-default: an unreadable, malformed,
# or timed-out roster is UNKNOWN and spawns nothing. A failed `gc | jq` pipeline
# must never collapse to live=0 — that was the gff-9117 spawn-storm trigger.
#
# SILENT FAILURE BECOMES MAIL (crit:90116a548d3b). switchyard-ops holds one
# invariant across every order: a failure the loop cannot self-heal is MAILED to
# the mayor within the cycle, never left as a mere log line nobody reads. This
# order replaces the controller's dead sling-claim, so a hand-off that does not
# happen means work is stalled — exactly the silent stall the invariant exists to
# surface. Three ways a hand-off fails, all escalated here:
#   - no session id returned / its unique requested alias still unresolved in
#     the session roster after about two minutes,
#   - the direct-assign was rejected (a spawned worker left with nothing to claim),
#   - a bead this order direct-assigned a FULL CYCLE AGO is STILL claimable demand
#     (the hand-off silently did not take — the assignee never stuck, or the
#     worker died and released it). This last one is cross-cycle by nature, so it
#     rides a small state file remembering last cycle's hand-offs.
# Repeated identical failure sets are fingerprinted and mailed once until a
# healthy cycle clears the fingerprint; a one-minute failure must not become a
# one-minute mailbox flood.
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
# KNOWN is a different question from LIVE: LIVE asks "does this session occupy a
# WIP slot", KNOWN asks "do I recognise this state at all". An unrecognised state
# fails the census CLOSED (sy_pool_brakeman_live returns rc 2), so every state gc
# can emit must appear here even when it does no work.
#
# `asleep` is exactly that case, and it belongs here and NOT in POOL_LIVE_STATES:
# a drained session is not working, so counting it live would suppress the very
# spawn its absence should trigger. Omitting it cost 12 dispatch cycles on
# 2026-08-12/13 — four drained brakemen (three of them leftover manual spawns)
# made `switchyard` and `switchyard-forge` fail the census every cycle for five
# hours while the escalation mail blamed "unreadable or timed out".
POOL_KNOWN_SESSION_STATES="$POOL_LIVE_STATES suspended closed asleep"
POOL_GC_READ_TIMEOUT="${POOL_GC_READ_TIMEOUT:-30}"
POOL_GC_WRITE_TIMEOUT="${POOL_GC_WRITE_TIMEOUT:-30}"
POOL_SESSION_LOOKUP_TIMEOUT="${POOL_SESSION_LOOKUP_TIMEOUT:-15}"
# The once-per-cycle capacity census, deliberately NOT sharing the budget above.
# POOL_SESSION_LOOKUP_TIMEOUT bounds a lookup paid up to POOL_SPAWN_RECONCILE_
# ATTEMPTS (7) times per spawn, so it has to stay small; this one is paid ONCE
# for the whole cycle, so it can afford to be large enough to actually finish.
# Measured 2026-08-13 on the live city under load ~55: `gc session list --json
# --state all` took 38.6s, and 31.8s even with --template narrowing it to 3
# rows -- the cost is gc's session enumeration, not the payload, so no filter
# fixes it. At the 15s lookup budget that census could never once succeed, and
# every rig fell to "capacity is UNKNOWN. No brakeman was spawned."
POOL_SESSION_CENSUS_TIMEOUT="${POOL_SESSION_CENSUS_TIMEOUT:-60}"
POOL_SPAWN_TIMEOUT="${POOL_SPAWN_TIMEOUT:-90}"
POOL_SPAWN_RECONCILE_ATTEMPTS="${POOL_SPAWN_RECONCILE_ATTEMPTS:-7}"
POOL_SPAWN_RECONCILE_DELAY="${POOL_SPAWN_RECONCILE_DELAY:-20}"
POOL_SPAWN_CYCLE_TIMEOUT="${POOL_SPAWN_CYCLE_TIMEOUT:-300}"

sy_pool_bounded_uint() {
  case "$1" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
  [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le "$3" ] 2>/dev/null
}
sy_pool_bounded_uint "$POOL_GC_READ_TIMEOUT" 1 300 || exit 0
sy_pool_bounded_uint "$POOL_GC_WRITE_TIMEOUT" 1 300 || exit 0
sy_pool_bounded_uint "$POOL_SESSION_LOOKUP_TIMEOUT" 1 300 || exit 0
sy_pool_bounded_uint "$POOL_SESSION_CENSUS_TIMEOUT" 1 300 || exit 0
sy_pool_bounded_uint "$POOL_SPAWN_TIMEOUT" 1 600 || exit 0
sy_pool_bounded_uint "$POOL_SPAWN_RECONCILE_ATTEMPTS" 1 20 || exit 0
sy_pool_bounded_uint "$POOL_SPAWN_RECONCILE_DELAY" 0 120 || exit 0
sy_pool_bounded_uint "$POOL_SPAWN_CYCLE_TIMEOUT" 1 600 || exit 0
# The dispatch lock is released by the cycle deadline. A reconciliation budget
# that cannot fit inside it turns every delayed spawn into a deadline alert,
# so reject configurations where the spawn timeout plus retry delays exceed the
# cycle timeout.
_reconcile_budget=$((POOL_SPAWN_TIMEOUT + (POOL_SPAWN_RECONCILE_ATTEMPTS - 1) * POOL_SPAWN_RECONCILE_DELAY))
[ "$_reconcile_budget" -le "$POOL_SPAWN_CYCLE_TIMEOUT" ] || exit 0

# sy_pool_nonsuspended_rigs — the name of every rig gc is not suspending AND that
# can actually be addressed per-rig, one per line. Mirrors publish-gate's rig
# enumeration, minus suspended rigs (checked two ways so a differently-spelled
# suspend signal still excludes; excluding an active rig only under-reports,
# which is the safe direction for detection).
#
# The HQ rig is excluded, and it is not a suspension case. `gc rig list` reports
# the city itself as a rig (`"hq": true`), but it is NOT addressable through
# `--rig`: `gc bd list --rig <hq-name>` exits 1 with `rig "<name>" not found`,
# because HQ beads are addressed by OMITTING `--rig`. Enumeration and addressing
# disagree, so every enumerated-then-addressed read fails for HQ and only HQ.
#
# That is a deterministic rejection in ~2s, but sy_pool_rig_demand can only
# return rc 2, so the escalation reads "bead demand was unreadable, malformed, or
# timed out" — none of which happened. It failed 17 of 17 cycles on 2026-08-12/13
# and was invisible precisely because it looked like load. A 100% failure rate is
# the tell: real timeouts are stochastic and leave gaps.
#
# Excluding is right rather than special-casing the read, because HQ hosts no
# brakeman pool — it holds the city's own session/mail beads, which are never
# pool demand. Keyed on the `hq` flag, never on the city's name.
sy_pool_nonsuspended_rigs() {
  _raw="$(sy_timeout "$POOL_GC_READ_TIMEOUT" gc rig list --json 2>/dev/null)" || return 2
  [ -n "$_raw" ] || return 2
  # The optional-boolean clauses below are `.x == null`, NOT `has("x")|not`.
  # The two differ on exactly one input — the key PRESENT and JSON null — and
  # that difference is the whole bug. `has("x")` is true for a null value, so
  # `(has("x")|not) or (.x|type=="boolean")` is false||false = FALSE, the `all`
  # collapses, and the function returns 2. rc 2 is reported as "rig roster was
  # unreadable", NOTHING is enumerated and NO rig is spawned into — one null
  # field takes down every healthy rig with it, behind the same misleading
  # message this script exists to eliminate. `.x == null` is true for both the
  # absent key and the null value, while still rejecting a wrong type.
  printf '%s' "$_raw" | jq -e '
    (if type=="array" then . elif type=="object" and (.rigs|type=="array") then .rigs else null end) as $r
    | ($r != null)
      and (all($r[];
        type=="object"
        and (.name|type=="string") and (.name|test("^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"))
        and ((.suspended == null) or (.suspended|type=="boolean"))
        and ((.hq == null) or (.hq|type=="boolean"))
        and ((.state // .status // "")|type=="string")))
      and (($r|map(.name)|length) == ($r|map(.name)|unique|length))' >/dev/null 2>&1 || return 2
  printf '%s' "$_raw" | jq -r '
    (if type=="array" then . else .rigs end)
    | .[]
    | select((.suspended // false) | not)
    | select((.state // .status // "") != "suspended")
    | select((.hq // false) | not)
    | .name' 2>/dev/null || return 2
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
  _raw="$(sy_timeout "$POOL_GC_READ_TIMEOUT" gc bd list --rig "$1" --all --json 2>/dev/null)" || return 2
  [ -n "$_raw" ] || return 2
  printf '%s' "$_raw" | jq -e 'type == "array" or (type == "object" and (.beads | type == "array"))' >/dev/null 2>&1 || return 2
  printf '%s' "$_raw" | jq -e '
    (if type=="array" then . else .beads end) as $b
    | all($b[];
        type=="object"
        and (.id|type=="string") and (.id|test("^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$"))
        and ((.status // "open")|type=="string")
        and ((.assignee // "")|type=="string")
        and ((.metadata // {})|type=="object")
        and ((.metadata["gc.routed_to"] // "")|type=="string")
        and ((.metadata["gc.kind"] // "")|type=="string")
        and ((.metadata["gc.root_bead_id"] // "")|type=="string")
        and ((.blocked_by // [])|type=="array")
        and ((.blocked // false)|type=="boolean")
        and ((.dependencies // [])|type=="array")
        and all((.dependencies // [])[];
          type=="object"
          and ((.type // .dependency_type // "")|type=="string")
          and ((.depends_on_id // .id // "")|type=="string")))
      and (($b|map(.id)|length) == ($b|map(.id)|unique|length))' >/dev/null 2>&1 || return 2
  _demand="$(printf '%s' "$_raw" | jq -r "$POOL_DEMAND_JQ" 2>/dev/null)" || return 2
  printf '%s\n' "$_demand" | awk 'NF'
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
  [ "$_pcd_n" -le 1000000000 ] 2>/dev/null || return 0
  printf '%s' "$_pcd_n"
}

# sy_pool_brakeman_max RIG AGENTS_JSON — RIG's configured brakeman pool ceiling,
# read out of a roster payload the CALLER supplies. The rig is only a jq filter
# here: `gc agent list` is city-wide and rig-independent, so fetching it inside
# this function made every rig re-pay an identical read. It is hoisted to once
# per cycle now, the same way and for the same reason as cloud_token below.
# An empty payload still means "unreadable" and still returns 2, so a failed
# hoisted fetch fails closed exactly as a failed per-rig fetch did. Returns 2
# when the record is unreadable or malformed, so callers fail closed AND surface
# the unknown capacity.
sy_pool_brakeman_max() {
  _raw="${2:-}"
  [ -n "$_raw" ] || return 2
  printf '%s' "$_raw" | jq -e 'type == "array" or (type == "object" and (.agents | type == "array"))' >/dev/null 2>&1 || return 2
  _max="$(printf '%s' "$_raw" | jq -r --arg q "$1/switchyard-ops.brakeman" '
    [(if type=="array" then . else .agents end)[]
      | select((.qualified_name // "") == $q)] as $m
    | if ($m|length) != 1 then empty
      else ($m[0] | ((.pool.max) // .max_active_sessions // empty)
        | select(type=="number" and floor==. and .>=0 and .<=10000))
      end' 2>/dev/null | awk 'NF')" || return 2
  case "$_max" in ''|*[!0-9]*) return 2 ;; esac
  printf '%s' "$_max"
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
  _known_json="$(printf '%s' "$POOL_KNOWN_SESSION_STATES" | jq -Rc 'split(" ")')"
  # SESSIONS_JSON is supplied by the caller — see sy_pool_brakeman_max above for
  # why, and the hoist below for the freshness argument. Reusing one snapshot
  # across rigs is sound because each rig spawns at most once per cycle (the
  # `max > live` branch runs a single spawn, not a loop), so no spawn this cycle
  # can invalidate a LATER rig's count: the jq filters by this rig's template.
  # The reconcile lookups do NOT share it — they hunt a session this cycle just
  # created, so they must read fresh and keep their own fetch.
  _raw="${2:-}"
  [ -n "$_raw" ] || return 2
  printf '%s' "$_raw" | jq -e '
    type == "object" and (.sessions | type == "array") and
    all(.sessions[];
      type=="object" and
      ([.agent,.agent_name,.qualified_name,.template,.state]
       | all(.[]; .==null or type=="string")))' >/dev/null 2>&1 || return 2
  _count="$(printf '%s' "$_raw" | jq -r --arg q "$1/switchyard-ops.brakeman" --argjson live "$_states_json" --argjson known "$_known_json" '
    [ (.sessions // [])[]
      | (.agent // .agent_name // .qualified_name // "") as $n
      | select( (.template // "") == $q
                or $n == $q
                or ($n | startswith($q + "-adhoc-")) )
    ] as $matching
    | if all($matching[]; (.state|type)=="string" and .state!="" and (.state as $st | ($known|index($st))!=null))
      then [$matching[] | select(.state as $st | ($live|index($st))!=null)] | length
      else empty end' 2>/dev/null)" || return 2
  case "$_count" in ''|*[!0-9]*) return 2 ;; esac
  [ "$_count" -le 10000 ] 2>/dev/null || return 2
  printf '%s' "$_count"
}

# sy_pool_brakeman_identity_for_alias RIG ALIAS — resolve exactly the session
# created with ALIAS. A before/after set difference is not sufficient: another
# controller or operator can concurrently spawn the same template outside this
# script's lock, making "first new pool member" the wrong worker. A unique alias
# is the idempotency token that ties reconciliation to this spawn request.
sy_pool_brakeman_identity_for_alias() {
  _raw="$(sy_timeout "$POOL_SESSION_LOOKUP_TIMEOUT" gc session list --json --state all 2>/dev/null)" || return 2
  [ -n "$_raw" ] || return 2
  printf '%s' "$_raw" | jq -e '
    type == "object" and (.sessions | type == "array") and
    all(.sessions[];
      type=="object" and
      ([.agent,.agent_name,.qualified_name,.template,.state,.alias,.name,.session_name,.id,.session_id]
       | all(.[]; .==null or type=="string")))' >/dev/null 2>&1 || return 2
  _states_json="$(printf '%s' "$POOL_LIVE_STATES" | jq -Rc 'split(" ")')"
  # $qa: current gc registers the requested alias QUALIFIED as
  # `<rig>/switchyard-ops.<alias>`; older builds keep it bare. Both are this
  # request's unique nonce, so both prove the record — and on modern gc the
  # record's own `.name` IS that qualified alias, so the identity select's
  # `. == $qa` arm is what accepts it. The select stays otherwise exact: an
  # identity that is neither this request's alias (either form) nor an
  # adhoc-shaped pool name is refused, because the shared roster is where an
  # unrelated session could wear our alias.
  printf '%s' "$_raw" | jq -r --arg q "$1/switchyard-ops.brakeman" --arg a "$2" --arg qa "$1/switchyard-ops.$2" --argjson live "$_states_json" '
    [ (.sessions // [])[] | select((.alias // "") as $al | $al == $a or $al == $qa) ] as $records
    | if ($records | length) != 1 then empty
      else ($records[0]
        | (.agent // .agent_name // .qualified_name // "") as $n
        | select((.template // "") == $q
                 or $n == $q
                 or ($n | startswith($q + "-adhoc-")))
        | select((.state // "") as $st | ($live | index($st)) != null)
        | (.name // .session_name // .id // .session_id // .qualified_name // .agent // "")
        | select(type == "string")
        | select(. == $a or . == $qa
                 or (startswith($q + "-adhoc-") and
                     ((ltrimstr($q + "-adhoc-")) | test("^[A-Za-z0-9_.-]+$")))))
      end' 2>/dev/null || return 2
}

# POOL_SESSION_ID_JQ — pull a session identity out of whatever `gc session new`
# prints. gc builds differ (some emit a bare session object, some a
# `{"session":{...}}` envelope), so try the common identity fields; a non-JSON
# answer just yields nothing here and the shell falls back to a plain-text scan.
POOL_SESSION_ID_JQ='
  (if type=="object" then (.session // .) else empty end)
  | (.qualified_name // .name // .session_name // .id // .session_id // "")'

# sy_pool_spawn_brakeman RIG SEQ — spawn ONE adhoc brakeman for RIG and echo its
# session identity (empty when the identity cannot be captured). Requests JSON and
# a unique public alias so an accepted-but-delayed spawn can be reconciled without
# confusing it with another controller's concurrent pool member. The default
# generated session name is based on its pool
# (`<rig>/switchyard-ops.brakeman-adhoc-<suffix>`, the scratch-reaper
# convention), so the plain-text fallback accepts only the exact unique alias or
# a token that begins with `<rig>/` — never `[]`, a usage line, or human prose.
sy_pool_spawn_brakeman() {
  # `gc session new` applies its 64-character limit to the QUALIFIED name it
  # registers — `<rig>/switchyard-ops.<alias>` — NOT to the bare alias passed on
  # the command line. Budgeting the bare string satisfies this function's own
  # assertion and is then rejected by gc for EVERY rig, because the prefix alone
  # is 26 characters for `switchyard` and 32 for `switchyard-forge`.
  #
  # A rejected spawn is worse than a refused one: reconciliation goes on to hunt
  # an alias that was never registered. A rejection returns at once, so the 90s
  # POOL_SPAWN_TIMEOUT is precisely what is NOT spent; what is spent is the whole
  # reconcile budget below — 7 attempts, which sleep between attempts and so span
  # 6 x POOL_SPAWN_RECONCILE_DELAY (120s), plus up to 7 x
  # POOL_SESSION_LOOKUP_TIMEOUT (15s) in the lookups themselves. Per rig that
  # reaches ~225s against a 300s POOL_SPAWN_CYCLE_TIMEOUT, and the line 221 guard
  # bounds only ONE rig's budget, so two rigs can overrun it and the cycle is
  # killed mid-sweep with the second rig never completing an attempt.
  #
  # (Measured 2026-08-13 on the live city: the bare-length budget emitted a
  # 55-character alias for `switchyard` and 57 for `switchyard-forge` — the width
  # varies because `cksum` is 8 digits for one rig and 10 for the other, and the
  # nonce still carried the shell PID then (1-5 digits) — so every spawn was
  # rejected with "exceeds max length 64", on stderr, which this call discards.
  # The claim pool sat at 138 for hours while each cycle either exited 0 on lock
  # contention or died on the deadline.)
  _qual_prefix="$1/switchyard-ops."
  _alias_budget=$(( 64 - ${#_qual_prefix} ))
  _seq="${2:-1}"
  case "$_seq" in ''|*[!0-9]*) return 1 ;; esac

  # The nonce is deliberately FIXED-WIDTH. It used to be `$$-$(date +%s)`, whose
  # length tracks the PID's, and that one variable width cost three consecutive
  # fixes — each of which moved a constant guessing the narrowest PID the kernel
  # would ever hand out, and each described in-file as correcting the previous
  # one's error in the opposite direction. There is no correct value for that
  # guess: a fresh PID namespace allocates 1, 2, 3…, while the host this ran on
  # had never issued a PID below 259. So the SAME rig spawns at one PID width and
  # is declared PERMANENTLY REFUSED — remedy: rename the rig, which is
  # irreversible — at another.
  #
  # `$$` bought nothing the random field does not already provide. It separated
  # two controllers racing on one host inside one second; the 8-16 hex drawn from
  # /dev/urandom below separates them by at least 32 bits, on any host, and the
  # refusal in this function is precisely what guarantees those 8 hex are always
  # there. Dropping it makes `${#_nonce_base}` a constant, which makes the floor
  # exact instead of a guess and deletes the bug class rather than re-tuning it.
  _nonce_base="${POOL_SPAWN_ALIAS_NONCE:-$(date +%s)}"
  case "$_nonce_base" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9_.-]*) return 1 ;; esac

  # `ps-<nonce>-<random>-<seq>`: 3 for `ps-`, 1 for each of the two separators.
  #
  # Two DIFFERENT questions, deliberately answered by two different numbers.
  # Collapsing them into one is what made the earlier attempts at this wrong in
  # alternating directions:
  #
  #   "refuse this spawn?"        — must use the LIVE widths, `_hexlen`. Keying
  #                                 the refusal on worst-case reserves
  #                                 permanently refuses rigs whose alias actually
  #                                 fits (a 17-char rig spawns on every reachable
  #                                 cycle position today).
  #   "will the refusal clear?"   — must use the NARROWEST widths this rig can
  #                                 reach without operator action, `_hexbest`.
  #                                 Keying this on the live ones calls a
  #                                 self-clearing fault permanent and sends
  #                                 someone to rename a rig, which is
  #                                 irreversible across anchor-keyed worktrees,
  #                                 CLOUD_POOL_RIGS, RIG_PROJECTS and every
  #                                 bead's gc.routed_to.
  #
  # They now differ in exactly ONE term. `_seq` is `spawn_seq`, scoped to the
  # LOCKED CYCLE and shared across rigs, so its width ticks 1 -> 2 at the tenth
  # spawn of a cycle and resets next cycle: position-dependent, and therefore
  # self-clearing. `_hexbest` is that term at 1. The nonce contributes the same
  # width to both, because a fixed-width one cannot vary between them — which is
  # what dropping `$$` above bought, and it is why no constant appears here.
  _hexlen=$(( _alias_budget - 3 - ${#_nonce_base} - 1 - 1 - ${#_seq} ))
  _hexbest=$(( _alias_budget - 3 - ${#_nonce_base} - 1 - 1 - 1 ))
  if [ "$_hexlen" -gt 16 ]; then _hexlen=16; fi

  # `ps-<nonce>-<random>-<seq>`. Three things were cut to make the budget: the
  # rig cksum and its separator (9-11 characters — `cksum` is 8-10 digits wide),
  # which was pure redundancy because the qualified name already namespaces the
  # alias by rig; 8 characters of the `pool-spawn-` prefix; and the PID, above.
  # Together those leave `switchyard` (10 characters) 22 hex, clamped down to 16
  # with room to spare, and `switchyard-forge` (16) exactly 16 — it never reaches
  # the clamp, and from the tenth spawn of a cycle (2-digit seq) it takes 15.
  # Both stay inside 64; forge simply has NO margin, so it is the rig to check
  # first if these fixed fields ever grow again.
  #
  # What must survive that squeeze is the RANDOM part. Reconciliation matches on
  # the WHOLE alias, not on the random alone (see the identity lookup below), but
  # the random is what keeps the whole alias unique when the rest of it does not:
  # `_nonce_base` defaults to `$(date +%s)`, which separates spawns across
  # seconds and nothing else, and a pinned POOL_SPAWN_ALIAS_NONCE — which only a
  # small minority of the suite's spawns set — does not separate them at all. Two
  # controllers racing inside one second, on this host or another, are told apart
  # by the random alone. So it is sized from whatever the budget leaves.
  # Below 8 hex (32 bits) the token stops being a credible idempotency proof, so
  # refuse rather than register a spawn whose alias could collide. The refusal
  # keys on `_hexlen` — the budget ACTUALLY free this cycle — so a rig whose
  # alias fits today keeps spawning; nothing is narrowed.
  if [ "$_hexlen" -lt 8 ]; then
    # `_hexbest` answers the second question. Short even at seq 1, the narrowest
    # cycle position this rig can reach, means no amount of retrying helps and a
    # human has to act; short only at THIS cycle's width means the next cycle
    # clears it, and saying otherwise is the false-permanent verdict this whole
    # change exists to remove. Return 3 only for the first case; the second takes
    # the transient rc 1 alongside every other self-clearing refusal here.
    if [ "$_hexbest" -lt 8 ]; then
      # Both remedies below are LIVE, because the refusal keys on the live nonce
      # width: pinning a shorter POOL_SPAWN_ALIAS_NONCE genuinely raises
      # `_hexlen`. (An earlier revision keyed the decision on a constant reserve,
      # which silently made that remedy inert while still printing it, leaving
      # the irreversible rename as the only thing that worked.) "Raise gc's
      # alias limit" is NOT offered: the 64 is hard-coded in `_alias_budget`
      # above, so it cannot move without editing this script.
      #
      # The prescribed count is the MINIMUM that clears the permanent verdict, so
      # it is stated as such: obeying it exactly lands the rig at `_hexbest` 8,
      # which spawns while spawn_seq is one digit and is refused — correctly, as
      # transient rc 1 — after that. An operator who is not told this reads that
      # later refusal as load and has no way back to this diagnostic.
      printf '%s\n' "pool-spawn: $1: alias-budget refusal — the qualified alias \`${_qual_prefix}ps-<nonce>-<random>-<seq>\` cannot hold an 8-hex (32-bit) idempotency token inside gc's 64-character limit. budget=$_alias_budget after the ${#_qual_prefix}-character prefix; nonce=${#_nonce_base}, seq=${#_seq} leave $_hexlen hex against a floor of 8 — short by $(( 8 - _hexlen )). This does NOT clear on retry: at seq 1, the narrowest cycle position this rig can reach, it still leaves $_hexbest. Remedy: free $(( 8 - _hexbest )) character(s) from the qualified alias — that is the MINIMUM, and it leaves this rig spawning only while spawn_seq is one digit (the first nine spawns of a cycle, shared across rigs) and refused as ordinary load after that; one further character covers a two-digit seq as well. To free them, pin a shorter POOL_SPAWN_ALIAS_NONCE (currently ${#_nonce_base} characters; the default is \$(date +%s), i.e. 10, and does not vary) and/or shorten the rig name (currently ${#1} characters)." >&2
      return 3
    fi
    return 1
  fi

  _random="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  case "$_random" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#_random}" -eq 16 ] || return 1
  _random="$(printf '%s' "$_random" | cut -c1-"$_hexlen")"
  [ "${#_random}" -eq "$_hexlen" ] || return 1
  _spawn_alias="ps-${_nonce_base}-${_random}-${_seq}"
  # A timed-out client does not prove the server rejected the spawn. Regardless
  # of this command's exit status, reconcile its unique alias below.
  # Current gc builds register an adhoc alias QUALIFIED — the response and the
  # roster both carry `<rig>/switchyard-ops.<requested>` — while older builds
  # echo it verbatim. Accept exactly those two forms and nothing else; the
  # qualified form is still bound to this request's random nonce, so it is the
  # same idempotency proof. (Measured 2026-08-12 on the live city: the bare-form
  # assertion made every SUCCESSFUL spawn read as "no session identity", so
  # pool-spawn spawned a worker per cycle, disowned each one, and mailed a
  # dispatch failure while 116 claimable beads sat in the pool.)
  _qualified_alias="${_qual_prefix}${_spawn_alias}"
  # Assert the string gc will actually validate, not the one we hand it. This is
  # the assertion whose bare-string form caused the outage described above.
  [ "${#_qualified_alias}" -le 64 ] || return 1
  _out="$(sy_timeout "$POOL_SPAWN_TIMEOUT" gc session new "$1/switchyard-ops.brakeman" --alias "$_spawn_alias" --json --no-attach 2>/dev/null)" || _out=""
  _json_alias="$(printf '%s' "$_out" | jq -r '(if type=="object" then (.session // .) else empty end) | (.alias // "")' 2>/dev/null | head -n1)"
  _id="$(printf '%s' "$_out" | jq -r "$POOL_SESSION_ID_JQ" 2>/dev/null | awk 'NF' | head -n1)"
  # A JSON identity is usable immediately only when the response proves it came
  # from THIS request's random alias (bare or qualified). Otherwise roster
  # reconciliation is the sole authority; a pool-shaped name in progress/error
  # text is not enough.
  case "$_json_alias" in
    "$_spawn_alias"|"$_qualified_alias") ;;
    *) _id="" ;;
  esac
  case "$_id" in
    "$_spawn_alias"|"$_qualified_alias") ;;
    "$1/switchyard-ops.brakeman-adhoc-"*)
      _suffix=${_id#"$1/switchyard-ops.brakeman-adhoc-"}
      printf '%s' "$_suffix" | grep -Eq '^[[:alnum:]_.-]+$' || _id="" ;;
    *)
      # The alias check above already proved the response is THIS spawn's, and
      # current gc identifies the session by registry id (`gf-…` / `s-gf-…`),
      # not by a pool-shaped name — so with the alias proven, any single sane
      # token is an acceptable identity. Without that proof _id is already "".
      printf '%s' "$_id" | grep -Eq '^[A-Za-z0-9/_.-]+$' || _id="" ;;
  esac
  if [ -z "$_id" ]; then
    _id="$(printf '%s\n' "$_out" | tr ' \t' '\n\n' | awk -v a="$_spawn_alias" -v q="$_qualified_alias" '$0==a || $0==q {print; exit}')"
  fi
  if [ -n "$_id" ]; then
    printf '%s' "$_id"
    return 0
  fi

  # `session new --no-attach` can accept the spawn while its stdout contains no
  # identity and the session registry catches up asynchronously. Reconcile the
  # exact requested alias for roughly two minutes before calling that a failure;
  # otherwise the next cycle sees stale capacity and spawns another worker for
  # the same demand. Never infer identity from an unrelated new pool member.
  _attempt=1
  while [ "$_attempt" -le "$POOL_SPAWN_RECONCILE_ATTEMPTS" ]; do
    [ "$_attempt" -eq 1 ] || sleep "$POOL_SPAWN_RECONCILE_DELAY"
    _candidate="$(sy_pool_brakeman_identity_for_alias "$1" "$_spawn_alias")" || _candidate=""
    if [ -n "$_candidate" ]; then
      printf '%s' "$_candidate"
      return 0
    fi
    _attempt=$((_attempt + 1))
  done
  return 1
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
  _raw="$(sy_timeout "$POOL_SESSION_LOOKUP_TIMEOUT" gc session list --json --state all 2>/dev/null)" || return 0
  [ -n "$_raw" ] || return 0                       # can't read the roster → refuse
  printf '%s' "$_raw" | jq -e '
    type=="object" and (.sessions|type=="array") and
    all(.sessions[];
      type=="object" and
      ([.agent,.agent_name,.qualified_name,.name,.alias,.id,.session_id,.state]
       | all(.[]; .==null or type=="string")))' >/dev/null 2>&1 || return 0
  _states_json="$(printf '%s' "$POOL_LIVE_STATES" | jq -Rc 'split(" ")')"
  _known_json="$(printf '%s' "$POOL_KNOWN_SESSION_STATES" | jq -Rc 'split(" ")')"
  _n="$(printf '%s' "$_raw" | jq -r --arg a "$1" --argjson live "$_states_json" --argjson known "$_known_json" '
    [ (.sessions // [])[]
      | select( ((.agent // "") == $a) or ((.agent_name // "") == $a)
                or ((.qualified_name // "") == $a) or ((.name // "") == $a)
                or ((.alias // "") == $a) or ((.id // "") == $a)
                or ((.session_id // "") == $a) )
    ] as $matching
    | if all($matching[]; (.state|type)=="string" and .state!="" and (.state as $st | ($known|index($st))!=null))
      then [$matching[] | select(.state as $st | ($live|index($st))!=null)] | length
      else empty end' 2>/dev/null)"
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
# spawn ago. Failed, empty, malformed, wrong-shaped, missing, or duplicate ledger
# results all refuse the assignment: inability to prove a bead unassigned can
# never authorize overwriting its holder.
sy_pool_holder_is_live() {
  _raw="$(sy_timeout "$POOL_GC_READ_TIMEOUT" gc bd list --rig "$1" --json 2>/dev/null)" || return 0
  [ -n "$_raw" ] || return 0
  printf '%s' "$_raw" | jq -e 'type == "array" or (type == "object" and (.beads | type == "array"))' >/dev/null 2>&1 || return 0
  _holder="$(printf '%s' "$_raw" | jq -r --arg id "$2" '
    [ (if type=="array" then . else .beads end)[] | select((.id // "") == $id) ] as $m
    | if ($m | length) != 1 then "__POOL_UNKNOWN__"
      elif (($m[0].assignee // null) != null and (($m[0].assignee|type) != "string"))
        then "__POOL_UNKNOWN__"
      else ($m[0].assignee // "") end' 2>/dev/null)" || return 0
  [ "$_holder" = "__POOL_UNKNOWN__" ] && return 0
  [ -n "$_holder" ] || return 1        # exactly one unassigned bead → clear
  [ "$_holder" = "$3" ] && return 1    # already ours → not a steal
  sy_pool_assignee_live "$_holder"     # a real other holder → live? then hands off
}

# sy_pool_assign_bead RIG BEAD SESSION — direct-assign BEAD to SESSION, the
# hand-off gastown's dead sling-claim would have made. The re-read above avoids
# needless workers, but correctness comes from Beads' atomic `--claim`: using the
# session identity as `--actor` makes a competing claim win-or-fail rather than
# allowing an unconditional assignee update to steal it. `gc bd list`/`update` from the city root see only the town
# ledger, so the write names its rig explicitly (the same rule publish-gate
# follows). Return codes let the caller report the outcome honestly:
#   0 — assigned; 2 — REFUSED (bead held by a live/unverifiable worker, so the
#   order stood down rather than steal it); other — the write itself failed.
sy_pool_assign_bead() {
  if sy_pool_holder_is_live "$1" "$2" "$3"; then
    return 2
  fi
  sy_timeout "$POOL_GC_WRITE_TIMEOUT" gc bd update --rig "$1" "$2" --actor "$3" --claim >/dev/null 2>&1
}

# --- main: enumerate rigs, identify claimable demand, spawn + assign ----------

command -v jq >/dev/null 2>&1 || exit 0   # every read below is jq-shaped

# Serialize the entire census→spawn→reconcile transaction. The order runs every
# minute, while a slow session census or post-spawn reconciliation can take more
# than one minute; without a city-local lock, overlapping cycles both observe the
# same free slot and both spawn.
#
# Prefer an OS advisory lock: it is acquired atomically before the child starts
# and released by the kernel when that process exits or crashes. There is no
# mkdir→pid-file initialization window, stale artifact to reap, or PID-reuse
# heuristic. macOS provides lockf; Linux normally provides flock. The marker
# prevents the locked child from wrapping itself recursively.
POOL_SPAWN_LOCK="$(sy_state_dir)/pool-spawn.advisory.lock"
mkdir -p "$(dirname "$POOL_SPAWN_LOCK")" || exit 1
POOL_SPAWN_CYCLE_ALERT="$(sy_state_dir)/pool-spawn.cycle-timeout-alert"
POOL_SPAWN_CYCLE_EPOCH="$(sy_state_dir)/pool-spawn.cycle-recovery-epoch"
POOL_SPAWN_CYCLE_STATE_LOCK="$(sy_state_dir)/pool-spawn.cycle-state.lock"
POOL_SPAWN_ALERT_STATE="$(sy_state_dir)/pool-spawn.alert-fingerprint"
ASSIGNED_LAST="$(sy_state_dir)/pool-spawn.assigned-last"

sy_pool_cleanup_state_temps() {
  rm -f "$POOL_SPAWN_ALERT_STATE.tmp."* "$ASSIGNED_LAST.tmp."* 2>/dev/null
  rm -rf "$(dirname "$ASSIGNED_LAST")/.pool-dispatch-state."* 2>/dev/null
}

sy_pool_cleanup_cycle_state_temps() {
  rm -f "$POOL_SPAWN_CYCLE_ALERT.tmp."* "$POOL_SPAWN_CYCLE_EPOCH.tmp."* 2>/dev/null
  rm -rf "$(dirname "$POOL_SPAWN_CYCLE_ALERT")/.pool-cycle-state."* 2>/dev/null
}

sy_pool_atomic_state_write() {
  _state_path="$1"; _state_value="$2"
  case "$_state_path" in
    "$POOL_SPAWN_CYCLE_ALERT"|"$POOL_SPAWN_CYCLE_EPOCH") _state_prefix=.pool-cycle-state ;;
    *) _state_prefix=.pool-dispatch-state ;;
  esac
  _state_tmpdir="$(mktemp -d "$(dirname "$_state_path")/${_state_prefix}.XXXXXX" 2>/dev/null)" || return 1
  chmod 700 "$_state_tmpdir" 2>/dev/null || { rm -rf "$_state_tmpdir"; return 1; }
  _state_tmp="$_state_tmpdir/value"
  trap 'rm -rf "$_state_tmpdir" 2>/dev/null; exit 129' HUP
  trap 'rm -rf "$_state_tmpdir" 2>/dev/null; exit 130' INT
  trap 'rm -rf "$_state_tmpdir" 2>/dev/null; exit 143' TERM
  trap 'rm -rf "$_state_tmpdir" 2>/dev/null' 0
  _state_rc=1
  if printf '%s\n' "$_state_value" >"$_state_tmp" 2>/dev/null &&
    mv "$_state_tmp" "$_state_path" 2>/dev/null; then
    _state_rc=0
  fi
  rm -rf "$_state_tmpdir" 2>/dev/null
  _state_tmp=""; _state_tmpdir=""
  trap - 0 HUP INT TERM
  return "$_state_rc"
}

# Timeout and recovery transitions use a second advisory lock. Each outer cycle
# captures the current recovery epoch before taking the dispatch lock. A late
# timeout reporter is ignored after a newer healthy cycle advances that epoch;
# concurrent timeout reporters from the same incident share one fingerprint.
sy_pool_cycle_state_worker() {
  _action="$1"; _captured="$2"
  sy_pool_cleanup_cycle_state_temps
  _current="$(cat "$POOL_SPAWN_CYCLE_EPOCH" 2>/dev/null || true)"
  case "$_current" in ''|*[!0-9]*) _current=0 ;; esac
  case "$_captured" in ''|*[!0-9]*) _captured=0 ;; esac
  if [ "$_action" = capture ]; then
    printf '%s' "$_current"
    return 0
  fi
  if [ "$_action" = success ]; then
    _next=$((_current + 1))
    sy_pool_atomic_state_write "$POOL_SPAWN_CYCLE_EPOCH" "$_next" || return 1
    rm -f "$POOL_SPAWN_CYCLE_ALERT" "$POOL_SPAWN_CYCLE_ALERT.tmp."* 2>/dev/null
    return 0
  fi
  [ "$_action" = timeout ] || return 2
  [ "$_current" = "$_captured" ] || return 0   # a later healthy cycle recovered
  _cycle_fp="cycle-timeout:epoch:${_captured}"
  [ "$(cat "$POOL_SPAWN_CYCLE_ALERT" 2>/dev/null || true)" = "$_cycle_fp" ] && return 0
  if sy_timeout "$POOL_GC_WRITE_TIMEOUT" gc mail send mayor \
    -s "pool-spawn: dispatch cycle exceeded its deadline" \
    -m "The pool-spawn transaction exceeded its ${POOL_SPAWN_CYCLE_TIMEOUT}s wall-clock deadline and was terminated so it could not retain the advisory lock across scheduler cycles. A spawn or alias reconciliation may be unresolved; the next cycle will fail closed against the live session census before dispatching." \
    >/dev/null 2>&1; then
    sy_pool_atomic_state_write "$POOL_SPAWN_CYCLE_ALERT" "$_cycle_fp"
  fi
}

# This mode is entered only under POOL_SPAWN_CYCLE_STATE_LOCK by the parent.
if [ -n "${POOL_SPAWN_CYCLE_STATE_ACTION:-}" ]; then
  sy_pool_cycle_state_worker "$POOL_SPAWN_CYCLE_STATE_ACTION" "${POOL_SPAWN_CYCLE_EPOCH_CAPTURE:-0}"
  exit $?
fi

sy_pool_cycle_state_run() {
  _action="$1"; _epoch="$2"
  _state_wait=$((POOL_GC_WRITE_TIMEOUT + 5))
  _state_bound=$((POOL_GC_WRITE_TIMEOUT * 2 + 12))
  if command -v lockf >/dev/null 2>&1; then
    sy_timeout "$_state_bound" lockf -t "$_state_wait" "$POOL_SPAWN_CYCLE_STATE_LOCK" \
      env POOL_SPAWN_CYCLE_STATE_ACTION="$_action" POOL_SPAWN_CYCLE_EPOCH_CAPTURE="$_epoch" /bin/sh "$0"
    return $?
  fi
  if command -v flock >/dev/null 2>&1; then
    sy_timeout "$_state_bound" flock -w "$_state_wait" "$POOL_SPAWN_CYCLE_STATE_LOCK" \
      env POOL_SPAWN_CYCLE_STATE_ACTION="$_action" POOL_SPAWN_CYCLE_EPOCH_CAPTURE="$_epoch" /bin/sh "$0"
    return $?
  fi
  return 1
}

# The dispatch-lock wrapper enters this mode after atomically committing a
# child:0 marker but before releasing the dispatch lock.
if [ -n "${POOL_SPAWN_CYCLE_STATE_REQUEST:-}" ]; then
  sy_pool_cycle_state_run "$POOL_SPAWN_CYCLE_STATE_REQUEST" "${POOL_SPAWN_CYCLE_EPOCH_CAPTURE:-0}"
  exit $?
fi

sy_pool_report_cycle_timeout() {
  sy_pool_cycle_state_run timeout "$_cycle_epoch"
}

_cycle_epoch="$(sy_pool_cycle_state_run capture 0)" || exit 74
case "$_cycle_epoch" in ''|*[!0-9]*) exit 74 ;; esac

if [ "${POOL_SPAWN_LOCK_HELD:-}" != "1" ]; then
  _lock_tmpdir="$(mktemp -d "$(dirname "$POOL_SPAWN_LOCK")/.pool-lock.XXXXXX" 2>/dev/null)" || exit 74
  chmod 700 "$_lock_tmpdir" 2>/dev/null || { rm -rf "$_lock_tmpdir"; exit 74; }
  _lock_err="$_lock_tmpdir/error"
  _lock_status="$_lock_tmpdir/status"

  sy_pool_finish_lock() {
    _lock_rc="$1"
    # The outer watchdog is authoritative. It may kill the status writer at any
    # byte boundary, so no marker (complete or partial) can override rc=124.
    if [ "$_lock_rc" -eq 124 ]; then
      rm -rf "$_lock_tmpdir"
      sy_pool_report_cycle_timeout
      exit 124
    fi
    if [ -f "$_lock_status" ]; then
      _child_rc="$(cat "$_lock_status" 2>/dev/null)"
      case "$_child_rc" in
        child:*) _child_rc=${_child_rc#child:}; case "$_child_rc" in ''|*[!0-9]*) _child_rc=74 ;; esac ;;
        *) _child_rc=74 ;;
      esac
      [ -s "$_lock_err" ] && cat "$_lock_err" >&2
      rm -rf "$_lock_tmpdir"
      exit "$_child_rc"
    fi
    if [ "$_lock_rc" -eq 75 ]; then
      rm -rf "$_lock_tmpdir"
      exit 0                            # contention: locked child never ran
    fi
    [ -s "$_lock_err" ] && cat "$_lock_err" >&2
    rm -rf "$_lock_tmpdir"
    exit "$_lock_rc"
  }

  if command -v lockf >/dev/null 2>&1; then
    sy_timeout "$POOL_SPAWN_CYCLE_TIMEOUT" lockf -t 0 "$POOL_SPAWN_LOCK" \
      /bin/sh -c '_status=$1; _tmp="${_status}.tmp"; _script=$2; _epoch=$3; shift 3; env POOL_SPAWN_LOCK_HELD=1 /bin/sh "$_script" "$@"; _rc=$?; printf "child:%s\n" "$_rc" >"$_tmp" && mv "$_tmp" "$_status" || { rm -f "$_tmp"; exit 74; }; if [ "$_rc" -eq 0 ]; then env POOL_SPAWN_CYCLE_STATE_REQUEST=success POOL_SPAWN_CYCLE_EPOCH_CAPTURE="$_epoch" /bin/sh "$_script" || { printf "child:74\n" >"$_tmp" && mv "$_tmp" "$_status" || exit 74; }; fi; exit 0' \
      sh "$_lock_status" "$0" "$_cycle_epoch" "$@" 2>"$_lock_err"
    sy_pool_finish_lock "$?"
  fi
  if command -v flock >/dev/null 2>&1; then
    sy_timeout "$POOL_SPAWN_CYCLE_TIMEOUT" flock -E 75 -n "$POOL_SPAWN_LOCK" \
      /bin/sh -c '_status=$1; _tmp="${_status}.tmp"; _script=$2; _epoch=$3; shift 3; env POOL_SPAWN_LOCK_HELD=1 /bin/sh "$_script" "$@"; _rc=$?; printf "child:%s\n" "$_rc" >"$_tmp" && mv "$_tmp" "$_status" || { rm -f "$_tmp"; exit 74; }; if [ "$_rc" -eq 0 ]; then env POOL_SPAWN_CYCLE_STATE_REQUEST=success POOL_SPAWN_CYCLE_EPOCH_CAPTURE="$_epoch" /bin/sh "$_script" || { printf "child:74\n" >"$_tmp" && mv "$_tmp" "$_status" || exit 74; }; fi; exit 0' \
      sh "$_lock_status" "$0" "$_cycle_epoch" "$@" 2>"$_lock_err"
    sy_pool_finish_lock "$?"
  fi
  rm -rf "$_lock_tmpdir"

  # An unsupported host fails closed. Do not invent a racy PID-file lock: a
  # quiet stall is safer than duplicate LLM sessions, and loop-health surfaces
  # the missing dispatch. Supported production hosts take one branch above.
  exit 0
fi

# Only the lock-owning child may reap state temporaries. A timed-out parent is
# already outside the dispatch lock; globbing there could delete a successor's
# live atomic-write temp after that successor acquires the lock.
sy_pool_cleanup_state_temps

# Self-test hook: prove that a locked child returning lockf/flock's contention
# code is propagated as a child result rather than mistaken for contention.
if [ -n "${POOL_SPAWN_TEST_CHILD_EXIT:-}" ]; then
  case "$POOL_SPAWN_TEST_CHILD_EXIT" in ''|*[!0-9]*) exit 74 ;; esac
  exit "$POOL_SPAWN_TEST_CHILD_EXIT"
fi

# Cross-cycle memory of the beads this order direct-assigned LAST cycle, one
# `<rig> <bead>` per line. A bead still in the demand set a full cycle after we
# handed it off means the hand-off silently did not take — the fourth failure
# mode the immediate spawn/assign checks cannot see. Only successful hand-offs are
# tracked (a bead on a full-slot rig is busy, not stalled), so a persistently
# saturated pool never mails.
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

# The capacity census, hoisted for the same reason as cloud_token above: both gc
# reads are CITY-WIDE and rig-independent — the rig appears only as a `jq --arg`
# filter inside the two functions — so issuing them per rig re-paid an identical
# payload once for every rig in the roster.
#
# This is not only waste. Measured on the live city under load ~55 (2026-08-13):
# `gc session list --json --state all` took 38.6s against a 15s per-rig budget,
# so the census could never complete, every rig took the `live_rc != 0` branch,
# and the cycle mailed "session census was unreadable or timed out, so pool
# capacity is UNKNOWN. No brakeman was spawned." for all of them — a total
# dispatch outage produced entirely by a budget that no longer fitted the call.
#
# Hoisting is what makes a budget that DOES fit affordable: the old worst case
# was 4 rigs x (30s + 15s) = 180s of census against a 300s cycle; the new one is
# 30s + 60s = 90s, paid once, with room left for the spawns themselves. A larger
# timeout without the hoist would simply have multiplied.
#
# An empty payload is passed through deliberately: both functions treat it as
# "unreadable" and return 2, so a failed hoisted read fails closed per rig
# exactly as the per-rig read did, with the same escalation text.
agents_census="$(sy_timeout "$POOL_GC_READ_TIMEOUT" gc agent list --json 2>/dev/null)" || agents_census=""
sessions_census="$(sy_timeout "$POOL_SESSION_CENSUS_TIMEOUT" gc session list --json --state all 2>/dev/null)" || sessions_census=""

report=""
escalations=""    # per-rig silent failures to mail the mayor this cycle
assigned_now=""   # `<rig> <bead>` hand-offs made this cycle, for next cycle's check
assigned_preserved="" # prior rows whose current demand could not be read
assigned_stalled=""   # prior rows whose alert has not yet been confirmed delivered
bd_rigs_seen=""   # did the local-`bd` path run for ANY rig this cycle?
spawn_seq=0        # monotonic suffix for every spawn alias in this locked cycle
rigs="$(sy_pool_nonsuspended_rigs)"; rigs_rc=$?
if [ "$rigs_rc" -ne 0 ]; then
  escalations="$escalations
- city: rig roster was unreadable, malformed, or timed out, so demand and capacity are UNKNOWN. No brakeman was spawned."
fi
for rig in $rigs; do
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

    max="$(sy_pool_brakeman_max "$rig" "$agents_census")"; max_rc=$?
    if [ "$max_rc" -ne 0 ]; then
      report="$report
- $rig: $depth claimable cloud-pool bead(s), WIP slot UNKNOWN
    dispatch: cloud pool (no bd ledger, no cursor file)
    action: none (agent capacity unreadable; capacity fails closed)"
      escalations="$escalations
- $rig: brakeman max-active capacity was unreadable, malformed, or timed out. No brakeman was spawned."
      continue
    fi
    live="$(sy_pool_brakeman_live "$rig" "$sessions_census")"; live_rc=$?
    if [ "$live_rc" -ne 0 ]; then
      report="$report
- $rig: $depth claimable cloud-pool bead(s), WIP slot UNKNOWN
    dispatch: cloud pool (no bd ledger, no cursor file)
    action: none (session census unreadable; capacity fails closed)"
      escalations="$escalations
- $rig: session census was unreadable or timed out, so pool capacity is UNKNOWN. No brakeman was spawned."
      continue
    fi

    if [ "$max" -gt "$live" ]; then
      spawn_seq=$((spawn_seq + 1))
      sess="$(sy_pool_spawn_brakeman "$rig" "$spawn_seq")"; _spawn_rc=$?
      if [ -z "$sess" ] && [ "$_spawn_rc" -eq 3 ]; then
        # Distinct from the generic failure below: rc 3 is the alias-budget
        # floor, which no retry can clear. Say so, or this reads as load.
        action="spawn REFUSED (alias budget too small — needs a human)"
        escalations="$escalations
- $rig: brakeman spawn REFUSED — this rig's qualified alias cannot fit an 8-hex idempotency token in gc's 64-character limit, so no brakeman will spawn for it until a human pins a shorter POOL_SPAWN_ALIAS_NONCE or shortens the rig name. This will NOT clear on retry — it is short even at the narrowest cycle position, so it is a naming/config fault rather than load. The stderr diagnostic from the same cycle carries the exact character deficit. $depth claimable cloud-pool bead(s) left unclaimed."
      elif [ -z "$sess" ]; then
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
  demand="$(sy_pool_rig_demand "$rig")"; demand_rc=$?
  if [ "$demand_rc" -ne 0 ]; then
    # Unknown demand cannot prove last cycle's hand-offs succeeded. Carry this
    # rig's cursor rows forward so the next healthy read can still verify them.
    _preserved="$(printf '%s\n' "$prev_assigned" | awk -v r="$rig" '$1==r {print}')"
    [ -n "$_preserved" ] && assigned_preserved="$assigned_preserved
$_preserved"
    report="$report
- $rig: demand UNKNOWN
    action: none (bead ledger unreadable; demand fails closed)"
    escalations="$escalations
- $rig: bead demand was unreadable, malformed, or timed out. No brakeman was spawned."
    continue
  fi
  [ -n "$demand" ] || continue            # silence is the success case

  count=$(printf '%s\n' "$demand" | awk 'NF' | wc -l | tr -d ' ')
  ids="$(printf '%s\n' "$demand" | awk 'NF' | tr '\n' ' ' | sed 's/ *$//')"

  # Silent-failure mode 4 — a bead we direct-assigned last cycle is STILL claimable
  # demand: the hand-off did not take. Check the ids we handed THIS rig against the
  # current demand set (bead ids are single tokens, so word-splitting is safe).
  for pb in $(printf '%s\n' "$prev_assigned" | awk -v r="$rig" '$1==r {print $2}'); do
    case " $ids " in
      *" $pb "*) escalations="$escalations
- $rig: bead $pb was direct-assigned last cycle but is STILL claimable demand — the hand-off did not take (unclaimed after a full cycle)."
        assigned_stalled="$assigned_stalled
$rig $pb" ;;
    esac
  done

  max="$(sy_pool_brakeman_max "$rig" "$agents_census")"; max_rc=$?
  if [ "$max_rc" -ne 0 ]; then
    report="$report
- $rig: $count claimable bead(s), WIP slot UNKNOWN; spawn-ready: none
    demand: $ids
    action: none (agent capacity unreadable; capacity fails closed)"
    escalations="$escalations
- $rig: brakeman max-active capacity was unreadable, malformed, or timed out. No brakeman was spawned for demand: $ids."
    continue
  fi
  live="$(sy_pool_brakeman_live "$rig" "$sessions_census")"; live_rc=$?
  if [ "$live_rc" -ne 0 ]; then
    report="$report
- $rig: $count claimable bead(s), WIP slot UNKNOWN; spawn-ready: none
    demand: $ids
    action: none (session census unreadable; capacity fails closed)"
    escalations="$escalations
- $rig: session census was unreadable or timed out, so pool capacity is UNKNOWN. No brakeman was spawned for demand: $ids."
    continue
  fi

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
      spawn_seq=$((spawn_seq + 1))
      sess="$(sy_pool_spawn_brakeman "$rig" "$spawn_seq")"; _spawn_rc=$?
      if [ -z "$sess" ] && [ "$_spawn_rc" -eq 3 ]; then
        # See the cloud-pool caller above: rc 3 is permanent, not load.
        action="spawn REFUSED (alias budget too small — needs a human)"
        escalations="$escalations
- $rig: brakeman spawn REFUSED — this rig's qualified alias cannot fit an 8-hex idempotency token in gc's 64-character limit, so no brakeman will spawn for it until a human pins a shorter POOL_SPAWN_ALIAS_NONCE or shortens the rig name. This will NOT clear on retry — it is short even at the narrowest cycle position, so it is a naming/config fault rather than load. The stderr diagnostic from the same cycle carries the exact character deficit. $count claimable bead(s) left unclaimed (demand: $ids)."
      elif [ -z "$sess" ]; then
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
          # The escalation deliberately omits $sess while `action` above keeps it.
          # The alert fingerprint is a cksum over $escalations alone, and $sess is
          # a fresh unique adhoc identity on every spawn — embedding it makes each
          # cycle's fingerprint differ from the last, so the dedup below never
          # matches and a persistent fault mails EVERY cycle instead of once. That
          # is the exact "hides new incidents in noise" flood the dedup exists to
          # prevent. Identity is not lost: it stays in `action`, which reaches the
          # per-cycle report.
          *) action="spawned $sess, but direct-assign of $target FAILED"
             escalations="$escalations
- $rig: the direct-assign of $target was rejected — a freshly spawned worker has nothing to claim." ;;
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
  _assigned_content="$(printf '%s\n%s\n%s\n' "$assigned_now" "$assigned_preserved" "$assigned_stalled" | awk 'NF' | awk '!seen[$0]++')"
  if ! sy_pool_atomic_state_write "$ASSIGNED_LAST" "$_assigned_content"; then
    escalations="$escalations
- city: the last-assignment cursor could not be persisted atomically; failed hand-offs may be unobservable next cycle."
  fi
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
# Deduplicate an unchanged incident across one-minute cycles. A spawn failure or
# unreadable census can persist for many cycles; mailing the same demand set each
# minute hides new incidents in noise. The fingerprint is cleared as soon as a
# healthy cycle has no escalation, so the same problem is reported again if it
# genuinely recurs after recovery.
# No sweep here: sy_pool_atomic_state_write writes through a private mktemp -d
# sibling directory, so it never creates a `<state>.tmp.<pid>` file. Remnants of
# that older name are swept once, for state directories written by an earlier
# version, in sy_pool_cleanup_state_temps.
_incident_confirmed=0
if [ -n "$escalations" ]; then
  alert_fingerprint="$(printf '%s' "$escalations" | cksum | awk '{print $1 ":" $2}')"
  previous_fingerprint="$(cat "$POOL_SPAWN_ALERT_STATE" 2>/dev/null || true)"
  if [ "$alert_fingerprint" = "$previous_fingerprint" ]; then
    _incident_confirmed=1
  else
    if sy_timeout "$POOL_GC_WRITE_TIMEOUT" gc mail send mayor \
      -s "pool-spawn: brakeman dispatch failure — demand left unclaimed" \
      -m "The switchyard-ops pool-spawn order could not get claimable brakeman demand into a worker's hands this cycle. This order replaces the controller's dead sling-claim, so each line below is stalled work — a rig whose demand a spawn, an assign, or an unreadable cloud-pool probe left unclaimed, which nothing else will pick up until the next cycle clears it or a human intervenes:$escalations" \
      >/dev/null 2>&1; then
      # Persist only after confirmed delivery. A failed send must retry next cycle.
      sy_pool_atomic_state_write "$POOL_SPAWN_ALERT_STATE" "$alert_fingerprint" || true
      _incident_confirmed=1
    fi
  fi
else
  rm -f "$POOL_SPAWN_ALERT_STATE" 2>/dev/null
fi

# A still-claimable prior hand-off remains in the first cursor write until its
# incident is known delivered (or already deduplicated as delivered). Only then
# consume those rows. If this second atomic write fails, the older cursor remains,
# causing a harmless retry rather than silently losing the incident.
if [ "$_incident_confirmed" -eq 1 ] && [ -n "$assigned_stalled" ] && [ -n "$bd_rigs_seen" ]; then
  _assigned_content="$(printf '%s\n%s\n' "$assigned_now" "$assigned_preserved" | awk 'NF' | awk '!seen[$0]++')"
  sy_pool_atomic_state_write "$ASSIGNED_LAST" "$_assigned_content" || true
fi

exit 0
