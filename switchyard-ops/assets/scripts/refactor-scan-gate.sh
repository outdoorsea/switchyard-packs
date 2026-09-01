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
# THE KEY: HEAD's TREE object — `rev-parse HEAD^{tree}` — with a small allowance
# of passes per tree (REFACTOR_SCAN_PASSES_PER_SHA, default 2). A strict
# once-per-tree gate is cheapest, but a repo whose first pass was under-served
# then gets no second look until somebody happens to commit. Allowing exactly one
# re-look bounds that without reopening the loop: a pinned clone that never moves
# costs two passes total, ever, instead of two a day.
#
# WHY THE TREE AND NOT THE COMMIT (switchyard PRD #413). The premise this key
# stands in for is about CONTENT: an unmoved repo means "a scan now re-derives
# the same ranking from the same history". The commit sha only approximates that,
# and the approximation breaks on exactly the commit kind this fleet produces
# most. Across switchyard-forge's 207 commits there are 80 merges, and 42 of them
# (52.5%) have a tree byte-identical to a parent. Each such commit is a new sha
# over unchanged content, so a sha-keyed marker RESET the count: one tree seen
# under N shas bought 2N passes instead of 2. Measured: three passes against a
# ceiling of two. Keying on the tree spends the allowance per unit of content, so
# tree-identical merges — and empty or message-only commits, which have the same
# shape — share one allowance between them.
#
# The env var keeps its shipped name (…_PASSES_PER_SHA) so a city that already
# sets it does not silently lose its setting; the "SHA" in it now names the tree
# sha. A marker written by the previous, commit-keyed build holds a commit sha,
# which can never equal a tree sha, so it simply fails to match and authorises
# one more pass — the fail-open direction, and a one-off cost per rig.
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

# TWO IDENTITIES, DELIBERATELY. The TREE is what the gate decides on; the COMMIT
# is what it says out loud. A human reading the lane's log recognises the sha
# `git log` just printed them, not the tree object behind it, so a verdict that
# named only the tree would read as a bug on the one case this change makes
# possible: HEAD moved, the gate still says SKIP (a merge or a message-only
# commit). Every verdict below therefore prints the commit AND the tree.
#
# `HEAD^{tree}` stays quoted. The script is /bin/sh, but it is also hand-run, and
# in zsh a bare `HEAD^{tree}` is eaten as a glob/brace expression before git ever
# sees the revspec.
head="$(git -C "$REPO" rev-parse HEAD 2>/dev/null | awk 'NF' | head -n1)"
tree="$(git -C "$REPO" rev-parse "HEAD^{tree}" 2>/dev/null | awk 'NF' | head -n1)"

# Read the marker, which is EXACTLY one line of EXACTLY two fields:
#   <40-hex-tree-sha> <decimal-count>
#
# Anything else — extra fields, extra lines, a short or non-hex sha, a non-numeric
# count, an empty file — is treated as ABSENT, which resolves to PROCEED. The
# validation is strict on purpose: a lenient read of a corrupt marker such as
# "<sha> 2 extra" would parse a count of 2 out of a file we cannot actually trust
# and answer SKIP, which is the one direction this gate must never fail in.
last_tree=""; last_n=0
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
    last_tree="${_parsed% *}"
    last_n="${_parsed#* }"
  fi
fi

# gate_stamp N — persist "<tree> N" via temp file + rename, so a pass killed
# mid-write cannot leave a half-line. A failed write is silent and non-fatal: the
# marker simply stays where it was, and the lane gets one more pass rather than
# being retired by a disk problem.
gate_stamp() {
  mkdir -p "$(dirname "$STATE")" 2>/dev/null || return 0
  _tmp="$STATE.$$"
  if printf '%s %s\n' "$tree" "$1" > "$_tmp" 2>/dev/null; then
    mv -f "$_tmp" "$STATE" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
  else
    rm -f "$_tmp" 2>/dev/null
  fi
}

case "$MODE" in
check|peek)
  # Either identity unreadable is the fail-open case. The tree is the one the
  # decision needs, but a repo that can produce a tree and not a HEAD is broken
  # in some way this gate has no business ruling on either.
  if [ -z "$head" ] || [ -z "$tree" ]; then
    echo "PROCEED: cannot read HEAD or its tree in $REPO — gate fails open."
    exit 0
  fi
  if [ "$tree" != "$last_tree" ]; then
    n=1
    reason="$RIG is at $head (tree $tree); last scanned tree '${last_tree:-<never>}'."
  elif [ "$last_n" -lt "$PASSES_PER_SHA" ]; then
    n=$((last_n + 1))
    reason="$RIG is at $head, whose tree $tree is the one last scanned; this is pass $n of the $PASSES_PER_SHA allowed at this content."
  else
    echo "SKIP: $RIG is at $head, whose tree $tree has already had $last_n pass(es). The commit sha may have moved — a merge or a message-only commit does that without changing a byte — but the evidence window has not, so a scan now would re-derive the same ranking. Exit the turn without reading anything."
    exit 10
  fi
  # `check` STAMPS THE PASS ITSELF. It deliberately does not defer that to a
  # second command at the end of the turn, for two reasons:
  #
  #  1. A separate end-of-turn record is one more instruction the scout has to
  #     obey, and forgetting it restores the exact unbounded loop this gate
  #     exists to close — the worst possible failure, reintroduced by omission.
  #  2. Two commands means two independent reads of the tree. If the repo
  #     advanced between them, the pass that actually scanned tree A would be
  #     recorded against tree B, and B could then be skipped having never been
  #     scanned. One read and one write cannot race with themselves.
  #
  # The accepted cost: a session that dies after the gate still consumes an
  # allowance. That is a bounded, self-healing loss — the next change to the tree
  # resets the count — and it also caps runaway spawning by crash-on-start
  # sessions.
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
