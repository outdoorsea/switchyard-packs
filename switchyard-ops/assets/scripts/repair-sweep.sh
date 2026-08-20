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
marker_consumed() {
  [ -f "$1" ] || return 1
  awk 'NR>1 && $1 == "consumed" { found = 1 } END { exit !found }' "$1" 2>/dev/null
}

# mark_consumed FILE — record that this assignment became a held lease.
#
# Idempotent: a repair held across several cycles is stamped once, so the marker
# cannot grow without bound while a long repair runs.
mark_consumed() {
  marker_consumed "$1" && return 0
  printf 'consumed %s\n' "$now" >>"$1" 2>/dev/null || true
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
  rework_attempted=0
  rework_warming=0

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
    unconsumed=0
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

    # GUARD 2 — an assignment we already routed that has not aged out. Nothing
    # on the criterion can show this: a worker nudged one minute ago has not
    # claimed yet and reads exactly like a worker nobody has told.
    if [ -f "$marker" ]; then
      at="$(awk 'NR==1{print $1}' "$marker" 2>/dev/null)"
      case "${at:-}" in
      *[!0-9]* | "") at=0 ;;
      esac
      [ "$((now - at))" -lt "$REPAIR_ASSIGNMENT_TTL" ] && continue

      # THE WINDOW CLOSED. Falling through re-routes it either way — the
      # question this answers is whether the assignment was ever consumed, and
      # so whether its disappearance is worth waking a human over.
      #
      # A stamp means a worker did hold it; its lease ending afterwards is an
      # expired claim, which is a different fault with its own handling, so it
      # is re-routed quietly rather than reported as ignored.
      #
      # An UNREADABLE criteria body leaves cstatus empty and is counted as
      # unconsumed. That direction is deliberate: this whole check exists to
      # stop a rejection going quiet, so an unverifiable assignment is reported
      # rather than assumed fine. It costs a duplicate alarm at worst.
      if ! marker_consumed "$marker"; then
        case "$cstatus" in
        "" | outstanding)
          unconsumed=1
          prev_target="$(awk 'NR==1{print $2}' "$marker" 2>/dev/null)"
          dropped="$dropped $rig/$label(nudged:${prev_target:-unknown})"
          ;;
        esac
      fi
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
    if [ "$worker_suffix" = ".rework" ] && [ -z "$target" ] && [ "$rework_attempted" -eq 0 ]; then
      rework_attempted=1
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
    if [ -z "$target" ] && [ "$rework_warming" -eq 1 ]; then
      # The lane is warming — a wake/spawn just succeeded. Not a failure, not
      # routed: the next cycle (1h) finds it live and routes with the marker
      # ledger intact.
      continue
    fi
    if [ -z "$target" ]; then
      failed="$failed $rig/$label(no-live-worker)"
      continue
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
      if printf '%s %s\n' "$now" "$target" >"$marker" 2>/dev/null; then
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
