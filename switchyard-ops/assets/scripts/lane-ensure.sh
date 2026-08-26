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
# THAT ALARM IS CLASSIFIED, NOT UNIFORM (switchyard PRD #299, crit:8ef84c79bb1f).
# "Could not start" covered two faults with opposite remedies — a lane that is
# not configured (permanent, needs a human) and a startup handshake that failed
# under load (transient, fixes itself) — and shipped the first one's remedy with
# both. It also fired for rigs whose session had in fact started, because the
# identity readback is the part load breaks first. So the escalation now
# re-probes before alarming and splits by cause; see the loop at the foot of
# this file.
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

# Load the city's roster.conf. REQUIRED, not optional: sy_project_for_rig (in
# lib/switchyard-api.sh) resolves a rig to its project via RIG_PROJECTS, and
# RIG_PROJECTS is set ONLY by sourcing roster.conf, which happens ONLY inside
# sy_load_conf. Without this call RIG_PROJECTS is always empty here, so the
# explicit binding added in #1515 never takes effect and a rig whose name does
# not equal its project slug resolves to nothing.
#
# The failure is silent in both directions: the lane still spawns (the scope
# check fails open), the session finds no project and exits IDLE, so the lane
# reads as running while doing nothing -- and the diagnostic this script mails
# tells the operator to add the RIG_PROJECTS entry that is already sitting in
# roster.conf, unread. Measured on a live city 2026-08-11: five lanes down at
# once with a correct roster.conf in place.
#
# The variable is never exported and orders exec this script directly, so it
# cannot be inherited from a parent either. Of the pack's order scripts only
# this one and repair-sweep.sh omitted the call; pool-spawn.sh, the third
# consumer of sy_project_for_rig, has always made it.
sy_load_conf


QUALIFIED="$SY_NS.$AGENT"

# THE LANE'S QUEUE, per agent — the read that answers "is there anything for a
# session to do?" without starting one (switchyard PRD #299, crit:61754b5dbdb9).
#
# Each lane's backlog is a different switchyard queue, so the endpoint is chosen
# by AGENT rather than derived: the judging lane takes delivered criteria that
# declare no `verify_command` (`?lane=judgment` is REQUIRED — the API answers 400
# on an absent lane rather than defaulting), the answerer takes outstanding
# PRD questions, and the dupe-scout takes the project's OPEN issues.
#
# THE DUPE-SCOUT'S THRESHOLD IS ONE OPEN ISSUE, NOT TWO. It files two kinds of
# proposal from that one queue, and they need different minimums: a duplicate
# MERGE pair needs two issues, but a COVERED-BY needs only one (an issue an
# existing PRD already covers). Gating on two would therefore silently strand the
# covered-by half on every project sitting at exactly one open issue — the same
# class of quiet unstaffing this whole guard exists to avoid. One is the floor
# that keeps both halves reachable.
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
# ADDING A LANE? IT NEEDS AN ARM HERE. scripts/check-lane-queue-declarations.sh
# enforces that every lane an order dispatches through this script declares BOTH
# variables below, and CI fails the PR that adds one without them — a lane with
# no arm spawns every cycle whether or not it has work, and nothing at run time
# distinguishes that from a queue it merely could not read. A lane that gates on
# something other than a switchyard queue records an exemption there instead,
# naming the gate it uses.
LANE_QUEUE_SUFFIX=""
LANE_QUEUE_COUNT_JQ=""
# LANE_ROLE — the catalog role this lane serves, for the governance gate and the
# liveness stamp (switchyard PRD #365, crit:fc020b45069d; see the role section
# below). Declared IN the same case block as the lane's queue because the two
# name one fact from different angles — which switchyard surface this lane is —
# and a lane whose queue moves should never have its role mapping drift apart in
# a second list. Empty (an unmapped lane) disables BOTH halves: no heartbeat is
# stamped and no registry verdict can withhold a spawn, so a lane added later,
# and the scouts (whose tree-scanning work has no catalog role — borrowing the
# nearest one would let disabling that role silently kill a scanner nobody
# meant to touch), keep working exactly as the queue check's own rule promises.
LANE_ROLE=""
case "$AGENT" in
  judge)
    LANE_QUEUE_SUFFIX="/validations?lane=judgment"
    LANE_QUEUE_COUNT_JQ='if (.validations|type) == "array" then (.validations|length) else empty end'
    # validate_criterion is the validator role's bound surface.
    LANE_ROLE="validator"
    ;;
  answerer)
    LANE_QUEUE_SUFFIX="/questions/open"
    LANE_QUEUE_COUNT_JQ='if (.questions|type) == "array" then (.questions|length) else empty end'
    LANE_ROLE="answerer"
    ;;
  intake-triage)
    # The unified intake queue — untriaged ideas AND issues (switchyard PRD #327).
    # The triager only acts on the issues, but the endpoint is the queue the
    # coordinator's own intake sweep reads, and a rig with untriaged ideas and no
    # untriaged issues is still a rig worth waking: the pass costs one read and
    # exits IDLE. Overcounting here can only cause a cheap no-op spawn, whereas
    # undercounting silently unstaffs the lane.
    #
    # `items` is the response's real array key, confirmed against a live project
    # rather than assumed — the whole point of the strictness described above is
    # lost if the key is guessed, since a wrong name reads as a drained queue.
    LANE_QUEUE_SUFFIX="/intake"
    LANE_QUEUE_COUNT_JQ='if (.items|type) == "array" then (.items|length) else empty end'
    LANE_ROLE="triager"
    ;;
  dupe-scout)
    LANE_QUEUE_SUFFIX="/issues/open"
    LANE_QUEUE_COUNT_JQ='if (.issues|type) == "array" then (.issues|length) else empty end'
    # Also `triager`, deliberately shared with intake-triage: the dupe-scout's
    # merge and covered-by proposals are triage OF the issue queue — the same
    # surface, not a distinct role — so one registry toggle governs both lanes
    # and both stamp the one role's liveness.
    LANE_ROLE="triager"
    ;;
  golden-journey)
    # The ship stage's verification queue: succeeded deploys carrying no grade yet
    # (switchyard PRD #327). Grading a deploy drops it from this queue, so the
    # depth is the real backlog rather than a running total.
    #
    # `deploys` is the response's real array key, read off the handler
    # (internal/api/api_v1_ship.go, `jsonOK(w, map[string]any{"deploys": out})`)
    # rather than assumed — the strictness described above buys nothing if the key
    # is guessed, since a wrong name parses as a drained queue and silently
    # unstaffs the lane forever.
    #
    # This endpoint OMITS a deploy whose environment has no registered journey,
    # because no run could ever clear it. So a project that reports deploys but has
    # registered no journeys reads as zero here and is correctly left alone: there
    # is genuinely nothing this lane could do for it.
    LANE_QUEUE_SUFFIX="/deploys/pending-verification"
    LANE_QUEUE_COUNT_JQ='if (.deploys|type) == "array" then (.deploys|length) else empty end'
    LANE_ROLE="shipper"
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

# THE SWEEP BOUNDS ITS OWN WORK (sw-jqrx).
#
# This order failed 21 consecutive times with `context deadline exceeded` and had
# never once completed since 2026-08-04 — so the judging lane's whole
# reap-then-spawn lifecycle (PRD #299) never ran. It was not close to the
# deadline: measured 2026-08-08 on this host, `gc session list --json --state all`
# costs 16.8-27.1s (mean ~21.8s), and the loop below called it TWICE per rig —
# once for lane_reap, once for lane_live_count — across 11 rigs carrying
# `switchyard-ops.judge`. That is ~480s of serial subprocess time before a single
# spawn decision, and it is why the failure was total rather than intermittent.
#
# Two things follow, and they are separate fixes:
#
#   1. READ THE ROSTER ONCE. This is roster.sh's own documented remedy — see
#      sy_session_snapshot ("one `gc session list` per cycle instead of one per
#      agent"), whose second and load-bearing reason is COHERENCE: per-rig lookups
#      judge different rigs against different rosters. lane_adhoc_sessions already
#      honoured SY_SESSION_SNAPSHOT; nothing ever SET it, and lane_live_count did
#      not read it at all, so the pack paid the exact cost its library exists to
#      avoid. 22 reads become 1.
#   2. CAP THE WHOLE SWEEP. A cheaper sweep is still an unbounded one, and this
#      order died silently for four days precisely because nothing it did was
#      bounded by anything it controlled. The budget below is the sweep's own
#      deadline, deliberately set well inside any plausible order-exec deadline,
#      so a sweep that cannot finish SAYS SO (below) instead of being killed
#      mid-rig with no record.
#
# Overridable per city because the honest number depends on host load and rig
# count, both of which vary; 0 disables the cap for a hand-run debug sweep.
LANE_SWEEP_BUDGET_SECONDS="${LANE_SWEEP_BUDGET_SECONDS:-600}"
case "$LANE_SWEEP_BUDGET_SECONDS" in
  '' | *[!0-9]*) LANE_SWEEP_BUDGET_SECONDS=600 ;;
