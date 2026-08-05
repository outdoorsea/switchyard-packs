#!/bin/sh
# lane-ensure AGENT SUBJECT — keep exactly one live session of the switchyard-ops
# agent AGENT alive for each rig that drives a switchyard project.
#
# This is the shared spawner behind the self-directed lanes — agents whose queue
# is switchyard's, not the gc bead ledger, so there is no demand bead to detect
# and no hand-off to make. Its whole job is "ensure a <AGENT> is running for each
# rig that has work for it".
#
# THAT LAST CLAUSE USED TO READ "for each rig that has a coordinator", and the
# difference is switchyard PRD #299, crit:61754b5dbdb9. The queue was readable
# only from INSIDE a session, so this order started one per rig per cycle and let
# it discover for itself that there was nothing to do and exit IDLE. On a drained
# lane that is a whole session — a process, a model context, a credential slot —
# spent to learn a fact a single HTTP GET answers. Measured while building this:
# one live rig's judging queue held 113 items while another's held 0, and the
# sweep was staffing both identically every 30 minutes. So the queue is now read
# BEFORE the spawn (lib/switchyard-api.sh), and a lane with nothing waiting is
# left alone. The session still exits IDLE when it finds the queue empty; that
# path is the backstop for the races this check cannot close, not the design.
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
#
# EVERY CYCLE REAPS BEFORE IT SPAWNS (switchyard PRD #299, crit:aa1366b1a73b).
# Spawning was only ever half a lifecycle: this order created one adhoc session
# per rig per cycle and removed none, so the population grew until the host
# saturated (14 concurrent adhoc sessions across two rigs on 2026-08-03, load
# excursion to 311 on a 16-core box).
#
# The retention is not a cadence problem, which is why widening the intervals in
# city.toml (judge 30m→4h, answer→6h) did not stop it. It is a STATE problem: a
# finished adhoc session leaves the LANE_LIVE_STATES set below — it settles as
# `asleep` — so the "one already running?" guard correctly reports none live and
# correctly spawns a replacement, while the finished session stays registered
# forever. The guard was never the leak; the missing half of the lifecycle was.
# Widening the interval only slows the accrual, it never bounds it.
#
# So a cycle is now reap-then-spawn, in that order. The ordering is load-bearing
# in both directions: reaping first means the spawn guard is evaluated against a
# roster that no longer holds finished sessions, and spawning after means a lane
# whose only session was just reaped is refilled in the same cycle rather than
# left unowned until the next one.
set -u

AGENT="${1:?lane-ensure: AGENT (e.g. judge) is required}"
SUBJECT="${2:-$AGENT}"          # human label for the escalation mail

. "$(dirname "$0")/../lib/roster.sh"
. "$(dirname "$0")/../lib/pane-state.sh"
. "$(dirname "$0")/../lib/switchyard-api.sh"

QUALIFIED="switchyard-ops.$AGENT"

# THE LANE'S QUEUE, per agent — the read that answers "is there anything for a
# session to do?" without starting one (switchyard PRD #299, crit:61754b5dbdb9).
#
# Each lane's backlog is a different switchyard queue, so the endpoint is chosen
# by AGENT rather than derived: the judging lane takes delivered criteria that
# declare no `verify_command` (`?lane=judgment` is REQUIRED — the API answers 400
# on an absent lane rather than defaulting), and the answerer takes outstanding
# PRD questions.
#
# AN UNRECOGNISED LANE LEAVES BOTH EMPTY, which disables the check and spawns as
# before. A lane added to this pack later must keep working on the day it is
# added, not go silently unstaffed until someone remembers to extend this case.
#
# THE COUNT FILTER INSISTS ON AN ARRAY, and that is a safety property rather than
# pedantry. `null | length` is 0 in jq, so the obvious `(.validations // []) |
# length` reads any 200 response that does not carry the key — an error envelope,
# a renamed field, a future shape — as a DRAINED QUEUE, and silently stops
# staffing a lane that has work. Demanding the array makes every one of those
# answer `empty` instead, which the caller treats as unknown and spawns. Both
# endpoints do return the key as a real array when the queue is empty (verified
# against a live project holding zero), so the strictness costs nothing true.
LANE_QUEUE_SUFFIX=""
LANE_QUEUE_COUNT_JQ=""
case "$AGENT" in
  judge)
    LANE_QUEUE_SUFFIX="/validations?lane=judgment"
    LANE_QUEUE_COUNT_JQ='if (.validations|type) == "array" then (.validations|length) else empty end'
    ;;
  answerer)
    LANE_QUEUE_SUFFIX="/questions/open"
    LANE_QUEUE_COUNT_JQ='if (.questions|type) == "array" then (.questions|length) else empty end'
    ;;
