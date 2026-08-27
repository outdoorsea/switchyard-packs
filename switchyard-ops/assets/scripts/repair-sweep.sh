#!/bin/sh
# repair-sweep: notice a real judgment rejection and put exactly one worker on it
# (switchyard PRD #330, crit:b6ea44d544e6).
#
# WHY THIS EXISTS. PRD #315 made a rejection DURABLE — the judge's reason is
# required, stored, and folded into retry guidance — and said in its own
# out-of-scope that it would not ROUTE. Nothing has since. So a `fail` verdict
# resets the criterion to `outstanding`, writes the reason onto the delivering
# bead, and then waits for a human to notice. This order is the routing half: it
# reads the rejections the ledger already recorded and hands each one to a
# worker, once.
#
# JUDGMENT LIVES IN THE SESSION, NOT HERE. Like intake-sweep, this script only
# decides WHO to wake and about WHICH criterion. What a repair should actually
# change is decided inside the brakeman session that receives the assignment,
# which has the switchyard MCP and can read the verdict, the diff and the
# lineage. This file must never grow a judgment about the code under repair.
#
# ONLY A RECORDED `fail` COUNTS. The sweep keys on the verdict ledger's
# verdict == "fail", never on criterion status. That distinction is the whole
# point: a criterion that is merely unvalidated, deferred, or contract-failed is
# `outstanding` with a closed bead too, so a status-based sweep would route
# repair work for criteria nobody has judged at all. `verdict` is the only
# recorded field that separates "a judge looked and refused this" from "nobody
# has looked yet" — a rejected criterion is otherwise byte-identical to an
# unjudged one on every read the API offers.
#
# EXACTLY ONE ASSIGNMENT PER REJECTED CRITERION, AND NEVER A SECOND WHILE THE
# FIRST IS LIVE. Two independent guards, because they answer different questions
# and either alone leaks:
#
#   * a LIVE CLAIM on the criterion means a worker already holds the repair —
#     it does not matter whether we are the sweep that routed them;
#   * a LIVE ASSIGNMENT MARKER means WE routed a worker who has not yet taken
#     the claim, which no read of the criterion can show (a dispatched worker
#     that has not called claim yet is indistinguishable from an idle one).
#
# A cycle that routed nobody must leave nothing live, so the marker is written
# ONLY after the nudge actually succeeds. Writing it first would let a failed
# dispatch suppress its own retry — the criterion would read as "assigned"
# forever with no worker on it, which is the silent drop this sweep exists to
# remove.
#
# THE ASSIGNMENT CARRIES ITS OWN BRIEF (crit:d1c12adefee0). Routing a worker to a
# rejected criterion and telling them to go find out why is a handoff with the
# expensive half missing: the judge's reason lives on the DELIVERING BEAD as a
# `judgment_fail` handoff (AttachJudgmentFailGuidance writes the rationale into
# its broken_or_unverified), which the worker only sees once they have claimed
# and re-opened the right bead — i.e. after they have already committed to the
# repair. So the sweep reads it HERE and puts it in the message, together with
# what the judge reviewed when they refused it.
#
# THE BRIEF NEVER GATES THE ROUTING. Every read behind it fails open to an empty
# string, and an assignment whose brief could not be assembled still goes out
# saying so, naming where to look. A sweep that withheld a repair because an
# audit read 404'd would convert a degraded brief into the exact silent stall
# this order removes — and the brief is an enrichment of the assignment, never a
# precondition for it.
#
# ROUTING IS NOT DELIVERY (crit:77cdace10626). A nudge that exits 0 proves the
# session accepted a message, not that any worker acted on it: a brakeman that is
# wedged, mid-compaction, or simply not reading its inbox absorbs the assignment
# and never takes the claim. So the sweep VERIFIES consumption instead of
# assuming it, and consumption is RECORDED rather than inferred — the cycle that
# observes a live claim stamps its marker `consumed`.
#
# Inferring it afterwards is not possible: once the window closes, "the worker
# never claimed" and "the worker claimed, repaired it and released" are the same
# read — no live claim — and the criteria endpoint exposes LIVE claims only, so
# nothing on it remembers a lease that has already ended.
#
# An assignment whose window closes with no stamp was never consumed. It is
# routed again AND mailed. Re-routing alone is not enough: the same dead worker
# absorbs a fresh assignment every cycle, forever, and every one of those cycles
# exits 0 having "routed" one — a criterion refused by a judge, with nobody on
# it, and no signal anywhere. That is the silent drop this criterion names.
#
# A LAPSED STAKE RETURNS TO THE QUEUE EXACTLY ONCE (crit:f6de67fd022f). A worker
# that took the repair and then died leaves a lease that expires, and the server's
# reclaim sweep frees it. To this sweep that reads as: no live claim, criterion
# still `outstanding`, and an assignment marker on disk. The same read describes
# three other states, and each wants a different answer:
#
#   * the worker DELIVERED the repair (bead closed, or a completion on the feed)
#     and the criterion is waiting on a judge — route NOBODY, the judging lane
#     owns it now; a repair re-routed here is the "multiplies" fault, one fresh
#     worker per TTL on work that is already done;
#   * the worker's stake LAPSED or was RELEASED without a delivery — route it
#     again NOW, once, and say so: waiting out the assignment window strands a
#     repair nobody holds, and a second route on the next cycle would be the
#     duplicate the fresh marker exists to suppress;
#   * the worker never claimed at all — the consumption path above, unchanged.
#
# The discriminator is the assignment's OWN history, read two ways. The
# `consumed` stamp proves a lease was seen live. For a stake that began and
# ended entirely between two cycles — the common shape of a quick death — the
# project event feed is the durable record: the marker carries the feed head at
# routing time, and the reclaim/complete/release events since it name the
# criterion (`criterion.*`, by prd + label) or its pool bead (`bead.*`, by the
# deterministic bead id). An unreadable feed degrades to the stamp alone, and
# the stamp's absence degrades to the consumption path — every fallback lands
# on "route it, once" or "alarm", never on "leave it".
#
# A DELIVERED repair's marker is kept and stamped `delivered` so the judge's
# turn is not re-routed, and it is retired the moment the rollup carries a NEWER
# `fail` than the one that routed it — a second rejection is a new repair, and
# the fresh marker it earns starts the lifecycle over.
set -u

. "$(dirname "$0")/../lib/roster.sh"
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