esac

# A bound on the single roster read too. Without it the one remaining
# `gc session list` is itself unbounded, and one wedged call reproduces the whole
# bug with a smaller call count.
LANE_ROSTER_TIMEOUT="${LANE_ROSTER_TIMEOUT:-120}"
case "$LANE_ROSTER_TIMEOUT" in
  '' | *[!0-9]*) LANE_ROSTER_TIMEOUT=120 ;;
esac

lane_now() { date +%s 2>/dev/null || printf '0'; }
LANE_STARTED="$(lane_now)"

# lane_over_budget — has this sweep spent its allowance?
#
# Fails toward "keep going" on an unreadable clock: a sweep that cannot time
# itself should do its work, not refuse to. `date +%s` yielding 0 makes the
# elapsed figure meaningless rather than large, so the comparison is skipped.
lane_over_budget() {
  [ "$LANE_SWEEP_BUDGET_SECONDS" -gt 0 ] || return 1
  [ "$LANE_STARTED" -gt 0 ] || return 1
  _lob_now="$(lane_now)"
  [ "$_lob_now" -gt 0 ] || return 1
  [ "$(( _lob_now - LANE_STARTED ))" -ge "$LANE_SWEEP_BUDGET_SECONDS" ]
}

# lane_roster [fresh] — the session roster JSON, from the per-cycle snapshot
# unless the caller demands a fresh read (or no snapshot was taken).
#
# Bounded on the fresh path for the reason above. An empty answer keeps
# lane_live_count's existing "cannot confirm absent" contract intact: callers
# already treat empty as UNKNOWN and decline to spawn, so a timed-out read is
# indistinguishable from an unreadable one, which is exactly right.
lane_roster() {
  if [ "${1:-}" = fresh ] || [ -z "${SY_SESSION_SNAPSHOT:-}" ]; then
    sy_timeout "$LANE_ROSTER_TIMEOUT" gc session list --json --state all 2>/dev/null
    return 0
  fi
  printf '%s' "$SY_SESSION_SNAPSHOT"
}

# lane_escalate_once KEY SUBJECT BODY — mail the mayor at most once per episode.
#
# A SWEEP THAT CANNOT COMPLETE MUST SAY SO. The whole reason sw-jqrx survived 21
# repetitions is that its only symptom was one line in a machine-wide log while
# every other surface — gc status, tmux, the switchyard agent roster — reported the
# lane healthy. Silence on the failure path is the defect, not a side effect of it.
#
# ONCE PER EPISODE, not once per cycle: a condition that persists is one problem,
# and re-mailing it every cycle is how an operator learns to filter this sender.
# The marker is cleared by lane_clear_escalation on the first clean sweep, so the
# NEXT occurrence mails again — an episode, not a permanent mute. Mirrors
# loop-health.sh's probe-alerted/missing-alerted markers, including their location.
#
# Keyed per AGENT so the judge and answerer lanes cannot mute each other, and per
# condition so a budget overrun does not suppress an unreadable-roster notice.
#
# Marker written only when the mail is accepted: if `gc mail send` fails there is
# no record of the escalation, so the next cycle must be free to retry it.
lane_escalate_once() {
  _leo_marker="$(sy_state_dir)/lane-ensure.$AGENT.$1"
  [ -f "$_leo_marker" ] && return 0
  mkdir -p "$(sy_state_dir)" 2>/dev/null || return 0
  gc mail send mayor -s "$2" -m "$3" >/dev/null 2>&1 || return 0
  : > "$_leo_marker" 2>/dev/null || true
}

