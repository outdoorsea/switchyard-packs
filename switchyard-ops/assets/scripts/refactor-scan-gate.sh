#!/bin/sh
# refactor-scan-gate check|peek|record|notes RIG REPO — decide whether a
# refactor-scout pass against REPO is worth paying for, and carry what a pass
# examined forward to the next one at the same content.
#
#   check  the gate proper: answers PROCEED or SKIP, and stamps the pass it just
#          authorised. NOT read-only — one call per pass, at the top of the pass.
#   peek   the same verdict without stamping, for inspecting the lane by hand.
#   record RIG REPO CANDIDATE [REASON] — file one examined-and-discarded
#          candidate against the tree in force. Bounded; see THE PASS RECORD.
#   notes  print the record retained for the tree in force, or nothing.
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
# sha. A marker written by the previous, commit-keyed build is treated as ABSENT
# by rule — see THE MARKER NAMES ITS KEY below — which authorises one more pass:
# the fail-open direction, and a one-off cost per rig.
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
MODE="${1:?refactor-scan-gate: MODE is required - check, peek, record or notes}"
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

# THE MARKER NAMES ITS KEY (switchyard PRD #413). KEY_KIND is the single place
# this gate says which kind of git object its allowance is spent against, and
# every marker it writes carries that word as its first field. Changing the key
# means changing this constant, and every marker written under the superseded key
# stops parsing on the spot.
#
# WHY A TAG AND NOT JUST A DIFFERENT HASH. A commit sha and a tree sha are both
# 40 lowercase hex characters. Nothing in a bare "<40-hex> <count>" line says
# which of the two its hash names, so a marker left by the previous commit-keyed
# build is INDISTINGUISHABLE from one this build wrote: it parses clean, lands in
# last_tree, and is then compared as though a pass had really been recorded
# against that tree — and printed to the operator as "last scanned tree <a commit
# sha>". That it does not also produce a wrong SKIP is an accident of SHA-1
# spreading two object types over one space, not a decision this script makes,
# and an unenforced second encoding is exactly the shape of defect that produced
# this PRD. With the tag the outcome is a rule: a marker under a key that is not
# the key in force is not evidence about the key in force, so it is ABSENT.
#
# ABSENT, NOT A THIRD STATE. A superseded marker resolves through the same empty
# last_tree / zero last_n as a missing file and produces the same PROCEED, on one
# code path, because that is the fail-open direction this gate is built around
# (see FAIL OPEN above). Giving it a verdict of its own would only tempt a later
# reader to give it a decision of its own. The cost is bounded and one-off: the
# first pass after a key change is authorised where it might have been skipped —
# one extra pass per rig, once, which is cheaper than migrating marker files.
KEY_KIND=tree

# Read the marker, which is EXACTLY one line of EXACTLY three fields:
#   <key-kind> <40-hex-tree-sha> <decimal-count>
#
# Anything else — a different key kind, extra fields, extra lines, a short or
# non-hex sha, a non-numeric count, an empty file, or the untagged two-field line
# older builds wrote — is treated as ABSENT, which resolves to PROCEED. The
# validation is strict on purpose: a lenient read of a corrupt marker such as
# "<kind> <sha> 2 extra" would parse a count of 2 out of a file we cannot
# actually trust and answer SKIP, which is the one direction this gate must never
# fail in.
last_tree=""; last_n=0
if [ -f "$STATE" ]; then
  _parsed="$(awk -v kind="$KEY_KIND" '
    NR > 1      { bad = 1; exit }
    NF != 3     { bad = 1; exit }
    $1 != kind  { bad = 1; exit }
    $2 !~ /^[0-9a-f]{40}$/ { bad = 1; exit }
    $3 !~ /^[0-9]+$/       { bad = 1; exit }
    { sha = $2; n = $3 }
    END { if (!bad && sha != "") print sha, n+0 }
  ' "$STATE" 2>/dev/null)"
  if [ -n "$_parsed" ]; then
    last_tree="${_parsed% *}"
    last_n="${_parsed#* }"
  fi
fi