# The pool a repair is routed to. A rig's worker pool is
# `<rig>/switchyard-ops.brakeman` — the same suffix pool-spawn staffs, because a
# repair is ordinary pool work with a known target, not a new kind of worker.
#
# ...unless the rig opted into the DEDICATED repair lane via roster.conf's
# REWORK_RIGS. A brakeman's prompt is written for building new work; a repair
# is the opposite job — the rejection must be read FIRST and the prior
# delivery is the starting point. agents/rework carries that prompt. For an
# opted-in rig the assignment goes to `<rig>/switchyard-ops.rework` instead,
# and when no rework session is live this sweep STARTS one and routes on the
# NEXT cycle (the conductor's spawn-then-dispatch ordering — a nudge into a
# still-booting pane is lost, and the assignment marker would then suppress
# the retry for a full TTL).
POOL_SUFFIX=".brakeman"
REWORK_RIGS="${REWORK_RIGS:-}"

# How long a routed assignment stays LIVE, in seconds. Defaults to one order
# interval: an assignment that has not become a held claim within its own cycle
# has not been consumed, and the next cycle is free to route it again.
REPAIR_ASSIGNMENT_TTL="${REPAIR_ASSIGNMENT_TTL:-3600}"

command -v jq >/dev/null 2>&1 || exit 0

token="$(sy_api_token)"
[ -n "$token" ] || exit 0
projects="$(sy_api_projects "$token")"
[ -n "$projects" ] || exit 0

# The RIGS to sweep, not the agents. sy_roster emits QUALIFIED AGENT NAMES
# (`rigA/switchyard-ops.brakeman`, optionally with a `:tmux-prefix` suffix), and
# what this sweep needs is the rig segment: sy_project_for_rig matches a rig name
# against a project SLUG, so passing a qualified name would match no project on
# any city and the sweep would route nothing, everywhere, in silence.
#
# Entries with no `/` are city-scoped and name no rig, so they are dropped rather
# than passed through as a rig that cannot exist.
#
# A city with no rigs is a legitimate state, not a fault. Say nothing.
rigs="$(sy_roster | sed 's/:.*$//' | grep '/' | sed 's#/.*##' | sort -u | awk 'NF')"
[ -n "$rigs" ] || exit 0

markers="$(sy_state_dir)/repair-assignments"
mkdir -p "$markers" 2>/dev/null || exit 0

now="$(date -u +%s)"
routed=0
failed=""
dropped=""
TAB="$(printf '\t')"

# prev_day DATE — the calendar day before DATE (YYYY-MM-DD), or empty.
#
# GNU and BSD `date` disagree on relative arithmetic and neither accepts the
# other's spelling, so both are tried and an unparseable answer is empty rather
# than wrong. Empty is safe here: it costs the boundary read below, not
# correctness of the reads that did work. An empty argument returns empty rather
# than falling through to GNU's "now minus a day", which would answer a question
# about the host clock that nobody asked.
prev_day() {
  [ -n "${1:-}" ] || return 0
  date -u -d "$1 -1 day" +%Y-%m-%d 2>/dev/null && return 0
  date -u -j -f %Y-%m-%d -v-1d "$1" +%Y-%m-%d 2>/dev/null && return 0
  return 0
}