# lane_clear_escalation KEY — the episode is over; the next occurrence may mail.
lane_clear_escalation() {
  rm -f "$(sy_state_dir)/lane-ensure.$AGENT.$1" 2>/dev/null || true
}

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
# lane_live_count RIG [REAPED_REFS] [fresh]
#
# REAPED_REFS is the newline-separated list of refs lane_reap closed for RIG on
# THIS cycle, and passing it is not optional bookkeeping — it is what makes the
# one-read-per-cycle snapshot safe. The loop is reap-then-spawn, so this count is
# asked AFTER the reap, against a roster captured BEFORE it. A session this cycle
# just closed is still non-closed and still in a live state in that snapshot, so
# without the subtraction it reads as "one already running", the spawn is skipped,
# and the lane the reap just emptied is left unstaffed until the next cycle. That
# turns the timeout this bounding exists to fix into the silent stall this file's
# teardown notes call strictly worse. Refs are compared on the same
# `(.alias // .id // .name)` key lane_adhoc_sessions emits, so the two agree by
# construction rather than by coincidence.
#
# `fresh` bypasses the snapshot for the post-spawn re-probe, which is the one
# caller that MUST see the roster as it is now: the session it is asking about was
# created after the snapshot was taken, so the snapshot cannot contain it and a
# cached answer would report every successful spawn as a failure and mail on it.
lane_live_count() {
  _llc_raw="$(lane_roster "${3:-}")"
  [ -n "$_llc_raw" ] || return 0
  _states_json="$(printf '%s' "$LANE_LIVE_STATES" | jq -Rc 'split(" ")')"
  _reaped_json="$(printf '%s' "${2:-}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  printf '%s' "$_llc_raw" \
    | jq -r --arg q "$1/$QUALIFIED" --argjson live "$_states_json" --argjson reaped "$_reaped_json" '
        [ (.sessions // [])[]
          | select( ((.closed // false) | not) )
          | select( ((.alias // .id // .name // "")) as $ref
                    | $ref == "" or ($reaped | index($ref)) == null )
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
lane_tmux_socket() { sy_tmux_socket; }

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

# lane_live_sessions RIG — live sessions that speak for this lane on RIG.
#
# Matches the SAME identity rule lane_live_count and lane_role_state use: the
# bare template session (`<rig>/<qualified>`), plus any `-adhoc-` instances the
# sweep itself spawned. Only states in LANE_LIVE_STATES are returned, because a
# session that is already asleep or closed is not a lever target.
lane_live_sessions() {
  _lls_raw="$(lane_roster)"
  [ -n "$_lls_raw" ] || return 0
  _lls_states_json="$(printf '%s' "$LANE_LIVE_STATES" | jq -Rc 'split(" ")')"
  printf '%s' "$_lls_raw" \
    | jq -r --arg q "$1/$QUALIFIED" --argjson live "$_lls_states_json" '
        (.sessions // [])[]
        | select( ((.closed // false) | not) )
        | (.agent // .agent_name // .qualified_name // "") as $n
        | select( (.template // "") == $q
                  or $n == $q
                  or ($n | startswith($q + "-adhoc-")) )
        | select( (.state // "") as $st | ($live | index($st)) != null )
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
lane_rigs() { sy_lane_rigs "$QUALIFIED"; }

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

# lane_reach_fault RIG — WHY this lane's queue cannot be read for RIG, or
# nothing when there is no reachability fault to report.
#
# lane_queue_depth above answers empty for every uncertainty and deliberately
# refuses to distinguish them, because the SPAWN decision is the same for all of
# them: fail open. That stays exactly as it is — nothing here changes what is
# spawned. But one spawn decision is not one OPERATOR STORY, and collapsing the
# causes is what lets a broken credential wear the face of a drained lane
# (switchyard PRD #327, crit:7ee5962457ff).
#
# THE FAILURE THIS ENDS IS A LOOP THAT REPORTS NOTHING. With no usable token, or
# a scope resolving to no project, every cycle does this: the sweep cannot read
# the queue, so it fails open and spawns; the session cannot read the queue
# either, so it exits IDLE; the reaper closes it; the next cycle repeats. No
# command fails, no mail is sent, `gc session list` looks healthy — and the lane
# does no work for as long as the fault lasts. Every other way this order can
# fail already escalates; this was the one that did not.
#
# IT COSTS NO EXTRA NETWORK CALL, which is what lets it sit on the hot path of
# every cycle. Both cycle-level facts are already in hand ($lane_token and
# $lane_projects, each read once per cycle above), and the per-rig one is a jq
# pass over that same already-fetched project list. A classifier that re-probed
# in order to explain itself would double this order's network cost to learn
# nothing the cycle did not already know.
#
#   credential  — no `sy_` token resolved at all. Permanent: no cycle fixes it.
#   unreachable — a token DID resolve and the project list still did not come
#                 back: the instance is down, or it rejected the token.
#   scope       — the token works and the list was read, but this rig's project
#                 is not in it, or its slug is ambiguous across workspaces.
#
# The credential/unreachable split is drawn on whether a token resolved at all,
# so the two are mutually exclusive within a cycle and at most one is ever
# reported. They are separated because their remedies are: one is a credential
# to install, the other an instance to bring up or a token to re-issue.
#
# A LANE WITH NO QUEUE MAPPING IS NOT A FAULT. LANE_QUEUE_SUFFIX is empty for an
# unrecognised AGENT, which disables the queue check by design so a lane added to
# this pack later keeps working on the day it is added rather than going
# silently unstaffed. There is no queue it is failing to read, so there is
# nothing to escalate — and reporting one would page the mayor about every lane
# this pack has not taught the sweep about yet.
lane_reach_fault() {
  [ -n "$LANE_QUEUE_SUFFIX" ] || return 0
  [ -n "$lane_token" ]        || { printf 'credential';  return 0; }
  [ -n "$lane_projects" ]     || { printf 'unreachable'; return 0; }
  # Read rc IMMEDIATELY after the assignment. Any command in between — `[`
  # included — overwrites $?, and a binding fault would silently degrade into a
  # scope fault, which is precisely the misdiagnosis this class exists to end.
  # An UNHANDLED rc=3 is safe everywhere else: sy_project_for_rig emits nothing
  # on that path, so callers that only test for empty output still take their
  # cannot-answer branch exactly as before.
  _lrf_project="$(sy_project_for_rig "$1" "$lane_projects")"
  [ $? -ne 3 ] || { printf 'binding'; return 0; }
  [ -n "$_lrf_project" ] || printf 'scope'
}

# ===========================================================================
# THE IDLE-BUT-LIVE LADDER (switchyard PRD #329, crit:349ce4b5f0ee)
# ===========================================================================
#
# THE FAILURE. Everything above answers "is a session THERE?" and nothing asks
# "is it WORKING?". A headless session exits when its pass ends and settles as
# `asleep`, so the two questions coincide and the pane/state machinery above is
# sound. An `opencode` TUI does not: it finishes its pass, returns to its prompt,
# and sits in `active` forever. lane_live_count then reports 1, the main loop
# takes its `already running → leave it` arm, and the lane is declared staffed by
# a session that will never take another item. Measured on gc-fremont-fresh: the
# judging lane did nothing from 2026-08-04 to 2026-08-07 while `gc status`, tmux
# and the switchyard agent roster all read healthy. Unstuck by hand it validated
# 32 criteria in one afternoon, so the lane was never the problem — only the
# predicate that decides it is staffed.
#
# WHY A SIGNAL AND NOT A TIMER. Session state and pane text both describe the
# session's SHELL, which is exactly what stays lively while the work stops. The
# heartbeat is the only signal that moves when work moves: the agent stamps it
# over MCP as it claims and completes, so a stale heartbeat is the absence of
# WORK rather than the absence of a process. Reading it costs nothing new to
# build — the server already classifies it (see lane_role_state).
#
# WHY A LADDER AND NOT A KILL. The rungs are ordered by what they destroy:
#
#   nudge       delivers a message to a running session. Destroys nothing; a
#               session that is genuinely mid-thought ignores it. This is the
#               rung that makes acting on a MERELY SUSPECTED stall safe.
#   reset+wake  restarts the session, preserving its bead, and clears holds.
#               Discards context, so it is not first. `reset` alone is not
#               enough: it leaves the session `asleep` when fresh creates are
#               budget-constrained, so the pair is the rung, not `reset`.
#   spawn       a new session alongside. Last, because it is the only rung that
#               spends a fresh session slot.
#
# ONE RUNG PER CYCLE, AND THE RECOVERY TEST IS THE HEARTBEAT ITSELF. The next
# cycle re-reads the signal: recovered ⇒ the ladder resets and nothing further
# happens; still stale ⇒ the next rung. So the escalation is driven by whether
# the lever WORKED, not by a fixed schedule, and a nudged session that goes back
# to work is never reset.
#
# IT FAILS CLOSED, WHICH IS THE OPPOSITE OF EVERY OTHER GATE IN THIS FILE. The
# queue check, the suspended-rig guard and the reaper all fail OPEN — they act
# when unsure — because their error costs a surplus session and their silence
# costs a stalled lane. This ladder inverts that: its lever lands on a session
# that may be WORKING, and interrupting a judge mid-criterion destroys work that
# no later cycle recovers. So every uncertainty here — an unreadable briefing, a
# role with no liveness row, a queue that cannot be counted — declines to
# escalate and leaves the session alone. The cost of that silence is bounded and
# visible: one more cycle of a lane that is already stalled, and the stall itself
# is what the rung log below makes legible.

# lane_role_state RIG — this lane's liveness on RIG: `fresh`, `stale`,
# `suspended`, or EMPTY when it cannot be answered confidently.
#
# The classification is the SERVER'S, not ours. `briefing.liveness.agents[].state`
# is already computed against that project's own `stale_after_minutes`, so the
# threshold lives with the project that owns it and this script never reimplements
# staleness arithmetic in shell — where it would drift from the dashboard's answer
# and from every other reader's.
#
# ANY fresh WINS. A lane may carry more than one registered ref (a bare template
# name and an adhoc one, or two sessions mid-handover), and one heartbeating agent
# means the lane IS being worked whatever the other rows say. Collapsing to the
# healthiest row is the fail-closed direction: it withholds the ladder.
#
# `suspended` is returned rather than folded into stale because it is an
# INTENTIONAL pause — a rig the mayor stopped — and escalating against a human
# decision is the false alarm this pack has already had to unlearn once.
lane_role_state() {
  [ -n "$lane_token" ] || return 0
  _lrs_project="$(sy_project_for_rig "$1" "$lane_projects")"
  [ -n "$_lrs_project" ] || return 0

  _lrs_body="$(sy_api_get "/api/v1/projects/$_lrs_project/briefing" "$lane_token")"
  [ -n "$_lrs_body" ] || return 0

  # Matched on the SAME identity rule lane_live_count uses, so "which sessions
  # count as this lane" and "whose heartbeat speaks for this lane" cannot drift
  # apart: the exact ref the agents' prompts register (`<rig>/switchyard-ops.<agent>`),
  # plus the `-adhoc-` instances the sweep itself spawns.
  printf '%s' "$_lrs_body" | jq -r --arg q "$1/$QUALIFIED" '
      [ (.liveness.agents // [])[]
        | (.agent_ref // "") as $r
        | select( $r == $q or ($r | startswith($q + "-adhoc-")) )
        | (.state // "") | select(. != "") ]
      | if   length == 0            then empty
        elif index("fresh")     then "fresh"
        elif index("suspended") then "suspended"
        elif index("stale")     then "stale"
        else empty end' 2>/dev/null \
    | awk 'NF' | head -n1
}

# lane_rung_file RIG — where RIG's current ladder position is remembered.
#
# Keyed per AGENT *and* per rig: two lanes on one rig, and one lane across two
# rigs, are independent stalls, and sharing a marker would let a recovery on one
# silently reset the ladder on another. The rig is sanitised into the filename
# because it reaches this script from `gc rig list` rather than from a literal
# here, and one `/` in it would otherwise write outside the state directory.
lane_rung_file() {
  printf '%s/lane-ensure.%s.%s.rung' "$(sy_state_dir)" \
    "$(printf '%s' "$AGENT" | tr -c 'A-Za-z0-9._-' '_')" \
    "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
}

lane_rung_read() {
  awk 'NF{print;exit}' "$(lane_rung_file "$1")" 2>/dev/null
}

# lane_rung_clear RIG — the lane recovered; the NEXT stall starts at `nudge`.
#
# Without this the ladder is a ratchet: a lane that stalls, is nudged back to
# life, and stalls again a week later would be reset+woken on the strength of a
# rung earned by an unrelated episode. Recovery has to be forgettable for the
# cheapest rung to keep being tried first.
lane_rung_clear() {
  rm -f "$(lane_rung_file "$1")" 2>/dev/null || true
}

# lane_rung_next LAST — the rung that follows LAST. Unrecognised or exhausted
# input pins at `spawn`: a corrupt marker must not silently restart the ladder at
# the bottom and leave a lane looping on nudges forever. The terminal marker
# `spawn-done` is written after the first top-rung spawn so later cycles decline
# instead of spawning a replacement on every sweep.
lane_rung_next() {
  case "${1:-}" in
    '')          printf 'nudge' ;;
    nudge)       printf 'reset-wake' ;;
    reset-wake)  printf 'spawn' ;;
    spawn-done)  printf 'exhausted' ;;
    *)           printf 'spawn' ;;
  esac
}

# lane_record_rung RIG RUNG DETAIL — RECORD WHICH RUNG WAS TAKEN.
#
# Two records, because they answer different questions and neither substitutes
# for the other:
#
#   stdout   is the operator's answer to "what did the sweep DO about it?". It
#            is the order's output, so it lands in the supervisor log beside the
#            `order exec` line, which is where someone triaging a quiet lane is
#            already looking. This is the criterion's own requirement — a rung
#            taken silently is indistinguishable from the four-day stall this
#            PRD exists to end.
#   the file is the LADDER's memory, and the reason it can escalate at all: the
#            next cycle reads it to learn that a nudge has already been spent.
#
# The marker is written even if the lever failed. A rung that could not be pulled
# is still a rung TRIED, and retrying it forever is the loop this ladder replaces.
lane_record_rung() {
  printf '%s-sweep: %s lane on %s is idle-but-live (heartbeat stale, %s) — escalated to rung %s\n' \
    "$AGENT" "$SUBJECT" "$1" "$3" "$2"
  mkdir -p "$(sy_state_dir)" 2>/dev/null || return 0
  printf '%s\n' "$2" >"$(lane_rung_file "$1")" 2>/dev/null || true
}

# lane_escalate_idle RIG — the whole ladder for one rig on one cycle.
#
# Ordered cheapest-evidence-first, so a healthy city pays nothing: the rung is
# only ever reached by a rig that already has a live session, a countable backlog
# and a confidently stale heartbeat.
lane_escalate_idle() {
  # A lane with no queue mapping has no backlog this script can confirm, so it
  # has no idle to detect. Declining here (rather than escalating blind) keeps a
  # lane added to this pack later inert until it declares its queue, matching the
  # rule the spawn path already follows.
  [ -n "$LANE_QUEUE_SUFFIX" ] || return 0

  # NOTHING TO DO IS NOT A STALL. A session sitting quietly on a drained queue is
  # correct behaviour, and nudging it would page a working city every cycle. Only
  # a CONFIDENT count of real work qualifies — unlike the spawn path, an unknown
  # queue declines, because here the doubt argues against acting.
  _lei_depth="$(lane_queue_depth "$1")"
  case "${_lei_depth:-}" in
    '' | *[!0-9]*) return 0 ;;
    0)             return 0 ;;
  esac

  # The briefing read is deliberately BELOW the queue check, so it is paid only
  # for a rig that has both a live session and real work waiting. A drained or
  # unstaffed lane costs no extra call at all.
  _lei_state="$(lane_role_state "$1")"
  case "${_lei_state:-}" in
    fresh)
      # WORKING. This is also the recovery path: whatever rung a previous cycle
      # spent, the lever worked, so the ladder is forgotten.
      lane_rung_clear "$1"
      return 0
      ;;
    stale) : ;;
    # `suspended` (a deliberate pause) and empty (no liveness row, an unreadable
    # briefing, an unresolvable project) both decline. Neither is evidence of a
    # stall, and acting on either lands a lever on a session that may be fine.
    *) return 0 ;;
  esac

  _lei_rung="$(lane_rung_next "$(lane_rung_read "$1")")"

  # The session to act on. The broad live-session predicate matches both the
  # bare template session and adhoc spawns, using the SAME identity rule
  # lane_live_count and lane_role_state use, so "counts as this lane" and
  # "speaks for this lane" cannot drift apart. It is empty only when no live
  # target exists; in that case nudge/reset cannot be delivered and the rung
  # degrades to spawn, which creates one rather than addressing one.
  _lei_ref="$(lane_live_sessions "$1" 2>/dev/null | awk -F"$LANE_TAB" 'NF{print $1; exit}')"
  if [ -z "${_lei_ref:-}" ] && [ "$_lei_rung" != spawn ] && [ "$_lei_rung" != exhausted ]; then
    _lei_rung=spawn
  fi

  case "$_lei_rung" in
    nudge)
      gc session nudge "$_lei_ref" \
        "$SUBJECT lane: your heartbeat has gone stale while $_lei_depth item(s) wait. If your pass is finished, exit so the lane can be restaffed; if you are still working, ignore this." \
        >/dev/null 2>&1 || true
      lane_record_rung "$1" nudge "$_lei_depth waiting, session $_lei_ref"
      ;;
    reset-wake)
      # PAIRED, NOT `reset` ALONE — see the ladder note above. `wake` runs even
      # if `reset` reported failure: the pair exists to leave the session RUNNING,
      # and a reset that half-succeeded still needs the hold cleared.
      gc session reset "$_lei_ref" >/dev/null 2>&1 || true
      gc session wake  "$_lei_ref" >/dev/null 2>&1 || true
      lane_record_rung "$1" reset-wake "$_lei_depth waiting, session $_lei_ref"
      ;;
    exhausted)
      # The ladder has already spent the top rung for this stall. Spawning again
      # on every subsequent cycle would fill the rig with replacement sessions.
      # Declining is bounded and visible: the lane stays on the log it already
      # recorded, and recovery (fresh heartbeat) clears the marker.
      return 0
      ;;
    spawn)
      # THE TOP RUNG DELIBERATELY STACKS A SECOND SESSION. The guard that would
      # normally forbid this counts the zombie as live, which is precisely the
      # reading this ladder has spent two rungs disproving. The surplus is the
      # cheaper error by this file's own standing argument: an extra session is
      # visible in `gc session list` and the reaper closes it once its pane says
      # it finished, whereas the lane it replaces is stalled invisibly.
      #
      # It is NOT reaped here. Closing a session the pane has not declared
      # finished is the one action this pack refuses everywhere else, and a
      # heartbeat is not pane evidence.
      _lei_id="$(lane_spawn "$1")"
      lane_record_rung "$1" spawn "$_lei_depth waiting, spawned ${_lei_id:-<identity unread>}"
      # Pin the ladder at the terminal marker so later cycles decline instead of
      # spawning a replacement on every sweep. The stdout report still says
      # `spawn`; the file only remembers that the top rung is spent.
      printf '%s\n' spawn-done >"$(lane_rung_file "$1")" 2>/dev/null || true
      ;;
  esac
  return 0
}

# ===========================================================================
# SERVER-SIDE ROLE GOVERNANCE + ROLE LIVENESS (switchyard PRD #365,
# crit:fc020b45069d)
# ===========================================================================
#
# THE GAP THIS CLOSES. The server carries per-project role GOVERNANCE (the
# project_roles registry: which roles MAY run) and per-role LIVENESS
# (project_role_liveness: which roles ARE reporting), and the companion honors
# both — its RoleSupervisor refuses a disabled role at startup and stamps each
# running role's heartbeat. The pack honored neither: an operator who disabled a
# role in project settings kept paying for that lane's sessions anyway, and a
# project driven entirely by pack lanes read permanently DARK on the dashboard's
# role-liveness surface, because nothing ever stamped it. Each signal is one
# cheap HTTP call, which is what lets both sit on the order script's own cycle:
# deterministic HTTP, no session started and no model tokens spent.
#
# WHICH ROLE A LANE IS is declared beside its queue (LANE_ROLE, in the case
# block at the top), and an unmapped lane is untouched by BOTH halves — the
# same day-one-keeps-working rule the queue check follows.
#
# THE GATE FAILS OPEN, like every other spawn-side gate in this file: only a
# CONFIDENT `enabled:false` withholds a spawn. An unreadable registry, a
# missing token, an unresolvable project, a response without this role, a
# non-boolean `enabled` — all answer EMPTY, and the sweep behaves byte-for-byte
# as it did before governance existed. The boolean strictness is the same
# safety property the queue count's array strictness buys: without it an error
# envelope or a renamed field could read as a verdict and silently unstaff a
# lane that has work.
#
# ONE MAIL PER TRANSITION, NOT PER CYCLE OR PER EPISODE-FOREVER. A disable is
# announced once when it is first seen, a re-enable once when it ends the
# pause; the cycles in between are silent. This is the lane_escalate_once
# marker idiom with BOTH edges reported, because a governance pause is a human
# decision whose end matters as much as its start: an operator re-enabling a
# role should hear the pack obey without grepping session lists.

# lane_role_verdict RIG — the server's governance verdict on this lane's mapped
# role for RIG's project: `enabled`, `disabled`, or NOTHING when no confident
# answer exists (no mapping, no token, no resolvable project, an unreadable
# registry, a role the response does not carry, a non-boolean enabled). Callers
# must treat empty as "no verdict" and change nothing on it, in either
# direction — see the fail-open note above and lane_role_resume's fail-safe one.
lane_role_verdict() {
  [ -n "$LANE_ROLE" ] || return 0
  [ -n "$lane_token" ] || return 0
  _lrv_project="$(sy_project_for_rig "$1" "$lane_projects")"
  [ -n "$_lrv_project" ] || return 0
  _lrv_body="$(sy_api_get "/api/v1/projects/$_lrv_project/roles" "$lane_token")"
  [ -n "$_lrv_body" ] || return 0
  printf '%s' "$_lrv_body" | jq -r --arg r "$LANE_ROLE" '
      [ (.roles // [])[]
        | select((.role // "") == $r)
        | .enabled
        | select(type == "boolean")
        | if . then "enabled" else "disabled" end ]
      | first // empty' 2>/dev/null \
    | awk 'NF' | head -n1
}

# lane_role_marker RIG — where "this rig's lane is paused by governance" is
# remembered between cycles, so the pause and resume mails fire once per
# TRANSITION rather than once per cycle. Keyed per AGENT and per rig like
# lane_rung_file, and sanitised the same way for the same reason.
lane_role_marker() {
  printf '%s/lane-ensure.%s.role-disabled.%s' "$(sy_state_dir)" \
    "$(printf '%s' "$AGENT" | tr -c 'A-Za-z0-9._-' '_')" \
    "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
}

# lane_role_pause RIG — the registry says disabled: announce the transition to
# the mayor ONCE. The skip itself never depends on this function or its marker
# — the caller has already declined to spawn on the verdict alone — so a broken
# mail path degrades the announcement, never the governance.
#
# The marker is written only when the mail is accepted, like lane_escalate_once:
# a failed send leaves no record, so the next cycle retries the announcement
# while the skip continues regardless.
lane_role_pause() {
  _lrp_marker="$(lane_role_marker "$1")"
  [ -f "$_lrp_marker" ] && return 0
  mkdir -p "$(sy_state_dir)" 2>/dev/null || return 0
  gc mail send mayor \
    -s "$AGENT-sweep: $LANE_ROLE role disabled — $SUBJECT lane paused on $1" \
    -m "The role registry for $1's switchyard project reports the \`$LANE_ROLE\` role DISABLED, so the $SUBJECT lane is skipped before any spawn on $1: no session will be started there until the role is re-enabled in the project's settings. Finished sessions are still reaped — governance withholds the spawn, not the cleanup, the same split the suspended-rig guard draws. This is the server's own per-project verdict being obeyed, not a pack fault: nothing here needs fixing unless the disable was unintended. One mail per transition: this notice does not repeat while the role stays disabled, and a matching notice is sent when it is re-enabled." \
    >/dev/null 2>&1 || return 0
  : > "$_lrp_marker" 2>/dev/null || true
}

# lane_role_resume RIG — the registry says enabled and a pause stands on
# record: close the episode with ONE resume mail and clear the marker. Only a
# CONFIDENT `enabled` reaches here (the caller's empty-verdict arm changes
# nothing), so a registry blip can neither end an episode nor mail a false
# resume — the fail-SAFE direction, where the gate itself fails open.
#
# The marker is cleared only when the mail is accepted, so a failed send
# retries next cycle rather than losing the transition. While it waits, a
# re-disable sends no second pause mail — the standing marker is right: that is
# one continuing episode, not a new one.
lane_role_resume() {
  _lrr_marker="$(lane_role_marker "$1")"
  [ -f "$_lrr_marker" ] || return 0
  gc mail send mayor \
    -s "$AGENT-sweep: $LANE_ROLE role re-enabled — $SUBJECT lane resumed on $1" \
    -m "The role registry for $1's switchyard project reports the \`$LANE_ROLE\` role enabled again, so the $SUBJECT lane resumes normal spawning on $1 from this cycle onward. This closes the pause announced under \"$AGENT-sweep: $LANE_ROLE role disabled — $SUBJECT lane paused on $1\"." \
    >/dev/null 2>&1 || return 0
  rm -f "$_lrr_marker" 2>/dev/null || true
}

# lane_role_heartbeat RIG — stamp the mapped role's liveness for RIG's project
# (POST .../roles/<role>/heartbeat), so project_role_liveness reflects a
# project whose roles are driven by pack lanes instead of reading permanently
# dark. Best-effort in both directions: an accepted stamp needs no answer read,
# and a refused or unreachable one changes nothing about the sweep — liveness
# reporting must never be the reason a lane went unstaffed.
#
# The agent_ref is informational (the dashboard names who holds the role); the
# rig-qualified lane name is the honest answer. It is built with jq rather than
# interpolated because the rig name is data from `gc rig list`, and one quote
# in it would otherwise break the JSON silently.
#
# THIS CANNOT MASK THE IDLE LADDER, and that is checked fact rather than hope:
# the stamp writes project_role_liveness (role-keyed), while lane_role_state
# reads the briefing's liveness.agents block, which the server assembles from
# AGENT registrations — a different table. The sweep saying "this lane is
# tended" therefore never overwrites the stalled-session heartbeat the ladder
# escalates on.
lane_role_heartbeat() {
  [ -n "$LANE_ROLE" ] || return 0
  [ -n "$lane_token" ] || return 0
  _lrh_project="$(sy_project_for_rig "$1" "$lane_projects")"
  [ -n "$_lrh_project" ] || return 0
  _lrh_body="$(jq -nc --arg ref "$1/$QUALIFIED" '{agent_ref: $ref}' 2>/dev/null)"
  [ -n "$_lrh_body" ] || _lrh_body='{"agent_ref":""}'
  sy_api_post "/api/v1/projects/$_lrh_project/roles/$LANE_ROLE/heartbeat" \
    "$lane_token" "$_lrh_body" >/dev/null
  return 0
}

# lane_agent_probe — did `gc agent list --json` ANSWER, as distinct from what it
# answered? Echoes the agent count (possibly 0) when the probe returned a
# parseable list, and nothing when the probe itself failed.
#
# lane_rigs cannot tell these apart: an older gc without `agent list --json` and
# a healthy city that simply does not define this lane BOTH reduce to an empty
# set there. They demand opposite verdicts below — "cannot tell" and
# "definitively not configured" — so the distinction has to be drawn here, from
# whether the probe spoke at all.
lane_agent_probe() {
  gc agent list --json 2>/dev/null \
    | jq -r '(if type=="array" then . else (.agents // []) end) | length' 2>/dev/null \
    | awk 'NF' | head -n1
}
agents_probe="$(lane_agent_probe)"

defined_rigs="$(lane_rigs)"
rigs="$defined_rigs"

# Fall back to the old coordinator derivation when the agent probe yields nothing
# (an older gc build, or one whose `agent list` lacks --json). Covering the rigs
# we can still name beats silently covering none — which is the exact failure
# this whole change exists to end.
[ -n "$rigs" ] || rigs="$(sy_coordinators | sed 's#/.*$##' | awk 'NF' | sort -u)"

# lane_defined RIG — does RIG actually DEFINE this lane's agent?
#
# This is the whole difference between the two failure conditions below, and it
# is answered STRUCTURALLY rather than by matching `gc session new`'s error
# prose. Error text is the worst possible discriminator here: it is unversioned,
# varies between gc builds, and is the one thing guaranteed to change without
# notice — whereas "is the agent in `gc agent list`?" is the same published
# contract lane_rigs already depends on.
#
# This can only ever answer NO for a rig reached through the sy_coordinators
# FALLBACK above — a rig reached through the agent-derived set is defined by
# construction, since that set IS the agents. So the unconfigured verdict means
# something precise: we are sweeping a rig because it has a coordinator, and the
# lane's own agent is not there.
#
# FAILS TOWARD "DEFINED", but on the PROBE rather than on the set. An empty
# $defined_rigs is ambiguous — an older gc that cannot answer `agent list --json`
# and a healthy city that simply does not define this lane both land there — so
# the test is $agents_probe, which is empty only in the first case. Gating on the
# emptiness of $defined_rigs instead would be worse than not classifying at all:
# it makes "unconfigured" UNREACHABLE, because the fallback that produces those
# rigs runs precisely when that set is empty.
#
# The direction matters. Calling a working lane "unconfigured" sends an operator
# to fix an import that is already correct while the real fault goes unnamed —
# and a wrong remedy is acted on, where a vague one is merely ignored.
#
# -F, because a rig name is data: `grep -qx` would read a metacharacter in it as
# a pattern and match the wrong rig.
lane_defined() {
  [ -n "$agents_probe" ] || return 0
  printf '%s\n' "$defined_rigs" | grep -qxF "$1"
}

# No coordinators is a legitimate state (all rigs suspended, or a fresh city).
[ -n "$rigs" ] || exit 0

# A spawn that hands back no identity is TWO different faults wearing one string,
# and this sweep used to mail both under "could not start a <lane>" with a single
# remedy attached ("check the agent is imported"). That remedy is right for one
# of them and actively misleading for the other:
#
#   unconfigured — the rig does not define this lane's agent. Permanent, and no
#                  amount of re-running fixes it; a human must import the agent.
#   handshake    — the lane IS configured and the spawn still did not come up.
#                  Transient and load-induced: under saturation a new session
#                  misses its startup handshake, so the identity readback comes
#                  back empty. The next cycle retries and usually succeeds.
#
# Conflating them is not a cosmetic problem on this particular sweep, because
# this sweep MANUFACTURES the second condition (PRD #299): retained sessions
# saturate the host, saturation breaks the handshake, and the broken handshake
# is reported in words that point the reader at the rig's config. Every such
# mail sent an operator to inspect an import that was fine, while the actual
# cause — the leak this PRD fixes — went unnamed. Measured 2026-08-03: 14
# concurrent adhoc sessions across two rigs, load excursion to 311 on a 16-core
# box, and the alarm the whole time read "check the agent is imported".
unconfigured=""
handshake=""

# The reachability faults, accumulated by lane_reach_fault inside the loop and
# mailed at the foot beside the two spawn faults above. Same shape deliberately:
# a fault is a space-separated rig list, empty means "did not happen", and one
# cycle sends at most one mail per condition however many rigs it names.
reach_credential=""
reach_unreachable=""
reach_scope=""
reach_binding=""
uncovered=""

# ONE ROSTER READ FOR THE WHOLE CYCLE — see the bounding note above.
#
# Taken here rather than at the top of the file so it is as fresh as possible when
# the loop starts, and after every cheap local reason to exit (no rigs at all) has
# already run: a city with nothing to sweep should not pay for a roster read.
SY_SESSION_SNAPSHOT="$(sy_timeout "$LANE_ROSTER_TIMEOUT" gc session list --json --state all 2>/dev/null)" \
  || SY_SESSION_SNAPSHOT=""

# AN UNREADABLE ROSTER ENDS THE SWEEP RATHER THAN GRINDING THROUGH IT.
#
# Not an optimisation. With no snapshot every lane_live_count falls back to its own
# read, which is the 22-call shape this change exists to remove — and it buys
# nothing, because a roster that cannot be read cannot answer "is one already
# running?" for ANY rig: every rig would take the "cannot confirm absent" branch
# and skip. So the whole loop is already decided, and running it just spends ~8
# minutes to reach the same verdict, which is how this failure stayed invisible.
#
# Escalated, because a lane that cannot be swept at all is exactly the condition
# that went unreported for four days. Deduped like every other notice here.
if [ -z "$SY_SESSION_SNAPSHOT" ]; then
  lane_escalate_once "roster-unreadable" \
    "$AGENT-sweep: session roster unreadable, lane not swept" \
    "\`gc session list --json --state all\` returned nothing within ${LANE_ROSTER_TIMEOUT}s, so no rig's liveness could be determined and the $SUBJECT lane was not swept this cycle: nothing was reaped and nothing was spawned. This is a gc/Dolt read problem, not a lane problem — check host load and \`gc doctor\` before touching this pack. The next cycle retries on its own; this notice repeats at most once per episode and clears itself on the first sweep that completes."
  exit 0
fi

for rig in $rigs; do
  # PER-LANE RIG RESTRICTION. A wrapper (security-scan.sh) can export
  # LANE_RIGS_FILTER as a space-separated allowlist; a rig not on it is
  # skipped ENTIRELY — no spawn, no reap, no escalation — because for a
  # filtered lane that rig is not merely unstaffed, it is out of the lane's
  # scope, exactly as if the roster never named it. Empty/unset means no
  # restriction (every existing caller). This is the *_RIGS roster idiom
  # reaching the lanes that delegate their rig walk to this script instead of
  # walking rigs themselves.
  if [ -n "${LANE_RIGS_FILTER:-}" ]; then
    _lrf_hit=0
    for _lrf in $LANE_RIGS_FILTER; do
      [ "$_lrf" = "$rig" ] && { _lrf_hit=1; break; }
    done
    [ "$_lrf_hit" -eq 0 ] && continue
  fi

  # SPEND THE BUDGET, THEN NAME WHAT WAS MISSED — do not just stop.
  #
  # `continue` rather than `break` so the remaining rigs are still collected by
  # name for the escalation below. Skipping them costs nothing (no subprocess runs
  # past this point), and a report that says WHICH rigs went unswept is the
  # difference between an actionable alarm and the single log line this bug hid
  # behind for four days.
  if lane_over_budget; then
    uncovered="$uncovered $rig"
    continue
  fi

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
  #
  # The refs are CAPTURED rather than discarded now that the roster is read once
  # per cycle: lane_live_count below is asked against a snapshot taken before this
  # reap ran, so it must be told what this reap closed or it will count those
  # sessions as live and skip the spawn. See lane_live_count's own note.
  reaped="$(lane_reap "$rig")"

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

  # SERVER-SIDE ROLE GOVERNANCE GATES THE SPAWN (switchyard PRD #365,
  # crit:fc020b45069d). Placed AFTER the reap and the suspension guard, and
  # BEFORE everything that can start a session — which includes
  # lane_escalate_idle's top rung, not just the spawn at the loop's foot — so a
  # disabled verdict is honored before ANY spawn. Like suspension, a disabled
  # role withholds the spawn and never the reap: a role disabled while its
  # session is finishing must still be swept, or governance opens the exact
  # retention hole the suspended-rig guard's own notes close.
  #
  # Only the two CONFIDENT verdicts act. The empty answer — no mapping for
  # this lane, no token, no project, an unreadable registry — falls through
  # with nothing withheld, nothing mailed and nothing cleared: fail-open on
  # the spawn side (the asymmetry every gate here shares), and fail-safe on
  # the episode side, since a blip that ended a pause would mail a false
  # resume and re-announce the same pause when the registry answers again.
  case "$(lane_role_verdict "$rig")" in
    disabled) lane_role_pause "$rig"; continue ;;
    enabled)  lane_role_resume "$rig" ;;
  esac

  # THE ROLE'S LIVENESS HEARTBEAT, STAMPED FROM THE ORDER SCRIPT each cycle,
  # for every rig the sweep tends — whether it then spawns, finds a session
  # already live, or finds the queue drained: the lane is being kept staffed
  # either way, and that is what the stamp asserts. Deliberately NOT stamped
  # for a rig whose role is disabled (skipped above — the server reads a
  # disabled role's silence as expected, and a fresh stamp would make a
  # switched-off role read alive) nor one the mayor suspended.
  lane_role_heartbeat "$rig"

  n="$(lane_live_count "$rig" "$reaped")"
  case "$n" in
    ''|*[!0-9]*) continue ;;      # cannot confirm absent → do not stack a second
    0) lane_rung_clear "$rig" ;;  # confirmed none live → spawn below
    # ALREADY RUNNING IS NOT THE SAME AS ALREADY WORKING (PRD #329).
    #
    # This arm used to `continue` unconditionally, and that is the silent stall:
    # a finished `opencode` session stays `active` forever, so the lane reads
    # staffed by a session that will never take another item. Ask the heartbeat
    # before believing the roster — see the ladder above, which declines unless
    # the lane has confirmed work AND a confidently stale heartbeat.
    *) lane_escalate_idle "$rig"; continue ;;
  esac

  # THE BALANCER'S TARGET FOR THIS LANE IS A CEILING ON THE SPAWN BELOW
  # (switchyard PRD #397). sy_balancer_capped applies the one rule every spawn
  # site in this pack shares — present, fresh and well-formed, min() never
  # max(), and an absent/stale/malformed/unreadable file answering "no target"
  # so the lane behaves byte-for-byte as it does today. Keeping the rule in
  # roster.sh rather than re-deriving it here is the point: a rule
  # re-implemented per caller is the same rule only by coincidence.
  #
  # THE CEILING PASSED IS 1 BECAUSE THAT IS THIS SWEEP'S WHOLE FAN-OUT. The
  # loop staffs at most one session per rig — the `case "$n"` above spawns only
  # on a confirmed zero — so min(1, target) can land only on 1 or 0. A target
  # ABOVE 1 is therefore not authority to stack a second session, which is
  # exactly what min() is for; zero is the only value that moves this lane, and
  # it is the one the global budget actually spends when it takes the lane's
  # allocation to nothing.
  #
  # PLACED AFTER THE REAP AND BEFORE THE QUEUE READ, both deliberately. Reaping
  # is cleanup, not capacity: gating it here would retain a finished session for
  # as long as the cap lasts, a retention hole inside the guard meant to bound
  # the lane. And this is a local file read while lane_queue_depth is the loop's
  # only network call, so the cheaper gate answers first — the same ordering the
  # queue check's own note argues for. Sitting above lane_reach_fault also keeps
  # that classifier's precision: a capped rig is not one this sweep was about to
  # staff, so it does not belong in the mails that name the rigs it could not
  # read a queue for.
  if [ "$(sy_balancer_capped "$rig" "$AGENT" 1)" = 0 ]; then
    continue
  fi

  # WHY THE QUEUE MIGHT NOT BE READABLE, recorded for the escalation at the foot.
  #
  # OBSERVATIONAL ONLY. It records a cause; it never withholds a spawn. The
  # fail-open contract below is untouched, and lane-queue.test.sh asserts that
  # independently of anything here.
  #
  # ITS PLACEMENT IS THE ESCALATION'S PRECISION, not tidiness. Reaching this line
  # means the rig survived every earlier gate: it is not suspended, and it has no
  # live session. So the mails below name only rigs this sweep was genuinely
  # about to staff and could not read a queue for — which is exactly the set that
  # goes quietly idle. Classifying at the top of the loop instead would page the
  # mayor about rigs the mayor has suspended, and about lanes that are working,
  # every cycle: the false-alarm pattern the spawn classifier above already had
  # to unlearn once.
  case "$(lane_reach_fault "$rig")" in
    credential)  reach_credential="$reach_credential $rig" ;;
    unreachable) reach_unreachable="$reach_unreachable $rig" ;;
    scope)       reach_scope="$reach_scope $rig" ;;
    binding)     reach_binding="$reach_binding $rig" ;;
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

  # NO IDENTITY IS NOT YET EVIDENCE THE LANE IS UNSTAFFED. `gc session new`
  # regularly STARTS a session whose identity we then fail to read back — that is
  # the same load coupling described above, and it is also what the two
  # plain-text fallbacks in lane_spawn exist to paper over. So re-probe the
  # roster before alarming: this is the check that keeps a rig with a live
  # session out of BOTH mails.
  #
  # Without it the sweep's own alarms scale with load rather than with breakage,
  # which is how an operator learns to ignore them.
  # FRESH, not the snapshot: the session this asks about was created seconds ago
  # by lane_spawn, so it cannot be in a roster captured before the loop. Answering
  # it from the snapshot would report every successful spawn whose identity we
  # failed to read back as a failure, and mail the mayor about a working lane.
  n2="$(lane_live_count "$rig" "" fresh)"
  case "$n2" in
    ''|*[!0-9]*) continue ;;      # cannot confirm unstaffed → do not alarm (see below)
    0) : ;;                       # confirmed still none → a real failure; classify it
    *) continue ;;                # live after all → the spawn worked; say nothing
  esac
  # The unreadable case is silent for the SAME reason the first probe is: acting
  # on an unknown is what produced the false alarms. It cannot hide a real
  # outage, either — an unreadable roster also stops the next cycle spawning, so
  # a persistently unreadable `gc session list` surfaces as loop-health's
  # probe-down rather than being swallowed here.

  if lane_defined "$rig"; then
    handshake="$handshake $rig"
  else
    unconfigured="$unconfigured $rig"
  fi
