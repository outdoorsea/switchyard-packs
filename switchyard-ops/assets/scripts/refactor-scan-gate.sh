#!/bin/sh
# refactor-scan-gate check|peek RIG REPO — decide whether a refactor-scout pass
# against REPO is worth paying for.
#
#   check  the gate proper: answers PROCEED or SKIP, and stamps the pass it just
#          authorised. NOT read-only — one call per pass, at the top of the pass.
#   peek   the same verdict without stamping, for inspecting the lane by hand.
#
# WHY THIS EXISTS (switchyard issue 163). The refactor-scout's evidence is a
# 6-month git window over one repo. Two passes at the same commit derive the same
# ranking from the same history — the second is a pure re-spend. The lane was
# already supposed to be guarded: `orders/refactor-scan.toml` sets a 168h cooldown
# and its own comment names that cadence AS the guard.
#
# THE FLAW: that guard lives in the SCHEDULER, and the scheduler is not what
# fires. Over the 24h to 2026-08-01T22:08Z the order fired 0 times; all 29 passes
# came from the reconciler's revive loop (switchyard issues #129/#154). A guard
# that only the cooldown enforces evaporates the moment something else does the
# spawning — and nothing downstream could tell. The lane could even SEE it was
# repeating ("twentieth adhoc pass, at HEAD f114044 - unchanged for the seventh
# consecutive") and then ran the full scan anyway, because noticing was not wired
# to stopping. Cost: 45.40M tokens/24h across the switchyard and faultline scouts,
# 23.8% of the whole city's burn.
#
# So the gate belongs where every pass must pass through it regardless of who
# started the session: the scout's own first action. See the "Gate" section of
# agents/refactor-scout/prompt.template.md.
#
# THE KEY: HEAD sha, with a small allowance of passes per sha
# (REFACTOR_SCAN_PASSES_PER_SHA, default 2). A strict once-per-sha gate is
# cheapest, but a repo whose first pass was under-served then gets no second look
# until somebody happens to commit. Allowing exactly one re-look bounds that
# without reopening the loop: a pinned clone that never moves costs two passes
# total, ever, instead of two a day.
#
# FAIL OPEN, DELIBERATELY. Every unreadable state — no git, no state dir, a
# corrupt marker — answers PROCEED. A broken gate that fails closed would silently
# retire the lane, and a lane that never runs can never report that it isn't
# running (the same shape as the sy_coordinators bug documented in lane-ensure.sh).
# Failing open costs money and is visible in the next token report; failing closed
# costs the lane and is visible to nobody.
#
# Exit codes (check): 0 = run the pass, 10 = skip it. The verdict is also printed.
set -u

# Keep these :? messages free of quotes, apostrophes and parentheses — the word
# inside ${...} is still parsed for quoting, so a lone apostrophe in a usage
# string opens a quote and breaks the whole file at parse time.
MODE="${1:?refactor-scan-gate: MODE is required - check or peek}"
RIG="${2:?refactor-scan-gate: RIG is required}"
REPO="${3:?refactor-scan-gate: REPO is required - path to the rig repo}"

. "$(dirname "$0")/../lib/roster.sh"
sy_load_conf

PASSES_PER_SHA="${REFACTOR_SCAN_PASSES_PER_SHA:-2}"
case "$PASSES_PER_SHA" in ''|*[!0-9]*) PASSES_PER_SHA=2 ;; esac

# One marker per rig — the scouts are per-rig and their repos move independently.
# Sanitised because the marker name is a path segment and the rig name is not.
SLUG="$(printf '%s' "$RIG" | sed 's/[^A-Za-z0-9._-]/_/g')"
STATE="$(sy_state_dir)/refactor-scan.$SLUG.state"

head="$(git -C "$REPO" rev-parse HEAD 2>/dev/null | awk 'NF' | head -n1)"

# Read the marker, which is EXACTLY one line of EXACTLY two fields:
#   <40-hex-sha> <decimal-count>
#
# Anything else — extra fields, extra lines, a short or non-hex sha, a non-numeric
# count, an empty file — is treated as ABSENT, which resolves to PROCEED. The
# validation is strict on purpose: a lenient read of a corrupt marker such as
# "<sha> 2 extra" would parse a count of 2 out of a file we cannot actually trust
# and answer SKIP, which is the one direction this gate must never fail in.
last_sha=""; last_n=0
if [ -f "$STATE" ]; then
  _parsed="$(awk '
    NR > 1      { bad = 1; exit }
    NF != 2     { bad = 1; exit }
    $1 !~ /^[0-9a-f]{40}$/ { bad = 1; exit }
    $2 !~ /^[0-9]+$/       { bad = 1; exit }
    { sha = $1; n = $2 }
    END { if (!bad && sha != "") print sha, n+0 }
  ' "$STATE" 2>/dev/null)"
  if [ -n "$_parsed" ]; then
    last_sha="${_parsed% *}"
    last_n="${_parsed#* }"
  fi
fi

# gate_stamp N — persist "<head> N" via temp file + rename, so a pass killed
# mid-write cannot leave a half-line. A failed write is silent and non-fatal: the
# marker simply stays where it was, and the lane gets one more pass rather than
# being retired by a disk problem.
gate_stamp() {
  mkdir -p "$(dirname "$STATE")" 2>/dev/null || return 0
  _tmp="$STATE.$$"
  if printf '%s %s\n' "$head" "$1" > "$_tmp" 2>/dev/null; then
    mv -f "$_tmp" "$STATE" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
  else
    rm -f "$_tmp" 2>/dev/null
  fi
}

case "$MODE" in
check|peek)
  if [ -z "$head" ]; then
    echo "PROCEED: cannot read HEAD of $REPO — gate fails open."
    exit 0
  fi
  if [ "$head" != "$last_sha" ]; then
    n=1
    reason="$RIG is at $head; last scanned '${last_sha:-<never>}'."
  elif [ "$last_n" -lt "$PASSES_PER_SHA" ]; then
    n=$((last_n + 1))
    reason="$RIG still at $head; this is pass $n of the $PASSES_PER_SHA allowed at this commit."
  else
    echo "SKIP: $RIG is unchanged at $head and has already had $last_n pass(es) at this commit. The evidence window has not moved — a scan now would re-derive the same ranking. Exit the turn without reading anything."
    exit 10
  fi
  # `check` STAMPS THE PASS ITSELF. It deliberately does not defer that to a
  # second command at the end of the turn, for two reasons:
  #
  #  1. A separate end-of-turn record is one more instruction the scout has to
  #     obey, and forgetting it restores the exact unbounded loop this gate
  #     exists to close — the worst possible failure, reintroduced by omission.
  #  2. Two commands means two independent reads of HEAD. If HEAD advanced
  #     between them, the pass that actually scanned commit A would be recorded
  #     against commit B, and B could then be skipped having never been scanned.
  #     One read and one write cannot race with themselves.
  #
  # The accepted cost: a session that dies after the gate still consumes an
  # allowance. That is a bounded, self-healing loss — the next commit resets the
  # count — and it also caps runaway spawning by sessions that crash on startup.
  # Use `peek` for the read-only form when inspecting the lane by hand.
  [ "$MODE" = "peek" ] || gate_stamp "$n"
  echo "PROCEED: $reason"
  exit 0
  ;;
*)
  echo "refactor-scan-gate: unknown mode '$MODE' (want check or peek)" >&2
  exit 2
  ;;
esac
