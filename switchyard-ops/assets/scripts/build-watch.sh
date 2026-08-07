#!/bin/sh
# build-watch: turn a wedged factory run into mayor mail (switchyard PRD #269).
#
# THE FAILURE
#
# `sy-build-from-prd` drains an approved PRD's pool beads through a convoy
# titled `prd-<id>-build`. The run is long — hours — and unsupervised: the
# convoy stays open because open is its normal state, the workers' sessions stay
# `active` because they are, `gc status` reads clean and every order keeps
# firing ok:true. A run that has STOPPED is therefore indistinguishable from a
# run that is still going, and stays that way until a human happens to look.
#
# THE SIGNAL: PROGRESS, NOT STATE
#
# No single-cycle read can tell those apart — "open with unfinished work" is
# what a healthy run looks like too. The only honest discriminator is the
# DERIVATIVE: has `progress.closed` advanced since last cycle? So this script
# keeps a small per-convoy ledger of (closed count, when that count was first
# seen) and judges the age of the current count, not the count itself.
#
# Thresholds (env-tunable via roster.conf):
#   BUILD_WATCH_STALL_MIN     minutes a factory run may sit at an unchanged
#                             closed-count before it is called wedged
#   BUILD_WATCH_FINALIZE_MIN  minutes a run whose work is ALL closed may sit
#                             with its convoy still open before it is called
#                             wedged in finalize
#
# DETECTOR ONLY. It never releases a lease, reopens a bead, closes a convoy or
# respawns a worker. All four are destructive on a run that is merely slow, and
# this script can tell slow from wedged with enough confidence to report, not to
# act. Recovery is a human's call. (events-rotate remains the pack's sole
# auto-actioner.)
#
# WHY AN UNREADABLE PROBE IS SILENT RATHER THAN ALARMING
#
# If `gc convoy list` cannot be read or parsed, this script knows nothing: it
# cannot tell "no factory runs" from "three wedged ones". It exits quiet. That
# is deliberate and it is the one place this detector accepts under-reporting —
# a 10-minute alarm that says only "I could not look" is noise a human cannot
# act on, and the fault it describes is gc's own health, which is loop-health's
# beat, not this order's. What this script must never do is turn an unknown into
# a confident wedge report, because the remedy for a wedge (go interrupt a live
# factory run) is expensive and wrong when the run was fine all along.
set -u

. "$(dirname "$0")/../lib/roster.sh"

sy_load_conf

STALL_MIN="${BUILD_WATCH_STALL_MIN:-45}"
FINALIZE_MIN="${BUILD_WATCH_FINALIZE_MIN:-20}"

LEDGER="$(sy_state_dir)/build-watch.progress"
SEEN="$(sy_state_dir)/build-watch.reported"
mkdir -p "$(sy_state_dir)" 2>/dev/null
[ -f "$LEDGER" ] || : >"$LEDGER"
[ -f "$SEEN" ] || : >"$SEEN"

NOW="$(date +%s)"
TAB="$(printf '\t')"

# A FACTORY RUN is an open convoy titled `prd-<id>-build` — the name
# `map-pool-to-convoy` mints (`gc convoy create "prd-{{prd_id}}-build"`). Match
# the title rather than a label or metadata key so this stays readable against
# the one artifact a human also sees in `gc convoy list`.
#
# Any other convoy in the city is somebody else's business and is not counted,
# not laddered and not reported.
raw="$(gc convoy list --json 2>/dev/null)" || exit 0
[ -n "$raw" ] || exit 0