done

# Two conditions, two subject lines, two remedies. The subjects are distinct on
# their own — a reader triaging an inbox must be able to tell which fault this is
# without opening the mail, and mail threading groups on subject, so a recurring
# handshake blip never buries a one-off config fault in the same thread.
#
# THE REACHABILITY MAILS BELOW EXTEND THAT RULE RATHER THAN REOPENING IT: one
# subject per remedy, because the whole point of splitting them is that an
# operator can act on the subject alone.
if [ -n "$unconfigured" ]; then
  gc mail send mayor \
    -s "$AGENT-sweep: $SUBJECT lane is not configured" \
    -m "No \`$QUALIFIED\` agent is defined for:$unconfigured. These rigs were swept because they have a switchyard coordinator, but the $SUBJECT lane itself was never imported into them, so \`gc session new <rig>/$QUALIFIED --no-attach\` has nothing to start and no cycle can fix this on its own. Import the $AGENT agent into these rigs (or stop sweeping them), then re-run. This is a configuration fault, NOT the load-induced startup failure reported under \"$AGENT-sweep: $SUBJECT did not come up\"." \
    >/dev/null 2>&1
fi

if [ -n "$handshake" ]; then
  gc mail send mayor \
    -s "$AGENT-sweep: $SUBJECT did not come up" \
    -m "\`gc session new <rig>/$QUALIFIED --no-attach\` returned no session identity for:$handshake, and a re-probe confirmed no live session for them. The $AGENT agent IS defined for these rigs, so this is not a missing import — it is the startup handshake failing, which on this sweep is normally load: a saturated host cannot complete a session handshake inside the spawn call. Check host load and the live adhoc session count before changing any config; the next cycle retries on its own and usually succeeds. Only if it persists on an unloaded host is it worth spawning one by hand to see the real error." \
    >/dev/null 2>&1