# gate_stamp N — persist "<key-kind> <tree> N" via temp file + rename, so a pass
# killed mid-write cannot leave a half-line. The kind is stamped from the same
# KEY_KIND the reader validates against, so the writer cannot drift from the
# reader. A failed write is silent and non-fatal: the marker simply stays where
# it was, and the lane gets one more pass rather than being retired by a disk
# problem.
gate_stamp() {
  mkdir -p "$(dirname "$STATE")" 2>/dev/null || return 0
  _tmp="$STATE.$$"
  if printf '%s %s %s\n' "$KEY_KIND" "$tree" "$1" > "$_tmp" 2>/dev/null; then
    mv -f "$_tmp" "$STATE" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
  else
    rm -f "$_tmp" 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# THE PASS RECORD (switchyard PRD #413 P1) — what a pass examined and threw out.
#
# The marker above says a pass HAPPENED. It says nothing about what that pass
# looked at, so a second pass at the same tree re-derives the first pass's
# discards before it can discover it is repeating itself — measured on one rig,
# the opening third of a pass, bought nothing. The record is where a pass leaves
# what it examined and rejected, so the next one starts from those rather than
# re-walking to them.
#
# A SIDECAR, NOT MORE FIELDS ON THE MARKER. The marker is EXACTLY one line of
# EXACTLY three fields and its reader rejects anything else into the fail-open
# path. That strictness is the whole reason a superseded marker cannot be
# misread, so the record must not be smuggled into it: appending lines would make
# every marker this build writes unreadable to the builds already deployed across
# the fleet, and they would each answer PROCEED forever. Two files, one key: the
# sidecar carries the same KEY_KIND tag and the same tree sha, so the record and
# the allowance are spent against the same unit of content.
#
# BOUNDED BY CONSTRUCTION (crit:1e59d388fd77). Three bounds, all enforced on
# WRITE, so the file on disk is never larger than the ceiling even for an instant:
#
#   NOTE_MAX_ENTRIES   the most recent N records are kept; an N+1st evicts the
#                      oldest. FIFO, not "append and hope something prunes".
#   NOTE_MAX_CANDIDATE the candidate is truncated to this many bytes.
#   NOTE_MAX_REASON    the reason is truncated to this many bytes.
#
# so the file cannot exceed NOTE_MAX_ENTRIES x NOTE_MAX_LINE bytes — 12 x 568,
# under 7 KiB — no matter how many passes run, how many candidates each records,
# or how long the strings it is handed are. NOTE_MAX_LINE is derived from the
# other three rather than chosen, so the ceiling cannot drift from the caps that
# produce it; note_read drops any line longer than it, which is how a file some
# other hand grew is brought back under the bound instead of being served.
#
# DISCARDED WHEN THE TREE MOVES. The record is evidence about one tree, and a
# tree that has moved makes it evidence about nothing. It is dropped in two
# places, deliberately both:
#
#   - `check` unlinks the sidecar on the branch where the tree has moved. That is
#     the active discard, and it runs once per pass at the top of the pass, so a
#     rig that scans a new tree carries no bytes from the old one.
#   - note_read serves only lines tagged with the key in force AND the tree in
#     force, and note_record rewrites the file from that filtered read. So a
#     sidecar left behind by a crash, a copy, or a build that never ran `check`
#     is inert on read and gone on the next write.
#
# One rule would have done for the happy path; the pair is what makes "discarded"
# true of the bytes on disk and not merely of what the reader chooses to believe.
#
# PRINTABLE ASCII, ONE RECORD PER LINE. The record is line-oriented and
# tab-delimited, so a candidate or reason carrying a newline or a tab could
# otherwise forge a second entry — including one tagged with a different tree.
# note_clean maps every byte outside printable ASCII to a space before
# truncating, which closes that and makes the byte caps exact (a byte is a
# character in this alphabet, so no multibyte character is ever cut in half).
# The cost is that non-ASCII text in a path or a reason is blanked, which is a
# legibility loss in the record and never a wrong decision by the gate.
#
# FAIL OPEN, like everything else here. Every failure to read or write the
# record is silent and non-fatal: a scout whose note could not be saved has
# still done its pass, and a gate that aborted a pass over a sidecar would be
# failing in the one direction this script must never fail in.
NOTES="$(sy_state_dir)/refactor-scan.$SLUG.notes"
NOTE_MAX_ENTRIES=12
NOTE_MAX_CANDIDATE=120
NOTE_MAX_REASON=400
# kind + TAB + 40-hex + TAB + candidate + TAB + reason + newline.
NOTE_MAX_LINE=$((${#KEY_KIND} + 1 + 40 + 1 + NOTE_MAX_CANDIDATE + 1 + NOTE_MAX_REASON + 1))
# A file this writer never produces: note_read stops here rather than walking a
# sidecar something else grew, so a corrupt one costs a bounded read, not a hang.
NOTE_SCAN_LIMIT=200

# note_clean MAX TEXT — TEXT reduced to at most MAX bytes of printable ASCII.
# TEXT arrives through the environment, not argv: an awk operand that looks like
# `name=value` is consumed as a variable assignment, and a reason such as
# "coupling=high" is an ordinary thing for a scout to write.
note_clean() {
  NOTE_CLEAN_TEXT="$2" LC_ALL=C awk -v max="$1" 'BEGIN {
    s = ENVIRON["NOTE_CLEAN_TEXT"]
    gsub(/[^ -~]/, " ", s)
    if (length(s) > max) s = substr(s, 1, max)
    printf "%s", s
  }' </dev/null 2>/dev/null
}

# note_read — the retained record for the tree in force, one entry per line, in
# the order it was written. Anything tagged with another key kind or another
# tree, malformed, or over the line bound is not this tree's evidence and is not
# emitted; the last NOTE_MAX_ENTRIES survivors are, so even a file grown by some
# other hand is served under the same bound the writer enforces.
note_read() {
  [ -f "$NOTES" ] || return 0
  LC_ALL=C awk -F'\t' \
    -v kind="$KEY_KIND" -v want="$tree" \
    -v max="$NOTE_MAX_ENTRIES" -v maxlen="$NOTE_MAX_LINE" \
    -v scan="$NOTE_SCAN_LIMIT" '
    NR > scan              { exit }
    NF != 4                { next }
    $1 != kind             { next }
    $2 != want             { next }
    length($0) + 1 > maxlen { next }
    { keep[++k] = $0 }
    END {
      start = (k > max ? k - max : 0)
      for (i = start + 1; i <= k; i++) print keep[i]
    }
  ' "$NOTES" 2>/dev/null
}

# note_record CANDIDATE REASON — append one entry, then re-apply every bound.
# The file is rewritten from note_read rather than appended to, which is what
# makes the caps hold on disk rather than only in the reader: eviction, the
# line bound and the tree filter are all applied by the same write. Temp file
# plus rename, so a pass killed mid-write cannot leave a half-line.
note_record() {
  [ -n "$tree" ] || return 0
  # A record naming no candidate is evidence about nothing and would only spend
  # an entry, so it is dropped before it can evict a record that names one.
  _cand="$(note_clean "$NOTE_MAX_CANDIDATE" "$1")"
  _bare="$(printf '%s' "$_cand" | tr -d ' ')"
  [ -n "$_bare" ] || return 0
  _reason="$(note_clean "$NOTE_MAX_REASON" "$2")"
  mkdir -p "$(dirname "$NOTES")" 2>/dev/null || return 0
  _tmp="$NOTES.$$"
  if {
    note_read
    printf '%s\t%s\t%s\t%s\n' "$KEY_KIND" "$tree" "$_cand" "$_reason"
  } | tail -n "$NOTE_MAX_ENTRIES" >"$_tmp" 2>/dev/null; then
    mv -f "$_tmp" "$NOTES" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
  else
    rm -f "$_tmp" 2>/dev/null
  fi
}

# note_discard — drop the record outright. Called where the tree has moved, so
# the bytes go with the evidence they were about.
note_discard() {
  rm -f "$NOTES" 2>/dev/null || :
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
    # THE RECORD GOES WITH THE TREE IT WAS ABOUT (crit:1e59d388fd77). This is the
    # branch that means "different content", so any sidecar still on disk is a
    # note about a tree nobody is scanning any more. Unlink it here, at the top
    # of the pass that supersedes it, rather than leaving it for note_record to
    # filter out — a rig whose scout files nothing would otherwise keep the old
    # tree's bytes indefinitely, which is exactly the accumulation this bounds.
    # `peek` is read-only and discards nothing; it is the hand-inspection mode.
    [ "$MODE" = "peek" ] || note_discard
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
record)
  # record RIG REPO CANDIDATE [REASON] — leave one examined-and-discarded
  # candidate in this tree's record. Always exits 0: a note is bookkeeping for
  # the NEXT pass, and a scout must never lose the pass it is running because
  # the note could not be filed.
  CANDIDATE="${4:-}"
  REASON="${5:-}"
  if [ -z "$CANDIDATE" ]; then
    echo "refactor-scan-gate: record needs a CANDIDATE - nothing recorded." >&2
    exit 0
  fi
  if [ -z "$tree" ]; then
    echo "refactor-scan-gate: cannot read the tree in $REPO - nothing recorded." >&2
    exit 0
  fi
  note_record "$CANDIDATE" "$REASON"
  exit 0
  ;;
notes)
  # notes RIG REPO — print the record retained for the tree in force, oldest
  # first, or nothing at all. Read-only, and silent when there is nothing to
  # say: no record, an unreadable tree and a record about a tree that has since
  # moved are the same answer, because in each case this pass inherits nothing.
  [ -n "$tree" ] || exit 0
  note_read | while IFS="$(printf '\t')" read -r _kind _tree _cand _reason; do
    if [ -n "$_reason" ]; then
      echo "- $_cand: $_reason"
    else
      echo "- $_cand"
    fi
  done
  exit 0
  ;;
*)
  echo "refactor-scan-gate: unknown mode '$MODE' (want check, peek, record or notes)" >&2
  exit 2
  ;;
esac