esac

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
#
# CLOSED SESSIONS ARE EXCLUDED, and that exclusion is load-bearing rather than
# tidy-minded. It is the one filter here that LOWERS the count, i.e. the one that
# can cause a spawn rather than suppress one, so it is the one that needs a
# reason: without it the session lane_reap just closed keeps its last state on
# the roster, still matches, and still counts as live — so the reap would free a
# slot the guard refuses to notice and the lane would go permanently unstaffed.
# Teardown would have converted an unbounded-growth bug into a silent-stall bug,
# which is strictly worse: growth is visible in `gc session list`, a lane that
# quietly stopped judging is not. A closed session is definitively not draining
# any backlog, so counting it as live was never right; it was merely harmless
# while nothing ever closed one. Mirrors sy_session_alias_for in roster.sh.
lane_live_count() {
  _states_json="$(printf '%s' "$LANE_LIVE_STATES" | jq -Rc 'split(" ")')"
  gc session list --json --state all 2>/dev/null \
    | jq -r --arg q "$1/$QUALIFIED" --argjson live "$_states_json" '
        [ (.sessions // [])[]
          | select( ((.closed // false) | not) )
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

# lane_tmux_socket — the tmux socket gc's server listens on, for the pane reads
# the reap decision is made from.
#
# It must be resolved explicitly and cannot be left to tmux's default. gc runs
# its agents on a DEDICATED server whose socket is named after the city, not on
# the default socket; an order's exec process is not itself inside that server,
# so a bare `tmux capture-pane` there talks to the wrong server, finds no such
# session, and — by pane-state.sh's fail-closed rule — answers `live` for every
# session forever. That failure is invisible: the sweep would run, reap nothing,
# report success, and leak exactly as it does today.
#
# Resolution order runs from most authoritative to most derived:
#   1. GC_TMUX_SOCKET — gc's own published knob (packs/examples/city/pack.toml
#      spells the same `tmux ${GC_TMUX_SOCKET:+-L …}` form).
#   2. $TMUX — set when we are running inside the server itself, and its first
#      comma-separated field is the socket PATH, so the basename is the name
#      `-L` wants. Measured: TMUX=/private/tmp/tmux-501/gc-fremont-fresh,60151,46.
#   3. the city name — what gc names the socket after, and the case that
#      actually applies to an order.
# Each step is a fact gc publishes rather than a guess, and an empty answer at
# any step falls through rather than pinning an empty -L.
lane_tmux_socket() {
  if [ -n "${GC_TMUX_SOCKET:-}" ]; then printf '%s' "$GC_TMUX_SOCKET"; return 0; fi
  if [ -n "${TMUX:-}" ]; then
    _lts="${TMUX%%,*}"
    _lts="${_lts##*/}"
    if [ -n "$_lts" ]; then printf '%s' "$_lts"; return 0; fi
  fi
  printf '%s' "$(sy_city_name)"
}

# lane_adhoc_sessions RIG — every non-closed session on RIG that THIS SWEEP
# SPAWNED, one per line as `<ref>\t<tmux-session-name>`. Empty when there are
# none; rc=2 when the roster could not be read at all.
#
# THIS PREDICATE DEFINES WHAT MAY BE KILLED, so it is deliberately the strictest
# in the file — the exact inverse of lane_live_count above, which matches as
# broadly as it can because over-matching there only suppresses a spawn. Here
# over-matching destroys a running agent's in-flight work, so the two must not
# share an identity test even though they name the same lane.
#
# Only the `-adhoc-` form matches. The other two clauses lane_live_count accepts
# are both excluded on purpose:
#   * `.template == $q` matches any session STARTED FROM this agent, including
#     one a human started and attached to by hand.
#   * `$n == $q`, the bare unsuffixed name, is precisely the singleton-alias
#     shape roster.conf's PINNED_EXTRA exists to describe — an agent held by a
#     long-lived manual session. Reaping one would be reaping a pinned role.
# What is left is the name gc gives a session THIS ORDER created via lane_spawn
# (`<rig>/switchyard-ops.<agent>-adhoc-<hash>`), which is the PRD's own boundary:
# a sweep removes what it spawned and nothing else. Named and pinned roles —
# witness, refinery, conductor, mayor, deacon, boot — carry no `-adhoc-` segment
# and so can never match, whatever their pane happens to say.
#
# The suffix is matched as the literal `-adhoc-` rather than a bare prefix so a
# lane named `judge` can never absorb one named `judgement`, the same care
# lane_live_count takes for the same reason.
#
# `.session_name` is carried alongside because it is the tmux join key — gc's own
# record of what it called the pane — and a row without one is emitted with an
# empty second field so the caller can skip it rather than guess a pane name.
# Guessing is what broke loop-health: `/` becomes `--` and `.` becomes `__`, and
# re-deriving that mangling is not this pack's business.
lane_adhoc_sessions() {
  if [ -n "${SY_SESSION_SNAPSHOT:-}" ]; then
    _las_raw="$SY_SESSION_SNAPSHOT"
  else
    _las_raw="$(gc session list --json --state all 2>/dev/null)" || return 2
  fi
  [ -n "$_las_raw" ] || return 2
  printf '%s\n' "$_las_raw" | jq -r --arg q "$1/$QUALIFIED" '
        (.sessions // [])[]
        | select( ((.closed // false) | not) )
        | (.agent_name // .agent // .qualified_name // "") as $n
        | select( $n | startswith($q + "-adhoc-") )
        | ((.alias // .id // .name // "")) as $ref
        | select( $ref != "" )
        | [ $ref, (.session_name // "") ] | @tsv' 2>/dev/null
}

# lane_reap RIG — close every adhoc session of this lane on RIG whose pane says
# it has finished. Echoes the ref of each session it closed, one per line.
#
# The decision is pane state and never age (pane-state.sh carries the full
# argument; in short, age misclassified 4 of 12 sessions and killed one holding
# an unread mayor escalation). Every uncertainty — an unreadable roster, a row
# with no pane name, a capture that fails, an empty or unrecognised capture —
# resolves to "leave it running", because the two errors are not symmetrical:
# failing to reap costs one retained session until the next cycle, while reaping
# a live agent destroys work that cannot be recovered.
#
# A close that fails is deliberately NOT escalated. It is self-healing — the
# session stays on the roster, the next cycle re-reads its pane and tries again —
# and this order already mails the mayor on spawn failure, which is the direction
# that leaves a backlog unowned. Mail on both and a wedged session would page the
# mayor every 30 minutes about a condition that resolves itself.
lane_reap() {
  _lr_rows="$(lane_adhoc_sessions "$1")" || return 0
  [ -n "$_lr_rows" ] || return 0

  printf '%s\n' "$_lr_rows" | while IFS="$LANE_TAB" read -r _lr_ref _lr_pane; do
    [ -n "${_lr_ref:-}" ] || continue
    [ -n "${_lr_pane:-}" ] || continue
    [ "$(sy_pane_classify_session "$_lr_pane" "$LANE_TMUX_SOCKET")" = reapable ] || continue
    gc session close "$_lr_ref" >/dev/null 2>&1 && printf '%s\n' "$_lr_ref"
  done
}

# A literal tab for the IFS above. Written via printf rather than inline because
# an embedded tab in the source is invisible and one stray editor space would
# silently split on the wrong character, leaving every ref field whole and every
# pane field empty — which reads as "no pane name" and reaps nothing at all.
LANE_TAB="$(printf '\t')"
LANE_TMUX_SOCKET="$(lane_tmux_socket)"

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

# The rigs the mayor has suspended, read ONCE per cycle.
#
# A SUSPENDED RIG IS NOT A RIG WITH A QUEUE, and lane_rigs above cannot see
# that. `gc agent list --json` carries the per-AGENT `suspended` flag and
# NOTHING about the rig the agent lives in — roster.sh says so outright where
# sy_derived_roster hits the same wall — so its filter answers "is this agent
# suspended?" and can never answer "did the mayor suspend this rig?". Every
# agent on a `gc rig suspend`-ed rig passes it with suspended=false, and the
# sweep then spawns a session the reconciler is deliberately declining to run,
# on a rig nobody asked to be staffed. That is the exact load this PRD exists to
# stop, manufactured by the sweep itself.
#
# Read once and not per rig: `gc rig list` is a subprocess, and polling it
# inside the loop would also let a mid-cycle blip answer differently for two
# rigs in the same sweep — the suspended set must be one consistent snapshot.
#
# FAILS OPEN, deliberately, and this is sy_suspended_rigs' own documented
# contract rather than a choice re-made here: an unreadable, slow or empty
# `gc rig list` yields an EMPTY set, so nothing is withheld and every rig is
# still staffed. The asymmetry is the one roster.sh argues at length. An
# over-spawn is visible in `gc session list` and self-corrects on the next
# cycle; a blipped lookup that silently withheld every spawn would stop the lane
# city-wide with no signal at all — the silent stall lane-teardown.test.sh
# already calls worse than the leak it replaced.
suspended_rigs="$(sy_suspended_rigs)"

# lane_rig_suspended RIG — 0 when the mayor has suspended RIG.
#
# grep -qxF and not a `case` glob: a rig name is arbitrary text and -F -x makes
# the match literal and whole-line, so a rig called `forge` is never matched by
# a suspended `forge-staging` (or vice versa). The empty-set short-circuit keeps
# the fail-open path from paying a process at all.
lane_rig_suspended() {
  [ -n "$suspended_rigs" ] || return 1
  printf '%s\n' "$suspended_rigs" | grep -qxF "$1"
}

# The switchyard credential and project list, read ONCE per cycle for the same
# two reasons the suspended set above is: each is a subprocess (and here a
# network call), and a per-rig re-read would let a mid-cycle blip answer
# differently for two rigs in the same sweep.
#
# Both are empty when switchyard cannot be reached, is not configured, or holds
# no token — which disables the queue check entirely and spawns exactly as this
# order did before it existed. That is the whole fail-open story: this check can
# only ever WITHHOLD a spawn on a confident answer, never cause one.
lane_token="$(sy_api_token)"
lane_projects="$(sy_api_projects "$lane_token")"

# lane_queue_depth RIG — how many items wait in RIG's queue for THIS lane.
# Prints a count, or NOTHING when the answer is not confidently known.
#
# Empty is returned for every uncertainty, and they are deliberately not
# distinguished: no lane mapping, no token, no reachable switchyard, a rig whose
# project cannot be resolved unambiguously, a non-200, a body jq cannot read. The
# caller treats all of them identically as "check unavailable" and spawns.
#
# The count is validated as digits before it is returned. jq answers `null` for a
# shape it did not expect, and `null` compared against 0 is not equal — so an
# unexpected body would fall through to the spawn anyway — but a count that is
# not a number has no business reaching a numeric guard in the first place.
lane_queue_depth() {
  [ -n "$LANE_QUEUE_SUFFIX" ] || return 0
  [ -n "$lane_token" ] || return 0

  _lqd_project="$(sy_project_for_rig "$1" "$lane_projects")"
  [ -n "$_lqd_project" ] || return 0

  _lqd_body="$(sy_api_get "/api/v1/projects/$_lqd_project$LANE_QUEUE_SUFFIX" "$lane_token")"
  [ -n "$_lqd_body" ] || return 0

  _lqd_n="$(printf '%s' "$_lqd_body" | jq -r "$LANE_QUEUE_COUNT_JQ" 2>/dev/null | awk 'NF' | head -n1)"
  case "${_lqd_n:-}" in
    '' | *[!0-9]*) return 0 ;;
  esac
  printf '%s' "$_lqd_n"
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
  # REAP FIRST, THEN SPAWN — see the lifecycle note in the header. A cycle
  # removes the sessions it spawned before it decides whether to spawn another,
  # so the guard below is answered by a roster holding only sessions that are
  # actually still working. Reaping AFTER would read the finished session as
  # live, skip the spawn, and reap the lane down to nothing — a sweep that
  # alternates between one session and none instead of keeping one at work.
  #
  # Unconditional, and in particular NOT gated on lane_live_count: the rig whose
  # sessions are all finished is exactly the rig that most needs the reap, and it
  # is the one a count-first ordering would skip.
  lane_reap "$rig" >/dev/null

  # SUSPENSION WITHHOLDS THE SPAWN, NOT THE REAP — and the split is the whole
  # point rather than an implementation detail.
  #
  # `gc rig suspend` tells the reconciler not to START this rig's agents. It
  # says nothing about sessions already sitting there, and closing one that has
  # printed IDLE does not fight the mayor's decision — it completes it. Skipping
  # the rig outright instead would open a fresh retention hole in the exact PRD
  # that exists to close them: suspend a rig while one of its adhoc sessions is
  # finishing and that session is never swept again, retained for as long as the
  # suspension lasts.
  #
  # This also matches the reap's own stated rule two blocks up — unconditional,
  # never gated on the spawn guard, because the rig whose sessions are all
  # finished is exactly the rig that most needs the reap.
  if lane_rig_suspended "$rig"; then
    continue
  fi

  n="$(lane_live_count "$rig")"
  case "$n" in
    ''|*[!0-9]*) continue ;;      # cannot confirm absent → do not stack a second
    0) : ;;                       # confirmed none live → spawn below
    *) continue ;;                # already running → leave it
  esac

  # AN EMPTY QUEUE MEANS THERE IS NOTHING TO START A SESSION FOR.
  #
  # This is the last gate before the spawn, and it is last on purpose: it is the
  # only one that costs a network call, so it is asked only once every cheaper
  # local reason to skip has already been ruled out. A city whose lanes are all
  # busy pays nothing for it at all.
  #
  # ONLY A CONFIDENT ZERO WITHHOLDS THE SPAWN. lane_queue_depth answers empty for
  # every uncertainty it meets, and empty falls through to the spawn — the same
  # asymmetry the suspended-rig guard and the reaper are both built on. Skipping
  # on a bad read would leave a lane with a real backlog permanently unstaffed and
  # say nothing, and this file's teardown notes already argue at length that such
  # a silent stall is worse than the over-spawn it would be preventing: a surplus
  # session is visible in `gc session list`, a lane that quietly stopped is not.
  #
  # Note this cannot strand the backlog it declines to staff. The queue is read
  # fresh every cycle, so the sweep that skips a drained lane is the same sweep
  # that staffs it the moment one item lands.
  if [ "$(lane_queue_depth "$rig")" = 0 ]; then
    continue
  fi

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