fi

# THE REACHABILITY ESCALATIONS (switchyard PRD #327, crit:7ee5962457ff).
#
# The three above all describe a session that did not start. These describe the
# opposite and worse shape: a session that starts perfectly, finds it cannot see
# switchyard, and exits IDLE — cycle after cycle, silently. Nothing fails, so
# nothing was ever reported, and the lane's backlog simply does not move.
#
# THEY DO NOT WITHHOLD ANYTHING. The queue check still fails open on every one of
# these; the sweep still spawns. Escalating is the entire behaviour change, which
# is what keeps this safe: the worst case is a mail about a lane that is working.
#
# THEY REPEAT WHILE THE FAULT DOES, matching the two mails above rather than
# inventing a dedup this order has never had. A credential or a grant is a human
# fix, and the cadence of the reminder is the sweep's interval by design — the
# alternative is a fault that announces itself once and is then forgotten for as
# long as it lasts, which is the silence this criterion exists to end.
if [ -n "$reach_credential" ]; then
  gc mail send mayor \
    -s "$AGENT-sweep: no switchyard credential" \
    -m "No switchyard API token resolved this cycle, so the $SUBJECT lane's queue could not be read for:$reach_credential. These rigs were still spawned into — the check fails open — but a session that cannot reach switchyard has no queue to work and exits IDLE, so the lane is running and doing nothing. Neither \`SWITCHYARD_API_TOKEN\` nor the file \`switchyard-mcp token-path\` names holds a usable token; install one (\`switchyard-mcp login\`) or set the variable for the order's environment. This is a missing credential, NOT the rejected-or-down instance reported under \"$AGENT-sweep: switchyard is unreachable\"." \
    >/dev/null 2>&1