runs="$(printf '%s\n' "$raw" | jq -r '
    (.convoys // [])[]
    | select((.title // "") | test("^prd-[0-9]+-build$"))
    | [ (.id // ""), (.title // ""), ((.progress.closed) // 0), ((.progress.total) // 0) ]
    | @tsv' 2>/dev/null)" || exit 0

# No factory runs at all: the "absent runs" case. Nothing to ladder, nothing to
# say. The ledger is truncated so a later run cannot inherit a stale age.
if [ -z "$runs" ]; then
  : >"$LEDGER"
  exit 0
fi

# build_wedged CLOSED TOTAL HELD IDLE AGE_S — rc 0 when this factory run is
# wedged, rc 1 when it is healthy. The single place the slow/wedged line is
# drawn; everything above it is observation and everything below it is
# reporting.
#
#   CLOSED  child beads finished
#   TOTAL   child beads in the convoy
#   HELD    OPEN children that carry an assignee (somebody is holding the work)
#   IDLE    OPEN children with no assignee   (ready work, nobody on it)
#   AGE_S   seconds since CLOSED last changed
build_wedged() {
  _closed="$1"; _total="$2"; _held="$3"; _idle="$4"; _age="$5"

  # FINALIZE WEDGE. Every child is closed but the convoy is still open, so the
  # run finished the work and never completed it back. Judged on its own,
  # shorter clock: there is no work left that could explain the delay, which is
  # what makes a short threshold safe here and unsafe above.
  if [ "$_total" -gt 0 ] && [ "$_closed" -ge "$_total" ]; then
    [ "$_age" -ge $((FINALIZE_MIN * 60)) ] && return 0
    return 1
  fi

  # DRAIN WEDGE. Work remains and the closed-count has not moved for
  # STALL_MIN. Reported whether or not a worker is holding it: a session that
  # holds a lease and does nothing is the exact failure this order exists to
  # catch, and it is invisible to every other surface — the convoy is open, the
  # session is active, the lease keeps renewing.
  [ "$_age" -ge $((STALL_MIN * 60)) ] && return 0
  return 1
}

fresh=""
wedged=""

# A here-doc, NOT a pipe: `while read` on the right of a pipe runs in a subshell
# in POSIX sh, and every variable accumulated in the loop would be discarded at
# the closing `done` — the loop would run correctly and report nothing.
while IFS="$TAB" read -r id title closed total; do
  [ -n "$id" ] || continue

  # Age of the CURRENT closed-count. A ledger row matches only when the count is
  # unchanged, so any advance re-stamps the row to now and the clock restarts —
  # which is what makes "progress" and not "elapsed time" the thing measured.
  since="$(awk -F"$TAB" -v k="$id" -v c="$closed" \
             '$1 == k && $2 == c { print $4; exit }' "$LEDGER" 2>/dev/null)"
  case "$since" in
    ''|*[!0-9]*) since="$NOW" ;;
  esac
  fresh="$fresh$id$TAB$closed$TAB$total$TAB$since
"
  age=$((NOW - since))
  [ "$age" -ge 0 ] || age=0

  # Per-convoy census of who is on the remaining work. Unreadable is treated as
  # zero of each, which reaches build_wedged as "nobody holding, nothing idle" —
  # it can weaken the report's detail but never manufactures a wedge on its own,
  # because the age clock is what decides.
  held=0
  idle=0
  cstat="$(gc convoy status "$id" --json 2>/dev/null)" || cstat=""
  if [ -n "$cstat" ]; then
    counts="$(printf '%s\n' "$cstat" | jq -r '
        [ (.children // [])[] | select((.status // "") != "closed") ] as $open
        | [ ($open | map(select((.assignee // "") != "")) | length),
            ($open | map(select((.assignee // "") == "")) | length) ]
        | @tsv' 2>/dev/null)" || counts=""
    if [ -n "$counts" ]; then
      # `cut -f` splits on tab by default. Preferred over a `${var%%...}` pattern
      # carrying a quoted "$TAB": quoting inside a parameter-expansion pattern is
      # POSIX but unevenly implemented, and getting it wrong yields the WHOLE
      # string in both fields rather than an error.
      held="$(printf '%s' "$counts" | cut -f1)"
      idle="$(printf '%s' "$counts" | cut -f2)"
      case "$held" in ''|*[!0-9]*) held=0 ;; esac
      case "$idle" in ''|*[!0-9]*) idle=0 ;; esac
    fi
  fi

  build_wedged "$closed" "$total" "$held" "$idle" "$age" || continue

  # Report each distinct stall EPISODE once. The key carries the closed-count,
  # so a run that advances and then wedges again is a new episode and mails
  # again, while a run sitting at the same count stays quiet after the first
  # notice. This is what lets the order run every 10m without nagging.
  key="$id:$closed/$total"
  grep -qxF "$key" "$SEEN" 2>/dev/null && continue
  printf '%s\n' "$key" >>"$SEEN"

  mins=$((age / 60))
  if [ "$total" -gt 0 ] && [ "$closed" -ge "$total" ]; then
    detail="all $total item(s) closed, convoy still open — finalize never ran"
  else
    detail="$closed/$total closed, no progress for ${mins}m; $held held, $idle unclaimed"
  fi
  wedged="$wedged
- $title ($id): $detail"
done <<EOF
$runs
EOF

# Rewrite the ledger to CURRENT runs only. A finished run's row must not
# survive, or the next run of the same PRD inherits its age and is called wedged
# on its first cycle.
printf '%s' "$fresh" >"$LEDGER"

[ -n "$wedged" ] || exit 0

gc mail send mayor \
  -s "build-watch: factory run wedged" \
  -m "These switchyard-build factory runs have stopped making progress. Every other health surface reads them as fine — the convoy is open, the sessions are active, gc status is clean:
$wedged

A factory run is a convoy of pool beads drained by \`sy-build-from-prd\`. Look at it with:

  gc convoy status <convoy-id>          # which children are open, and who holds them
  gc convoy stranded                    # ready work with no worker, city-wide

Nothing has been released, reopened or respawned — this order only reports, because interrupting a run that is merely slow costs more than the delay. If a worker died holding a lease, releasing its bead returns the work to the pool; if the run finished but never completed back, the beads still need their PRs attached.

Thresholds are BUILD_WATCH_STALL_MIN (${STALL_MIN}m) and BUILD_WATCH_FINALIZE_MIN (${FINALIZE_MIN}m) in roster.conf. Each distinct stall episode is reported once." >/dev/null 2>&1

exit 0