# fails ROLLUP_JSON — the rejections in one day's rollup, as `prd_id<TAB>label`.
#
# `.retro.validations` is the ONLY exposed read carrying a verdict discriminator
# (internal/db/daily_report.go: "Verdict ("done" | "fail") distinguishes the
# two"), so it is what "a real rejection" is read from. An empty or malformed
# body yields nothing, which fails open exactly like every other read here.
fails() {
  printf '%s' "$1" | jq -r '
      (.retro.validations // [])[]
      | select((.verdict // "") == "fail")
      | select((.crit_label // "") != "" and ((.prd_id // 0) > 0))
      | "\(.prd_id)\t\(.crit_label)"' 2>/dev/null
}

# marker_consumed FILE — was the assignment in FILE ever seen as a held lease?
#
# The stamp is a LINE, appended, never a rewrite of line 1. Line 1 carries the
# routing timestamp the liveness window is measured from, and it is read by a
# fixed `NR==1` parse, so appending leaves the window arithmetic — and any marker
# written by a sweep that predates this check — parsing exactly as before. An
# older marker simply carries no stamp, which reads as "not yet observed
# consumed": that can cost one extra alarm, never a suppressed one.
marker_consumed() { marker_stamped "$1" consumed; }

# marker_stamped FILE WORD — does the marker carry a WORD stamp on any line
# after the first? The stamp vocabulary is `consumed` (a lease was seen live)
# and `delivered` (the repair landed and awaits a judge); both are appended,
# never rewritten, for the reason marker_consumed's header gives.
marker_stamped() {
  [ -f "$1" ] || return 1
  awk -v w="$2" 'NR>1 && $1 == w { found = 1 } END { exit !found }' "$1" 2>/dev/null
}

# marker_field FILE N — field N of the marker's routing line, or empty. Line 1
# is `<routed-at> <target> [<feed-head>] [<verdict-at>]`: the two optional
# trailing fields were added for the lapsed-stake check and are absent from
# markers written before it, which read as `-` (unknown) here rather than as an
# error, so an older marker keeps its full pre-existing lifecycle.
marker_field() {
  [ -f "$1" ] || return 0
  awk -v n="$2" 'NR==1 { print $n }' "$1" 2>/dev/null
}

# mark_consumed FILE — record that this assignment became a held lease.
#
# Idempotent: a repair held across several cycles is stamped once, so the marker
# cannot grow without bound while a long repair runs.
mark_consumed() {
  marker_consumed "$1" && return 0
  printf 'consumed %s\n' "$now" >>"$1" 2>/dev/null || true
}

# mark_delivered FILE — record that this assignment's repair was delivered and
# is now the judging lane's to act on. Idempotent like mark_consumed.
mark_delivered() {
  marker_stamped "$1" delivered && return 0
  printf 'delivered %s\n' "$now" >>"$1" 2>/dev/null || true
}

# stake_ended PROJECT TOKEN PRD LABEL SINCE — how this criterion's most recent
# stake ended, according to the project event feed since event id SINCE:
# `lapsed` (the lease expired and the reclaim sweep freed it), `delivered` (the
# holder completed) or `released` (the holder gave it back), else empty.
#
# Two event families name a criterion's stake, and both are matched because a
# repair reaches the worker down either lane: the criterion-claim API writes
# `criterion.{reclaimed,completed,released}` scoped to the PRD with the label in
# its detail, and the pool writes `bead.{reclaimed,closed,released}` keyed on the
# criterion's deterministic pool bead id (PoolBeadID: prd-{prd}-{hash}). The
# detail match is anchored on a trailing space so `crit:aaa` cannot match
# `crit:aaab`.
#
# The NEWEST matching event wins: a stake that was reclaimed and then re-taken
# and completed reads `delivered`, which is the state the criterion is actually
# in. Pages the feed in the server's batch size, bounded so a runaway feed cannot
# hold the cycle; a page that fails to read ends the scan with what was seen so
# far, and an unknown SINCE (`-`, or empty) answers nothing at all — the caller
# then falls back to the `consumed` stamp, which fails toward re-routing.
#
# `_se_`-prefixed locals: this runs inside the routing loop, and POSIX sh has no
# `local`.
stake_ended() {
  _se_since="$5"
  case "${_se_since:-}" in '' | '-' | *[!0-9]*) return 0 ;; esac
  _se_bead="prd-$3-$(printf '%s' "$4" | sed 's/^crit://')"
  _se_verdict=""
  _se_pages=0
  while [ "$_se_pages" -lt 5 ]; do
    _se_pages=$((_se_pages + 1))
    _se_page="$(sy_api_get "/api/v1/projects/$1/events?since_id=$_se_since" "$2")"
    [ -n "$_se_page" ] || break
    _se_hit="$(printf '%s' "$_se_page" | jq -r --arg p "$3" --arg l "$4" --arg b "$_se_bead" '
        [ (.events // [])[]
          | select(((.bead_id // "") == $b)
                   or ((((.prd_id // 0) | tostring) == $p)
                       and (((.detail // "") + " ") | contains("criterion " + $l + " "))))
          | select(.type == "criterion.reclaimed" or .type == "bead.reclaimed"
                   or .type == "criterion.completed" or .type == "bead.closed"
                   or .type == "criterion.released" or .type == "bead.released") ]
        | sort_by(.id) | last
        | if . == null then empty
          elif (.type | endswith(".reclaimed")) then "lapsed"
          elif (.type | endswith(".released")) then "released"
          else "delivered" end' 2>/dev/null | head -n1)"
    [ -n "$_se_hit" ] && _se_verdict="$_se_hit"
    _se_n="$(printf '%s' "$_se_page" | jq -r '(.events // []) | length' 2>/dev/null)"
    _se_last="$(printf '%s' "$_se_page" | jq -r '(.events // []) | last | .id // empty' 2>/dev/null)"
    case "${_se_n:-}" in '' | *[!0-9]*) break ;; esac
    case "${_se_last:-}" in '' | *[!0-9]*) break ;; esac
    [ "$_se_n" -ge 200 ] || break
    [ "$_se_last" -gt "$_se_since" ] || break
    _se_since="$_se_last"
  done
  [ -n "$_se_verdict" ] && printf '%s\n' "$_se_verdict"
  return 0
}

# verdict_for ROLLUPS PRD LABEL — the NEWEST recorded `fail` for that PRD and
# label across the day rollups already read this cycle, as
# `validator<TAB>evidence_ref<TAB>validated_at<TAB>provenance`. Empty when the
# criterion carries no fail, which fails open like every other read here.
#
# KEYED ON THE PAIR, AND ON BOTH HALVES. A single cycle routinely refuses more
# than one criterion, and an UNKEYED pick hands every brief the newest verdict in
# the rollup — attributing one judge's rejection to another criterion. That is
# not an incomplete brief but a false one, stating a checkable-looking fact that
# is wrong, which is the failure the whole assembly exists to avoid. The PRD is
# the other half of the key because `crit_label` hashes the criterion TEXT: two
# PRDs in one project sharing a boilerplate acceptance line share a label, and
# this rollup is project-wide, so the label alone is not unique in it. The
# routing loop already holds the authoritative PRD, so narrowing costs nothing.
# Compared as a STRING (`tostring`, never `--argjson`) so a rollup encoding
# prd_id either way still matches, and a malformed value degrades this one brief
# instead of erroring jq out of it.
#
# A LOOKUP, NOT A WIDER `fails()` RECORD — and that is load-bearing rather than
# stylistic. The routing set is deduped with `sort -u` over `prd<TAB>label`, so
# adding per-verdict columns to what `fails()` emits would make a criterion
# rejected TWICE (or rejected on both days this sweep reads) two distinct lines,
# and the sibling guarantee this order already ships — exactly one assignment per
# rejected criterion, crit:b6ea44d544e6 — would break silently in the one case it
# exists for. Keeping the brief out of the dedup key means the two cannot
# interact at all.
#
# Read from the rollups ALREADY IN HAND, never re-fetched: they are the very
# documents the rejection was noticed in, so the brief cannot end up describing a
# different verdict than the one that routed the assignment. Slurped (`-s`)
# because the two days arrive as two separate JSON documents; `last` after
# sort_by picks the newest when a criterion was refused more than once.
verdict_for() {
  printf '%s' "$1" | jq -rs --arg p "$2" --arg l "$3" '
      [ .[]
        | (.retro.validations // [])[]
        | select((.verdict // "") == "fail")
        | select((.crit_label // "") == $l)
        | select(((.prd_id // 0) | tostring) == $p) ]
      | sort_by(.validated_at // "")
      | last
      | if . == null then empty
        else [ (.validator // ""), (.evidence_ref // ""),
               (.validated_at // ""), (.verdict_provenance // "") ] | @tsv
        end' 2>/dev/null | head -n1
}

# repair_brief PROJECT TOKEN PRD LABEL ROLLUPS — the assignment's brief: WHY this
# criterion was refused, and WHAT the judge was looking at when they refused it.
# Always prints something; an unreadable source degrades to a line saying so.
#
# THE RATIONALE IS NOT ON ANY CRITERION READ. `prd_criterion_validations` stores
# it, but neither the rollup (DailyReportValidation) nor `/criteria` exposes that
# column — the only read that surfaces it is the delivering bead's handoff chain,
# where AttachJudgmentFailGuidance mirrors it into `broken_or_unverified` on a
# `judgment_fail` row. Hence the delivery-evidence audit read, which also carries
# the rest of the prior delivery's grounds (its PRs and its verification run) in
# the same response, so the brief costs ONE call.
#
# THE BEAD ID IS DERIVED, NOT DISCOVERED. A criterion's pool bead is
# deterministically `prd-{prd}-{hash}` (internal/prddispatch/pool_enqueue.go's
# poolBeadID, documented deterministic so a criterion always maps to the same
# primary key). `satisfying_bead_id` on /criteria is NOT the handle to use: it is
# populated only by an explicit link_bead_to_criterion and is empty for the
# ordinary pool bead. A criterion delivered through the RIG lane carries an `sw-`
# id this derivation cannot produce — that read simply 404s and the brief
# degrades, which is why the reason is reported as unavailable rather than
# assumed absent.
#
# Every local is `_rb_`-prefixed: POSIX sh has no `local`, this runs INSIDE the
# routing loop, and a bare `prd`/`label`/`target` here would overwrite the loop's
# own and route the wrong criterion.
repair_brief() {
  _rb_project="$1"
  _rb_token="$2"
  _rb_prd="$3"
  _rb_label="$4"
  _rb_validator=""
  _rb_ref=""
  _rb_at=""
  _rb_prov=""

  _rb_line="$(verdict_for "$5" "$_rb_prd" "$_rb_label")"
  if [ -n "$_rb_line" ]; then
    _rb_validator="$(printf '%s\n' "$_rb_line" | cut -f1)"
    _rb_ref="$(printf '%s\n' "$_rb_line" | cut -f2)"
    _rb_at="$(printf '%s\n' "$_rb_line" | cut -f3)"
    _rb_prov="$(printf '%s\n' "$_rb_line" | cut -f4)"
  fi

  _rb_bead="prd-$_rb_prd-$(printf '%s' "$_rb_label" | sed 's/^crit://')"
  _rb_ev="$(sy_api_get "/api/v1/projects/$_rb_project/beads/$_rb_bead/delivery-evidence" "$_rb_token")"
  _rb_reason=""
  _rb_prs=""
  _rb_verify=""
  if [ -n "$_rb_ev" ]; then
    # Newest first (bead_handoffs is ordered created_at DESC), so `.[0]` is the
    # rejection that routed THIS assignment rather than a superseded one. Rows
    # with an empty account are dropped before the pick: a bare marker would
    # otherwise shadow the real rationale behind it.
    _rb_reason="$(printf '%s' "$_rb_ev" | jq -r '
        [ (.handoffs // [])[]
          | select((.action // "") == "judgment_fail")
          | select((.broken_or_unverified // "") != "") ]
        | .[0].broken_or_unverified // empty' 2>/dev/null)"
    _rb_prs="$(printf '%s' "$_rb_ev" | jq -r '
        [ (.prd_prs // [])[] | (.url // "") | select(. != "") ]
        | .[0:5] | join(", ")' 2>/dev/null)"
    _rb_verify="$(printf '%s' "$_rb_ev" | jq -r '
        if (.verification // null) == null then empty
        else "\(.verification.command // "?") (exit \(.verification.exit_code))"
        end' 2>/dev/null)"
  fi

  if [ -n "$_rb_reason" ]; then
    printf 'WHY IT WAS REJECTED\n%s\n' "$_rb_reason"
  else
    printf 'WHY IT WAS REJECTED\n(the rejecting handoff could not be read from %s — read the verdict with\nget_prd / list_criteria before you change anything, and do NOT assume the prior\ndelivery was merely unfinished.)\n' "$_rb_bead"
  fi

  [ -n "$_rb_validator" ] && printf '\nRejected by: %s%s%s\n' \
    "$_rb_validator" "${_rb_at:+ at $_rb_at}" "${_rb_prov:+ (verdict: $_rb_prov)}"
  [ -n "$_rb_ref" ] && printf 'Reviewed: %s\n' "$_rb_ref"
  [ -n "$_rb_prs" ] && printf 'Prior delivery PRs: %s\n' "$_rb_prs"
  [ -n "$_rb_verify" ] && printf 'Prior verification run: %s\n' "$_rb_verify"
  return 0
}

for rig in $rigs; do
  project="$(sy_project_for_rig "$rig" "$projects")"
  [ -n "$project" ] || continue

  today="$(sy_api_get "/api/v1/projects/$project/daily-report-draft" "$token")"
  [ -n "$today" ] || continue

  # TODAY AND THE DAY BEFORE IT. The rollup buckets one PROJECT-LOCAL calendar
  # day, so a rejection recorded at 23:50 leaves today's window the moment
  # midnight rolls over — a sweep reading only "today" would drop every late
  # rejection on the floor and never route it. The previous day is anchored on
  # the rollup's OWN `.date`, which is the project's local day, rather than on
  # the host's UTC clock, so a city in a different zone than its project still
  # reads the two days that actually adjoin.
  rejections="$(fails "$today")"
  # The same documents are kept whole for the brief, so what an assignment says
  # about a verdict comes from the read that noticed it (see verdict_for).
  rollups="$today"
  yday="$(prev_day "$(printf '%s' "$today" | jq -r '.date // empty' 2>/dev/null)")"
  if [ -n "$yday" ]; then
    prev="$(sy_api_get "/api/v1/projects/$project/daily-report-draft?date=$yday" "$token")"
    [ -n "$prev" ] && rejections="$rejections
$(fails "$prev")" && rollups="$rollups
$prev"
  fi
  rejections="$(printf '%s\n' "$rejections" | awk 'NF' | sort -u)"
  [ -n "$rejections" ] || continue

  # The criterion read is fetched ONCE per rig and reused for every rejection in
  # it: it is a network call, and re-reading it per criterion would also let a
  # mid-cycle blip answer differently for two criteria in the same sweep.
  criteria="$(sy_api_get "/api/v1/projects/$project/criteria" "$token")"

  # The project feed's head, read ONCE per rig and recorded on every marker this
  # cycle writes, so a later cycle can ask the feed what happened to that
  # assignment (see stake_ended). A single event with the head is the cheapest
  # read the cursor endpoint offers. Unknown reads as `-`, never as 0: a marker
  # anchored at 0 would replay the project's whole history on every check.
  feed_head="$(sy_api_get "/api/v1/projects/$project/events?since_id=0&limit=1" "$token" \
    | jq -r '.head_id // empty' 2>/dev/null | head -n1)"
  case "${feed_head:-}" in '' | *[!0-9]*) feed_head="-" ;; esac

  # Dedicated rework lane for opted-in rigs; the shared brakeman pool for the
  # rest. See the REWORK_RIGS note beside POOL_SUFFIX above.
  worker_suffix="$POOL_SUFFIX"
  case " $REWORK_RIGS " in
    *" $rig "*) worker_suffix=".rework" ;;
  esac

  target=""
  target_known=1
  if ! target="$(sy_live_session_for "$rig/$SY_NS$worker_suffix")"; then
    target=""
    target_known=0
  fi

  # Rework-lane revival state, decided LAZILY inside the loop — only when a
  # rejection actually survives the consumption/settled guards and needs a
  # route. Deciding it here, on the raw 2-day rollup, spawned a session for
  # rigs whose every rejection was already repaired (the rollup replays a
  # settled fail for up to 48h), which then idled 30m and died, every cycle.
  #   rework_attempted: revival tried this cycle (try once per cycle, not per
  #                     rejection).
  #   rework_warming:   a wake/spawn SUCCEEDED, so this cycle's unrouted
  #                     rejections are the lane warming up — route next cycle,
  #                     no alarm. A FAILED revival leaves this 0 and the
  #                     rejection falls through to the no-live-worker
  #                     accumulation below, so a rig whose rework agent is
  #                     missing or suspended mails the mayor within one cycle
  #                     (the silent-failure invariant) instead of spinning a
  #                     doomed spawn forever.
  #   rework_capped:    the balancer published a rework target of 0 for this
  #                     rig, so the revival was DECLINED rather than attempted.
  #                     Tracked separately from rework_warming because the two
  #                     mean opposite things to the mail below: warming says a
  #                     worker is on its way, capped says one deliberately is
  #                     not. It must suppress the no-live-worker accumulation
  #                     all the same — a throttled lane is a decision, not a
  #                     broken registration, and reporting it as one would mail
  #                     the mayor "fix that registration" every cycle about a
  #                     rig where nothing is wrong.
  rework_attempted=0
  rework_warming=0
  rework_capped=0

  # A HERE-DOC, NOT A PIPE. `printf ... | while read` runs the loop body in a
  # SUBSHELL, so every `routed`/`failed` this loop records would be discarded at
  # the `done` — the failure mail below would then be unreachable and a sweep
  # that routed nothing would exit 0 in silence, which is the exact failure mode
  # the silent-failure invariant exists to prevent.
  while IFS="$TAB" read -r prd label; do
    [ -n "${prd:-}" ] && [ -n "${label:-}" ] || continue
    key="prd$prd-$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '-')"
    marker="$markers/$key"

    # Reset per rejection, never per rig: a criterion inheriting the previous
    # one's verdict would report a drop against whichever criterion happened to
    # be read next.
    cstatus=""
    bead_closed=""
    unconsumed=0
    ended=""
    prev_target=""

    # GUARD 1 — a live claim. The criteria read surfaces a claim only while its
    # lease is unexpired ("Only LIVE claims appear"), so a non-empty claimed_by
    # IS a worker holding this criterion right now. Routing a second one would
    # put two workers on one repair.
    #
    # An UNREADABLE criteria body skips the guard rather than the criterion:
    # this whole path fails open, and withholding a repair on a bad read is the
    # stall the sweep exists to remove.
    #
    # NARROWED ON (prd, label), NOT THE LABEL ALONE, for the same reason
    # verdict_for is: crit_label hashes the criterion TEXT, and this read is
    # project-wide, so two PRDs sharing a boilerplate acceptance line share a
    # label. Matching on the label alone let a live claim on ONE PRD's criterion
    # make a different PRD's rejected criterion read as held — its repair never
    # routed, and silently, because the criterion is skipped before the `failed`
    # accumulation below. api_v1_criteria.go says it outright: uniqueness is
    # (prd_id, crit_label), never crit_label alone.
    if [ -n "$criteria" ]; then
      held="$(printf '%s' "$criteria" | jq -r --arg l "$label" --arg p "$prd" '
          (.criteria // [])
          | map(select((.crit_label // "") == $l)
                | select(((.prd_id // 0) | tostring) == $p))
          | .[0].claimed_by // empty' 2>/dev/null | awk 'NF' | head -n1)"
      if [ -n "$held" ]; then
        # THIS IS THE ONLY MOMENT CONSUMPTION IS OBSERVABLE. A lease shows up on
        # the criteria read only while it is live, so a cycle that sees one and
        # does not record it cannot recover the fact afterwards. Stamping here is
        # what lets the expiry check below tell a worker that ignored its
        # assignment from one that took it, repaired it and released.
        [ -f "$marker" ] && mark_consumed "$marker"
        continue
      fi
      # Consumption is also PROVEN by the criterion having moved on: a repair
      # that reached a `done` verdict was plainly performed, whether or not any
      # cycle happened to catch its lease in flight.
      #
      # Narrowed on (prd, label) for the same reason the claim read above is:
      # crit_label hashes the criterion TEXT, so two PRDs sharing a boilerplate
      # acceptance line share a label, and matching on the label alone would let
      # one PRD's settled criterion silence another PRD's live rejection.
      cstatus="$(printf '%s' "$criteria" | jq -r --arg l "$label" --arg p "$prd" '
          (.criteria // [])
          | map(select((.crit_label // "") == $l)
                | select(((.prd_id // 0) | tostring) == $p))
          | .[0].status // empty' 2>/dev/null | awk 'NF' | head -n1)"
      # The delivery leg the criteria read exposes. A rejection re-opens the
      # criterion's bead (crit:123a5d5345fb), so a CLOSED bead with no live claim
      # on a criterion we routed is the repair worker's completion — the judging
      # lane's turn, not this one's.
      bead_closed="$(printf '%s' "$criteria" | jq -r --arg l "$label" --arg p "$prd" '
          (.criteria // [])
          | map(select((.crit_label // "") == $l)
                | select(((.prd_id // 0) | tostring) == $p))
          | .[0].bead_closed // false | tostring' 2>/dev/null | awk 'NF' | head -n1)"
    fi

    # THE REPAIR IS SETTLED. A criterion that reached `done` was repaired and
    # re-judged; the `fail` that put it in this cycle's rollup is history. The
    # rollup buckets a whole calendar day and is read for two days, so that
    # stale verdict keeps reappearing for as long as 48 hours after the repair
    # landed — and every one of those cycles would otherwise fall through to the
    # nudge below and route a SECOND assignment for work already accepted.
    #
    # Its marker goes with it: leaving one behind means the next rejection of
    # this same criterion reads as an assignment already live and is suppressed
    # for a whole TTL. Checked BEFORE the unconsumed accounting so a settled
    # repair is never reported as dropped either.
    if [ "$cstatus" = "done" ]; then
      rm -f "$marker" 2>/dev/null || true
      continue
    fi

    # The verdict this cycle is acting on, by its timestamp. Recorded on the
    # marker so a later cycle can tell "the same rejection, still in flight"
    # from "rejected AGAIN after the repair landed" by string equality alone —
    # no date arithmetic, no host clock. Empty (a rollup row without one) is
    # recorded as `-` and never compared.
    verdict_at="$(verdict_for "$rollups" "$prd" "$label" | cut -f3)"

    # A SECOND REJECTION RETIRES A DELIVERED MARKER. Once the repair was
    # delivered, its marker is kept so the judge's turn is not re-routed (below).
    # That hold must end when the judge rules against it again: the rollup then
    # carries a `fail` NEWER than the one this marker was routed for, which is a
    # new repair and starts the lifecycle over with a fresh marker. Only a
    # `delivered` marker is retired this way — an assignment still in flight
    # keeps its window, so a replayed or re-judged verdict on an unchanged
    # delivery cannot put a second worker beside the first.
    if [ -f "$marker" ] && marker_stamped "$marker" delivered; then
      routed_for_verdict="$(marker_field "$marker" 4)"
      if [ -n "$verdict_at" ] && [ -n "$routed_for_verdict" ] &&
        [ "$routed_for_verdict" != "-" ] && [ "$routed_for_verdict" != "$verdict_at" ]; then
        echo "repair-sweep: $rig/$label was rejected again after its repair landed; routing it afresh"
        rm -f "$marker" 2>/dev/null || true
      fi
    fi

    # GUARD 2 — an assignment we already routed that has not aged out. Nothing
    # on the criterion can show this: a worker nudged one minute ago has not
    # claimed yet and reads exactly like a worker nobody has told.
    #
    # ...unless the assignment's first life has demonstrably ENDED, which the
    # header's lapsed-stake section spells out (crit:f6de67fd022f). We are past
    # guard 1, so no claim is live; the question is how the stake we routed
    # ended, and it is answered from the cheapest evidence first:
    #
    #   1. a `delivered` stamp, or a closed bead on the criteria read — the
    #      repair landed and the judging lane owns it: route nobody;
    #   2. the event feed since this marker's routing head — a reclaim is a
    #      lapse, a completion a delivery, a release a hand-back, whatever
    #      cycle did or did not happen to observe the lease;
    #   3. a `consumed` stamp with nothing on the feed — the lease WAS seen
    #      live and is gone with the criterion still open: a lapse, and the
    #      direction every fallback here takes is toward the queue, never
    #      away from it.
    #
    # A lapsed or released stake is re-routed NOW, inside the window: the
    # window measures a worker who has not claimed YET, and a stake that ended
    # is not that. It is re-routed ONCE because the route below writes a fresh
    # marker, and this same check finds nothing ended on the next cycle.
    if [ -f "$marker" ]; then
      if marker_stamped "$marker" delivered || [ "$bead_closed" = true ]; then
        ended=delivered
      else
        ended="$(stake_ended "$project" "$token" "$prd" "$label" "$(marker_field "$marker" 3)")"
        [ -n "$ended" ] || ! marker_consumed "$marker" || ended=lapsed
      fi
      case "$ended" in
      delivered)
        mark_delivered "$marker"
        continue
        ;;
      lapsed | released)
        prev_target="$(marker_field "$marker" 2)"
        echo "repair-sweep: $rig/$label stake $ended (held via ${prev_target:-unknown}); returning it to the repair queue once"
        ;;
      *)
        at="$(marker_field "$marker" 1)"
        case "${at:-}" in
        *[!0-9]* | "") at=0 ;;
        esac
        [ "$((now - at))" -lt "$REPAIR_ASSIGNMENT_TTL" ] && continue

        # THE WINDOW CLOSED. Falling through re-routes it either way — the
        # question this answers is whether the assignment was ever consumed,
        # and so whether its disappearance is worth waking a human over.
        # Reaching here means neither the feed nor a stamp showed the stake
        # ending, so the only way a lease existed is one no cycle saw AND the
        # feed did not record — reported rather than assumed.
        #
        # An UNREADABLE criteria body leaves cstatus empty and is counted as
        # unconsumed. That direction is deliberate: this whole check exists to
        # stop a rejection going quiet, so an unverifiable assignment is
        # reported rather than assumed fine. It costs a duplicate alarm at worst.
        case "$cstatus" in
        "" | outstanding)
          unconsumed=1
          prev_target="$(marker_field "$marker" 2)"
          dropped="$dropped $rig/$label(nudged:${prev_target:-unknown})"
          ;;
        esac
        ;;
      esac
    fi

    if [ "$target_known" -eq 0 ]; then
      failed="$failed $rig/$label(session-lookup-failed)"
      continue
    fi

    # Rework-lane revival (see the state block above the loop). Runs here — a
    # rejection that reached this point survived every guard, so the demand is
    # real. An ASLEEP session is revived with `gc session wake`, never a
    # second `gc session new`: the agent runs max_active_sessions = 1 and its
    # 30m idle_timeout makes asleep the COMMON state, so a spawn here would
    # bounce off the cap every cycle while the sweep read the lane as absent
    # (roster.sh's sy_session_alias_for header documents exactly this trap).
    # Either revival routes NEXT cycle — a nudge into a booting or waking pane
    # is lost, and the assignment marker would then suppress the retry for a
    # full TTL.
    #
    # THE BALANCER'S REWORK TARGET IS A CEILING ON THIS REVIVAL (switchyard PRD
    # #397). sy_balancer_capped applies the one rule every spawn site in this
    # pack shares — present, fresh and well-formed, min() never max(), and an
    # absent/stale/malformed/unreadable file answering "no target" so the lane
    # behaves byte-for-byte as it does today. It lives in roster.sh rather than
    # being re-derived here for the reason its own header gives: a rule
    # re-implemented per caller is the same rule only by coincidence.
    #
    # THE CEILING PASSED IS 1 BECAUSE THAT IS THIS REVIVAL'S WHOLE FAN-OUT.
    # rework_attempted holds it to one wake-or-spawn per rig per cycle, and the
    # agent runs max_active_sessions = 1, so min(1, target) can land only on 1
    # or 0. A target ABOVE 1 is therefore not authority to stack a second
    # session; zero is the only value that moves this lane. min() vs max() is
    # consequently unprovable from here — targets 1 and 9 are indistinguishable
    # at this call site — and is asserted where it is decidable, on
    # sy_balancer_capped itself.
    #
    # IT GATES THE REVIVAL, NEVER THE ROUTING. The nudge below is deliberately
    # left uncapped: a rig that already has a live rework worker still gets its
    # rejection routed, because a target of zero is an instruction not to ADD
    # capacity, not licence to leave a criterion a judge refused sitting unowned
    # in front of an idle worker. Capping the spawn starves a lane for a cycle;
    # capping the nudge is the silent drop this whole order exists to remove.
    #
    # BOTH REVIVAL PATHS ARE GATED, and wake is the one that matters. The
    # agent's 30m idle_timeout makes ASLEEP its common state, so a cap that
    # gated only `gc session new` would read as correct in every test and
    # essentially never fire in production.
    if [ "$worker_suffix" = ".rework" ] && [ -z "$target" ] && [ "$rework_attempted" -eq 0 ]; then
      rework_attempted=1
      if [ "$(sy_balancer_capped "$rig" rework 1)" = 0 ]; then
        rework_capped=1
        echo "repair-sweep: $rig rework lane is at the balancer's target of 0; not reviving it this cycle"
      else
        _rw_agent="$rig/$SY_NS.rework"
        _rw_any="$(sy_session_alias_for "$_rw_agent" "" 2>/dev/null)" || _rw_any=""
        if [ -n "$_rw_any" ]; then
          if gc session wake "$_rw_any" >/dev/null 2>&1; then
            rework_warming=1
            echo "repair-sweep: $rig rework session $_rw_any is asleep; woke it, routing next cycle"
          fi
        elif gc session new "$_rw_agent" --no-attach >/dev/null 2>&1; then
          rework_warming=1
          echo "repair-sweep: $rig has repair demand and no rework session; spawned one, routing next cycle"
        fi
      fi
    fi
    if [ -z "$target" ] && [ "$rework_warming" -eq 1 ]; then
      # The lane is warming — a wake/spawn just succeeded. Not a failure, not
      # routed: the next cycle (1h) finds it live and routes with the marker
      # ledger intact.
      continue
    fi
    if [ -z "$target" ] && [ "$rework_capped" -eq 1 ]; then
      # The lane is THROTTLED, not broken. Falling through to no-live-worker
      # would mail the mayor "check pool-spawn is running and the rig is not
      # suspended ... fix that registration" for a rig the balancer switched
      # off on purpose, every cycle for as long as the target holds — turning
      # the throttle into a standing false alarm and burying the real
      # no-live-worker reports underneath it.
      #
      # SEPARATE FROM THE WARMING CHECK ABOVE, not folded into it, because the
      # two are opposite claims about the next cycle: warming says a worker is
      # arriving, capped says none was asked for. Nothing is dropped either way
      # — the rejection keeps its place in the rollup and routes on whichever
      # cycle the lane is allowed capacity again.
      continue
    fi
    if [ -z "$target" ]; then
      failed="$failed $rig/$label(no-live-worker)"
      continue
    fi

    # THE REWORK SESSION MAY BE MID-PR-REWORK. pr-rework-sweep routes
    # review-rejected PRs to this same singleton session (max_active_sessions
    # = 1, wake_mode = fresh), and its assignment markers carry the target
    # alias in field 2 exactly like ours — so a fresh, undelivered marker
    # naming our target means a nudge now would drop that in-flight PR rework
    # on the floor while its marker still suppressed re-dispatch for the rest
    # of its TTL. This is the mirror image of pr-rework-sweep's own check of
    # OUR ledger; the two must stay paired, or the unchecked direction
    # silently drops work again. Waiting is not a failure: the repair routes
    # on a later cycle, which is the serialization the agent's pool ceiling
    # already chose. The TTL default must equal pr-rework-sweep's (it pairs
    # that value to the rework agent's max_session_age); a `delivered` stamp
    # (appended line — the PR rework pushed and the head moved) releases the
    # hold early, same as our own `consumed` stamp shape.
    if [ "$worker_suffix" = ".rework" ]; then
      _prw_ttl="${PR_REWORK_ASSIGNMENT_TTL:-14400}"
      _prw_busy=0
      for _prw_m in "$(sy_state_dir)/pr-rework-assignments"/*; do
        [ -f "$_prw_m" ] || continue
        awk 'NR>1 && $1 == "delivered" { found = 1 } END { exit !found }' "$_prw_m" 2>/dev/null && continue
        _prw_at="$(awk 'NR==1{print $1}' "$_prw_m" 2>/dev/null)"
        case "${_prw_at:-}" in '' | *[!0-9]*) continue ;; esac
        [ $((now - _prw_at)) -lt "$_prw_ttl" ] || continue
        if [ "$(awk 'NR==1{print $2}' "$_prw_m" 2>/dev/null)" = "$target" ]; then
          _prw_busy=1
          break
        fi
      done
      if [ "$_prw_busy" -eq 1 ]; then
        echo "repair-sweep: $rig rework session holds a live PR rework; waiting a cycle"
        continue
      fi
    fi

    # Assembled only for a criterion that IS being routed — after both guards, so
    # a suppressed rejection costs no extra call — and never allowed to fail the
    # dispatch: repair_brief always succeeds, degrading its content instead.
    brief="$(repair_brief "$project" "$token" "$prd" "$label" "$rollups")"

    # A RE-ROUTE SAYS SO. The retry is otherwise indistinguishable from a first
    # assignment, and a worker that cannot tell it is the second attempt has no
    # reason to report back rather than go quiet the same way.
    note=""
    if [ "$unconsumed" -eq 1 ]; then
      note="

This criterion was already routed once — to ${prev_target:-a worker that no longer
resolves} — and no claim was ever taken on it, so the assignment was dropped
rather than worked. You are the retry. If you cannot take this repair, say so
instead of leaving it: that silence is what cost this rejection a cycle."
    fi

    # A RETURN TO THE QUEUE SAYS SO TOO, and says something different: a prior
    # worker HELD this repair. Their partial work may already sit on a branch,
    # their handoff (if any) is on the bead, and a lease that lapsed mid-repair
    # usually means the worker died, not that the approach failed — none of
    # which a worker told only "repair this" would think to look for.
    case "$ended" in
    lapsed)
      note="$note

A worker already held this repair — via ${prev_target:-a session that no longer
resolves} — and its lease expired without a delivery, so the stake was reclaimed
and the repair has been returned to the queue once. You are its second holder.
Before you start, read the bead's handoffs and delivery evidence for anything
that worker left behind: a lapsed lease usually means the session died, not that
its approach was wrong, and partial work may already sit on a branch."
      ;;
    released)
      note="$note

A worker already held this repair — via ${prev_target:-a session that no longer
resolves} — and released it without a delivery, so it has been returned to the
queue once. You are its second holder. Their release handoff is on the bead:
read it before you start, so you build on what they learned rather than
repeating it."
      ;;
    esac

    if gc session nudge "$target" "REPAIR $label (PRD #$prd, project $project)

A judge recorded a \`fail\` on this criterion: it was delivered, reviewed, and
refused. It is repair work, not new work.

$brief
Take the criterion claim before you build — claim { kind: \"criterion\", prd_id:
$prd, crit_label: \"$label\", lane: \"pool\" } — so a second worker is not routed
onto the same repair. The rejection above is the brief: take a materially
different approach rather than re-submitting the prior delivery, and land the
repair as a pull request.$note" </dev/null >/dev/null 2>&1; then
      # Marker AFTER the nudge, never before: see the header. A failed dispatch
      # must leave nothing live so the next cycle retries it.
      #
      # A MARKER THAT DID NOT PERSIST IS A ROUTING FAILURE, not a detail to
      # swallow. The nudge has already gone out, so the work IS assigned — but
      # with nothing on disk recording it, GUARD 2 cannot suppress anything and
      # the next cycle routes a second worker onto the same repair, then a third.
      # Reporting it is the only way that duplication is ever visible; the old
      # `|| true` made an unwritable state directory look like a clean cycle.
      #
      # LINE 1 CARRIES FOUR FIELDS: the routing timestamp and target that every
      # older reader parses (`NR==1 {print $1}` / `$2`, here and in
      # pr-rework-sweep's mirror check), then the feed head at routing and the
      # timestamp of the verdict routed for — the two anchors the lapsed-stake
      # check reads back through marker_field. Unknown values are `-`.
      if printf '%s %s %s %s\n' "$now" "$target" "$feed_head" "${verdict_at:--}" >"$marker" 2>/dev/null; then
        routed=$((routed + 1))
      else
        failed="$failed $rig/$label(marker-write-failed)"
      fi
    else
      failed="$failed $rig/$label(nudge-failed)"
    fi
  done <<REJECTIONS
$rejections
REJECTIONS
done

# SILENT-FAILURE INVARIANT (same contract as intake-sweep, pool-spawn and
# lane-ensure): a rejection nobody was routed to is a criterion sitting refused
# with no worker on it and nobody watching — precisely the stall this order
# removes — so it becomes mail within the cycle. Routing every rejection is the
# quiet path.
if [ -n "$failed" ]; then
  gc mail send mayor \
    -s "repair-sweep: could not route $(printf '%s' "$failed" | wc -w | tr -d ' ') repair assignment(s)" \
    -m "repair-sweep read a recorded judgment \`fail\` for each of these criteria and could not put a worker on it:$failed

Routed $routed repair assignment(s) successfully this cycle.

session-lookup-failed means 'gc session list --json' could not be run or its output could not be parsed, so whether that rig has a live worker is UNKNOWN. Do not spawn on this one — check gc and jq first.
no-live-worker means the roster was read fine and that rig has no live worker session to route to (brakeman, or rework for a REWORK_RIGS rig): check pool-spawn is running and the rig is not suspended. For a REWORK_RIGS rig this also means the sweep's own wake/spawn of the rework agent FAILED — the agent is missing from the rig or suspended, or the city is at its session cap — so fix that registration rather than waiting on more cycles.
nudge-failed means the session alias resolved but gc session nudge returned non-zero.
marker-write-failed means the worker WAS nudged and the assignment could not be recorded, so nothing suppresses a duplicate: the next cycle will route a second worker onto the same repair until the state directory is writable again.

Until this clears, those criteria stay rejected with nobody repairing them." \
    >/dev/null 2>&1
fi

# AN IGNORED ASSIGNMENT IS ITS OWN ALARM, AND A SEPARATE ONE. The mail above
# reports a dispatch that could not be made; this reports a dispatch that was
# made and then absorbed — the nudge succeeded, and the worker never claimed.
# They are different faults with different fixes (find a worker vs. find out why
# the one we have is not working), so folding them into one subject would hide
# the second behind the first every time both fire.
#
# Without this, the re-route is silent by construction: a wedged brakeman can eat
# one assignment per cycle indefinitely while every cycle exits 0 reporting a
# successful route, which is precisely the drop this criterion forbids.
#
# THE ALARM MUST NOT OVERSTATE THE RETRY. A criterion is added to `dropped` when
# its window closes unconsumed, which is BEFORE the re-route is attempted — and
# that retry can still fail four ways (session lookup, no live worker, the nudge
# itself, the marker write). Claiming "each has been routed again" unconditionally
# would report the worst case — never consumed AND now unassigned — as if it were
# handled, which is the same false all-clear this check exists to remove, just
# moved one cycle later. So the retry is described conditionally and the reader is
# pointed at the companion mail, which names exactly those the retry could not reach.
if [ -n "$dropped" ]; then
  gc mail send mayor \
    -s "repair-sweep: $(printf '%s' "$dropped" | wc -w | tr -d ' ') repair assignment(s) were never consumed" \
    -m "repair-sweep routed a repair assignment for each of these criteria in an earlier cycle, the nudge succeeded, and no claim was ever taken on it. Each has been re-routed this cycle EXCEPT any also named in a 'repair-sweep: could not route' mail — for those the retry could not be dispatched either, and the criterion is now rejected with nobody on it:$dropped

The name after 'nudged:' is the session the dropped assignment went to; 'unknown' means the marker recorded no target.

A worker that is nudged and never claims is usually wedged, mid-compaction, or out of context — check it with 'gc session peek' before assuming the routing is at fault. If that session is dead, the retry has gone to whoever is live now.

This is not the same fault as 'could not route': there, no worker could be reached at all. Here one was reached and did not act. A criterion in BOTH mails has hit both faults in sequence and is the most urgent case in this report.

Routed $routed repair assignment(s) this cycle in total." \
    >/dev/null 2>&1
fi

exit 0