fi

if [ -n "$reach_unreachable" ]; then
  gc mail send mayor \
    -s "$AGENT-sweep: switchyard is unreachable" \
    -m "A switchyard API token resolved, but \`GET /api/v1/projects\` returned nothing this cycle, so the $SUBJECT lane's queue could not be read for:$reach_unreachable. These rigs were still spawned into — the check fails open — but a session that cannot reach switchyard exits IDLE, so the lane is running and doing nothing. Either the instance is down or it rejected the token: check the instance named by \`SWITCHYARD_BASE_URL\` is serving, then whether the token has been revoked or expired and re-issue it. A token holds this shape until it is replaced, so unlike a startup blip this does not clear on its own. This is a rejected-or-down instance, NOT the missing credential reported under \"$AGENT-sweep: no switchyard credential\"." \
    >/dev/null 2>&1
fi

if [ -n "$reach_scope" ]; then
  gc mail send mayor \
    -s "$AGENT-sweep: $SUBJECT lane has no switchyard project" \
    -m "switchyard answered and the token is good, but no single project matches the rig name for:$reach_scope, so the $SUBJECT lane's queue could not be read for them. These rigs were still spawned into — the check fails open — but a session with no project to scope to exits IDLE, so the lane is running and doing nothing. A rig NOT named in RIG_PROJECTS is matched to the project whose slug EQUALS the rig name, and exactly one match is required. So this is either no match or more than one. NO MATCH IS USUALLY NOT AN ACCESS PROBLEM: the likeliest cause by far is that the intended project is perfectly reachable and simply carries a different slug — rig \`switchyard-forge\` does not match slug \`forge\`, because the rule is EQUALITY, not resemblance and not uniqueness. Confirm what this token can actually see before chasing a grant it may already have. MORE THAN ONE means the slug exists in several of its workspaces and a rig name cannot say which. THE FIX FOR BOTH, AND IT NEEDS NO RENAME: bind the rig explicitly in the city's roster.conf — RIG_PROJECTS=\"<rig>=<tenant-slug>/<project-slug>\" — which also resolves the ambiguous case a rename cannot. Renaming the project slug to equal the rig name works too, but makes a cloud-side identifier load-bearing for a local rig name. This is a scope fault: the credential itself is working, which is why it is not reported under \"$AGENT-sweep: no switchyard credential\"." \
    >/dev/null 2>&1
fi

# THE BINDING FAULT IS THE OPERATOR'S OWN CONFIG, and is deliberately NOT folded
# into the scope fault above. The two demand opposite actions: a scope fault asks
# you to CREATE a binding, a binding fault says the one you already wrote is
# wrong. Reporting the second as the first would send an operator to add a
# RIG_PROJECTS entry that is already sitting there — the same wrong-cause chase
# the scope text above was just corrected to stop.
if [ -n "$reach_binding" ]; then
  gc mail send mayor \
    -s "$AGENT-sweep: $SUBJECT lane has a broken RIG_PROJECTS binding" \
    -m "switchyard answered and the token is good, and the city's roster.conf DOES bind these rigs — but the project each binding names is not reachable by this token, so the $SUBJECT lane's queue could not be read for:$reach_binding. These rigs were still spawned into — the check fails open — but a session with no project to scope to exits IDLE, so the lane is running and doing nothing. Unlike the scope fault, nothing here is missing: RIG_PROJECTS names a target and the target does not answer. Check the entry for a typo in either half of \`<tenant-slug>/<project-slug>\`, that the value is the FULL tenant-qualified pair rather than a bare project slug, and that this token still holds a grant on that project — a revoked or expired grant presents exactly this way. The binding is honored as written and is never silently replaced by a slug match, so the lane stays down until the entry is corrected. This is a broken binding, NOT the absent one reported under \"$AGENT-sweep: $SUBJECT lane has no switchyard project\"." \
    >/dev/null 2>&1
fi

# A SWEEP THAT RAN OUT OF TIME IS A REPORTED FAILURE, NOT A QUIET ONE (sw-jqrx).
#
# This is the condition that replaces `context deadline exceeded`. Before, an
# over-long sweep was killed by the order runner mid-rig: no record of how far it
# got, which rigs it covered, or that the lane had gone unswept at all. Now it
# stops itself while it still has a voice, and says exactly which rigs it did not
# reach — so the alarm names the gap instead of merely proving something died.
#
# The distinction matters for the remedy too: rigs listed here were never
# examined, so nothing can be concluded about their lanes. That is different from
# a rig that was checked and found healthy, and the mail says so rather than
# leaving a reader to assume the sweep's silence meant coverage.
if [ -n "$uncovered" ]; then
  lane_escalate_once "budget-exceeded" \
    "$AGENT-sweep: sweep ran out of time, rigs left unswept" \
    "The $SUBJECT sweep hit its ${LANE_SWEEP_BUDGET_SECONDS}s budget and stopped before covering:$uncovered. Those rigs were NOT examined this cycle — nothing was reaped and nothing was spawned for them, and no conclusion should be drawn about their lanes. Rigs swept before the budget ran out were handled normally. This bound is the sweep's own, deliberately inside gc's order-exec deadline, so this mail replaces the silent \`order exec $AGENT-sweep failed: context deadline exceeded\` that hid this condition for four days (sw-jqrx). If it recurs on an unloaded host the sweep has genuinely outgrown its budget: raise LANE_SWEEP_BUDGET_SECONDS, or reduce the per-rig cost. This notice repeats at most once per episode and clears itself on the first sweep that covers every rig."
else
  # THE EPISODE IS OVER. Clearing on the clean sweep is what makes these notices
  # episodic rather than one-shot: the next occurrence mails again instead of being
  # permanently muted by a marker nothing ever removes. Both keys clear here — a
  # sweep that covered every rig necessarily read the roster to do it.
  lane_clear_escalation "budget-exceeded"
  lane_clear_escalation "roster-unreadable"
fi

exit 0
