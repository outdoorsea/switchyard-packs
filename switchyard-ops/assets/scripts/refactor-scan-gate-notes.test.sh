#!/usr/bin/env bash
#
# Self-test for the PASS RECORD of
# packs/switchyard-ops/assets/scripts/refactor-scan-gate.sh
# (switchyard PRD #413 P1, crit:1e59d388fd77).
#
# THE VERIFICATION CONTRACT
# -------------------------
#   "The retained record is bounded and is discarded when the tree moves, so the
#    marker does not accumulate without limit"
#
# WHY THIS IS ITS OWN SUITE. The two sibling suites are about the MARKER — which
# object the allowance is spent against (refactor-scan-gate.test.sh) and what
# becomes of a marker written against a different one
# (refactor-scan-gate-marker.test.sh). Neither says anything about the sidecar
# the record lives in, and the sidecar is where unbounded growth would actually
# happen: the marker is a fixed three-field line and cannot grow at all.
#
# WHAT MAKES UNBOUNDED GROWTH EASY TO SHIP AND HARD TO SEE. A record that is
# appended to is correct on the day it is written and for weeks afterwards — a
# scout files a handful of discards per pass, the allowance is two passes, and
# nothing looks wrong. It goes wrong at a rig that never commits (the marker
# stops re-arming but the record does not), at a repo whose tree oscillates
# between two values, and at any candidate or reason long enough to matter, none
# of which a casual run reproduces. So this suite asserts the bounds NUMERICALLY
# and against a flood: 60 records with multi-kilobyte fields, where an unbounded
# writer would leave ~800 KB and the bound leaves 6,816 bytes.
#
# THE BOUNDS ARE PINNED AS LITERALS, deliberately. A suite that re-derived
# NOTE_MAX_ENTRIES x NOTE_MAX_LINE from the script would agree with any value the
# script chose, including one raised by accident, and would assert only that the
# arithmetic is self-consistent. The numbers below are the contract:
#
#   12    NOTE_MAX_ENTRIES
#   568   the longest line the writer may produce, newline included
#         (4 "tree" + 1 + 40 sha + 1 + 120 candidate + 1 + 400 reason + 1)
#   6816  the whole-file ceiling, 12 x 568
#
# Changing a constant in the gate therefore reds this suite, which is the point:
# the ceiling is a promise about a file on a city's disk, and moving it should
# cost a deliberate edit here.
#
# DISCARDED IS ABOUT BYTES, NOT BELIEF. Case 5 asserts the sidecar is UNLINKED
# when the tree moves, not merely that a moved tree is served nothing. A reader
# that filtered by tree would satisfy every "the old note is not served"
# assertion while leaving the old tree's bytes on disk forever, one file per rig
# that ever ran a pass — which is the accumulation the criterion names.
#
# THE OTHER HALF OF "WHEN THE TREE MOVES" is case 6: a commit that does NOT move
# the tree must KEEP the record. Without it, `rm -f` on every call passes cases 5
# and 7 and satisfies the criterion by never retaining anything — a record that
# is always empty is bounded in the same way an unplugged fridge is cold.
#
# It runs hermetically: a throwaway git repo plus a throwaway pack state dir via
# GC_PACK_STATE_DIR. No real city, rig, session or switchyard instance is
# involved. Needs git (skips without it).
#
# Run:  bash packs/switchyard-ops/assets/scripts/refactor-scan-gate-notes.test.sh
#       GATE_NOTES_TEST_SH=dash bash .../refactor-scan-gate-notes.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/refactor-scan-gate.sh"
PACK="$HERE/../.."

# The gate is POSIX sh and ships to cities that are not Ubuntu, so the suite can
# be re-run under another shell. `sh` is the default; CI also runs it under dash.
SH="${GATE_NOTES_TEST_SH:-sh}"

if ! command -v git >/dev/null 2>&1; then
	echo "SKIP — refactor-scan-gate notes self-test needs git (not on PATH)"
	exit 0
fi
if ! command -v "$SH" >/dev/null 2>&1; then
	echo "SKIP — refactor-scan-gate notes self-test needs $SH (not on PATH)"
	exit 0
fi

# The contract, as three numbers. See THE BOUNDS ARE PINNED AS LITERALS above.
MAX_ENTRIES=12
MAX_LINE=568
MAX_BYTES=6816

pass=0
fail=0

report() { # <ok|FAIL> <name> [detail]
	if [ "$1" = ok ]; then
		echo "ok   — $2"
		pass=$((pass + 1))
	else
		echo "FAIL — $2${3:+: $3}"
		fail=$((fail + 1))
	fi
}

# Substring assertions with NO pipeline — `printf | grep -q` under pipefail
# SIGPIPEs its producer on the success path; herestrings cannot.
has() { grep -q -F -- "$2" <<<"$1"; }

# ---------------------------------------------------------------------------
# Fixtures. Every case builds a FRESH state dir: the subject is cross-pass
# state, so a dir reused across cases would let a later case pass on an earlier
# case's record rather than its own.
# ---------------------------------------------------------------------------

new_repo() {
	mkdir -p "$1"
	git -C "$1" init -q 2>/dev/null
	git -C "$1" config user.email t@t.test
	git -C "$1" config user.name t
	echo seed >"$1/f"
	git -C "$1" add f
	git -C "$1" commit -qm seed
}

# commit_content DIR — a commit that CHANGES the tree. The discard signal.
commit_content() {
	echo "$RANDOM$RANDOM" >>"$1/f"
	git -C "$1" add f
	git -C "$1" commit -qm move
}

# commit_same_tree DIR — a new commit sha over a byte-identical tree. HEAD has
# moved; the content has not, so the record must survive.
commit_same_tree() {
	git -C "$1" commit -q --allow-empty -m "message only $RANDOM"
}

new_state() { mktemp -d; }

run_gate() { # STATE MODE RIG REPO [ARGS...]
	local state="$1"
	shift
	GC_PACK_STATE_DIR="$state" GC_PACK_DIR="$PACK" \
		"$SH" "$GATE" "$@" 2>&1
}

notes_file() { echo "$1/refactor-scan.$2.notes"; }
marker() { cat "$1/refactor-scan.$2.state" 2>/dev/null; }
lines_of() { wc -l <"$1" | tr -d ' '; }
bytes_of() { wc -c <"$1" | tr -d ' '; }
longest_line() { awk '{ if (length($0) + 1 > n) n = length($0) + 1 } END { print n + 0 }' "$1"; }

# ---------------------------------------------------------------------------
# 1. THE POSITIVE CONTROL. A record written at a tree is served back at that
#    tree. Without this, every "is not served" and "is discarded" assertion
#    below is also satisfied by a gate that records nothing at all.
# ---------------------------------------------------------------------------
state="$(new_state)"; repo="$state/rigA"; new_repo "$repo"
run_gate "$state" check rigA "$repo" >/dev/null
run_gate "$state" record rigA "$repo" "internal/db/epics.go" "already split by table; churn is the index, not the shape" >/dev/null
out="$(run_gate "$state" notes rigA "$repo")"
if has "$out" "internal/db/epics.go" && has "$out" "already split by table"; then
	report ok "a recorded candidate and its reason are served back at the same tree"
else
	report FAIL "a recorded candidate and its reason are served back at the same tree" "$out"
fi

# A reason is prose a scout writes, and prose contains `=`. An awk operand of
# the form name=value is consumed as a variable assignment rather than data, so
# a record whose reason reads "coupling=high" is the shape that silently loses
# its text — pinned here because it is invisible in every other reason.
run_gate "$state" record rigA "$repo" "internal/dashboard/dashboard.go" "coupling=high, but PRD 358 already split it" >/dev/null
out="$(run_gate "$state" notes rigA "$repo")"
if has "$out" "coupling=high, but PRD 358 already split it"; then
	report ok "a reason containing an equals sign survives intact"
else
	report FAIL "a reason containing an equals sign survives intact" "$out"
fi
rm -rf "$state"

# ---------------------------------------------------------------------------
# 2. THE ENTRY BOUND, and that eviction is FIFO. A cap that kept the FIRST N
#    would hold the same line count while pinning the record to whatever the
#    first pass happened to look at, so the newest record must be present and
#    the oldest gone.
# ---------------------------------------------------------------------------
state="$(new_state)"; repo="$state/rigA"; new_repo "$repo"
run_gate "$state" check rigA "$repo" >/dev/null
i=1
while [ "$i" -le $((MAX_ENTRIES + 8)) ]; do
	run_gate "$state" record rigA "$repo" "candidate-$i.go" "reason number $i" >/dev/null
	i=$((i + 1))
done
nf="$(notes_file "$state" rigA)"
got_lines="$(lines_of "$nf")"
out="$(run_gate "$state" notes rigA "$repo")"
if [ "$got_lines" -eq "$MAX_ENTRIES" ]; then
	report ok "$((MAX_ENTRIES + 8)) records leave exactly $MAX_ENTRIES entries on disk"
else
	report FAIL "$((MAX_ENTRIES + 8)) records leave exactly $MAX_ENTRIES entries on disk" "lines=$got_lines"
fi
if has "$out" "candidate-$((MAX_ENTRIES + 8)).go" && ! has "$out" "candidate-1.go"; then
	report ok "eviction is FIFO — the newest record survives and the oldest is gone"
else
	report FAIL "eviction is FIFO — the newest record survives and the oldest is gone" "$out"
fi
rm -rf "$state"

# ---------------------------------------------------------------------------
# 3. THE BYTE CEILING UNDER A FLOOD. 60 records whose candidate and reason are
#    each multiple kilobytes. An appending writer leaves ~800 KB here; a writer
#    that capped entries but not fields leaves ~170 KB. Only capping both holds
#    the file at $MAX_BYTES, which is the number a city's disk sees.
# ---------------------------------------------------------------------------
state="$(new_state)"; repo="$state/rigA"; new_repo "$repo"
run_gate "$state" check rigA "$repo" >/dev/null
big_c="$(head -c 5000 /dev/zero | tr '\0' 'C')"
big_r="$(head -c 9000 /dev/zero | tr '\0' 'R')"
i=1
while [ "$i" -le 60 ]; do
	run_gate "$state" record rigA "$repo" "$big_c$i" "$big_r$i" >/dev/null
	i=$((i + 1))
done
nf="$(notes_file "$state" rigA)"
got_bytes="$(bytes_of "$nf")"
got_longest="$(longest_line "$nf")"
if [ "$got_bytes" -le "$MAX_BYTES" ]; then
	report ok "60 records with multi-kilobyte fields stay under the $MAX_BYTES-byte ceiling"
else
	report FAIL "60 records with multi-kilobyte fields stay under the $MAX_BYTES-byte ceiling" "bytes=$got_bytes"
fi
if [ "$got_longest" -le "$MAX_LINE" ]; then
	report ok "no single record exceeds the $MAX_LINE-byte line bound"
else
	report FAIL "no single record exceeds the $MAX_LINE-byte line bound" "longest=$got_longest"
fi
rm -rf "$state"

# ---------------------------------------------------------------------------
# 4. ONE RECORD PER LINE. The file is line-oriented and tab-delimited, and the
#    strings come from a scout's prose. A newline or a tab in a reason would
#    otherwise write a SECOND entry — and, since the tree is a field, one
#    attributable to a tree that was never scanned. That is not a formatting
#    nicety: it is how a record about tree A gets served at tree B.
# ---------------------------------------------------------------------------
state="$(new_state)"; repo="$state/rigA"; new_repo "$repo"
run_gate "$state" check rigA "$repo" >/dev/null
forged_tree="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
run_gate "$state" record rigA "$repo" "one.go" "first line
tree	$forged_tree	forged.go	forged reason" >/dev/null
nf="$(notes_file "$state" rigA)"
got_lines="$(lines_of "$nf")"
if [ "$got_lines" -eq 1 ]; then
	report ok "a newline in a reason cannot forge a second entry"
else
	report FAIL "a newline in a reason cannot forge a second entry" "lines=$got_lines
$(cat "$nf")"
fi
# Asserted on the KEY FIELD, not on the file as a string. The forged sha is
# still present as text — it is inside the reason the scout wrote, where it is
# just characters — and demanding its absence would be demanding the writer
# censor a scout's prose. What must be true is that no RECORD is keyed to it:
# field 2 is what note_read compares the tree in force against, so a line
# holding that sha in field 2 is a record that would be served at a tree this
# rig never scanned.
forged_rows="$(awk -F'\t' -v t="$forged_tree" '$2 == t { n++ } END { print n + 0 }' "$nf")"
if [ "$forged_rows" -eq 0 ]; then
	report ok "an injected line cannot attribute a record to another tree"
else
	report FAIL "an injected line cannot attribute a record to another tree" "$(cat "$nf")"
fi
rm -rf "$state"

# ---------------------------------------------------------------------------
# 5. DISCARDED WHEN THE TREE MOVES — asserted on the BYTES. The sidecar must be
#    unlinked by the `check` that opens the pass at the new tree, not merely
#    filtered out on read: a filtering reader satisfies "the old note is not
#    served" while leaving one stale file per rig on disk forever.
# ---------------------------------------------------------------------------
state="$(new_state)"; repo="$state/rigA"; new_repo "$repo"
run_gate "$state" check rigA "$repo" >/dev/null
run_gate "$state" record rigA "$repo" "old.go" "examined at the old tree" >/dev/null
nf="$(notes_file "$state" rigA)"
[ -f "$nf" ] || report FAIL "case 5 fixture wrote a record" "no sidecar at $nf"
commit_content "$repo"
run_gate "$state" check rigA "$repo" >/dev/null
if [ ! -e "$nf" ]; then
	report ok "the sidecar is unlinked when the pass opens at a moved tree"
else
	report FAIL "the sidecar is unlinked when the pass opens at a moved tree" "$(cat "$nf")"
fi
out="$(run_gate "$state" notes rigA "$repo")"
if [ -z "$out" ]; then
	report ok "a moved tree inherits no record"
else
	report FAIL "a moved tree inherits no record" "$out"
fi
rm -rf "$state"

# ---------------------------------------------------------------------------
# 6. THE OTHER HALF: a commit that does NOT move the tree KEEPS the record.
#    This is the case that stops "discard everything, always" from passing the
#    criterion — and it is the same tree-identical merge the P0 half of this PRD
#    is about, seen from the record's side: the memory follows the content, so
#    the second pass at one tree inherits what the first pass discarded even
#    though HEAD has moved between them.
# ---------------------------------------------------------------------------
state="$(new_state)"; repo="$state/rigA"; new_repo "$repo"
run_gate "$state" check rigA "$repo" >/dev/null
run_gate "$state" record rigA "$repo" "kept.go" "discarded on pass 1, still true on pass 2" >/dev/null
commit_same_tree "$repo"
run_gate "$state" check rigA "$repo" >/dev/null
out="$(run_gate "$state" notes rigA "$repo")"
if has "$out" "kept.go" && has "$out" "still true on pass 2"; then
	report ok "a commit that does not move the tree keeps the record"
else
	report FAIL "a commit that does not move the tree keeps the record" "$out"
fi
rm -rf "$state"

# ---------------------------------------------------------------------------
# 7. A SIDECAR FROM ANOTHER TREE IS INERT, AND IS REPLACED. The active discard
#    in `check` covers the rig that keeps scanning; this covers everything else
#    that can leave a file behind — a crashed pass, a copied state dir, a build
#    that never ran `check`. Such a file must serve nothing, and the next record
#    must leave only the tree in force behind.
# ---------------------------------------------------------------------------
state="$(new_state)"; repo="$state/rigA"; new_repo "$repo"
nf="$(notes_file "$state" rigA)"
printf 'tree\t%s\tstale.go\tabout a tree nobody is scanning\n' "$forged_tree" >"$nf"
printf 'commit\t%s\twrongkind.go\tunder a superseded key\n' "$(git -C "$repo" rev-parse "HEAD^{tree}")" >>"$nf"
out="$(run_gate "$state" notes rigA "$repo")"
if [ -z "$out" ]; then
	report ok "a sidecar from another tree, or under another key, serves nothing"
else
	report FAIL "a sidecar from another tree, or under another key, serves nothing" "$out"
fi
run_gate "$state" record rigA "$repo" "fresh.go" "examined at the tree in force" >/dev/null
if ! grep -q -F "stale.go" "$nf" && ! grep -q -F "wrongkind.go" "$nf" && grep -q -F "fresh.go" "$nf"; then
	report ok "the next record rewrites the sidecar, dropping what was not this tree's"
else
	report FAIL "the next record rewrites the sidecar, dropping what was not this tree's" "$(cat "$nf")"
fi
rm -rf "$state"

# ---------------------------------------------------------------------------
# 8. A SIDECAR GROWN BY SOMETHING ELSE IS BROUGHT BACK UNDER THE BOUND. The
#    bounds are enforced on write, so they hold for files this writer produced.
#    A file that arrived some other way — an editor, a merge of two state dirs,
#    an older build — must not be served whole, and one record must return it to
#    the ceiling rather than appending to it.
# ---------------------------------------------------------------------------
state="$(new_state)"; repo="$state/rigA"; new_repo "$repo"
nf="$(notes_file "$state" rigA)"
tree_sha="$(git -C "$repo" rev-parse "HEAD^{tree}")"
i=1
while [ "$i" -le 500 ]; do
	printf 'tree\t%s\tgrown-%s.go\thand-grown entry %s\n' "$tree_sha" "$i" "$i" >>"$nf"
	i=$((i + 1))
done
served="$(run_gate "$state" notes rigA "$repo" | wc -l | tr -d ' ')"
if [ "$served" -le "$MAX_ENTRIES" ]; then
	report ok "an oversized sidecar is served under the entry bound, not whole"
else
	report FAIL "an oversized sidecar is served under the entry bound, not whole" "served=$served"
fi
run_gate "$state" record rigA "$repo" "after.go" "one record after the file was grown" >/dev/null
got_lines="$(lines_of "$nf")"
got_bytes="$(bytes_of "$nf")"
if [ "$got_lines" -le "$MAX_ENTRIES" ] && [ "$got_bytes" -le "$MAX_BYTES" ]; then
	report ok "one record returns a hand-grown sidecar to the ceiling"
else
	report FAIL "one record returns a hand-grown sidecar to the ceiling" "lines=$got_lines bytes=$got_bytes"
fi
rm -rf "$state"

# ---------------------------------------------------------------------------
# 9. `peek` DISCARDS NOTHING. It is the hand-inspection mode and is documented
#    read-only; an operator looking at a lane must not be the reason a record
#    was thrown away.
# ---------------------------------------------------------------------------
state="$(new_state)"; repo="$state/rigA"; new_repo "$repo"
run_gate "$state" check rigA "$repo" >/dev/null
run_gate "$state" record rigA "$repo" "peeked.go" "still here after a peek" >/dev/null
nf="$(notes_file "$state" rigA)"
commit_content "$repo"
run_gate "$state" peek rigA "$repo" >/dev/null
if [ -f "$nf" ] && grep -q -F "peeked.go" "$nf"; then
	report ok "peek at a moved tree leaves the record alone"
else
	report FAIL "peek at a moved tree leaves the record alone" "$(ls -l "$nf" 2>&1)"
fi
rm -rf "$state"

# ---------------------------------------------------------------------------
# 10. THE MARKER IS NOT WHERE THE RECORD GOES. The marker's reader accepts
#     EXACTLY one line of EXACTLY three fields and rejects everything else into
#     the fail-open path — the rule the sibling marker suite rests on. A record
#     smuggled into it would make every marker this build writes unreadable to
#     the builds already deployed, so the record must leave it byte-identical.
# ---------------------------------------------------------------------------
state="$(new_state)"; repo="$state/rigA"; new_repo "$repo"
run_gate "$state" check rigA "$repo" >/dev/null
before="$(marker "$state" rigA)"
run_gate "$state" record rigA "$repo" "somewhere.go" "a reason long enough to notice if it leaked into the marker" >/dev/null
after="$(marker "$state" rigA)"
if [ "$before" = "$after" ] && [ "$after" = "tree $(git -C "$repo" rev-parse "HEAD^{tree}") 1" ]; then
	report ok "recording leaves the marker byte-identical and three fields wide"
else
	report FAIL "recording leaves the marker byte-identical and three fields wide" "before=[$before] after=[$after]"
fi
rm -rf "$state"

# ---------------------------------------------------------------------------
# 11. FAIL OPEN. Every failure around the record is silent and non-fatal: the
#     note is bookkeeping for the NEXT pass, and a scout must never lose the
#     pass it is running because the note could not be filed. A record with no
#     candidate, a record against an unreadable repo, and `notes` against one
#     all exit 0 — the direction this gate is allowed to fail in.
# ---------------------------------------------------------------------------
state="$(new_state)"; repo="$state/rigA"; new_repo "$repo"
run_gate "$state" record rigA "$repo" >/dev/null 2>&1; rc_nocand=$?
run_gate "$state" record rigA "$state/not-a-repo" "x.go" "y" >/dev/null 2>&1; rc_norepo=$?
out_norepo="$(run_gate "$state" notes rigA "$state/not-a-repo" 2>/dev/null)"; rc_notes=$?
if [ "$rc_nocand" -eq 0 ] && [ "$rc_norepo" -eq 0 ] && [ "$rc_notes" -eq 0 ] && [ -z "$out_norepo" ]; then
	report ok "a record with no candidate, and either mode against an unreadable repo, fail open"
else
	report FAIL "a record with no candidate, and either mode against an unreadable repo, fail open" \
		"rc=$rc_nocand/$rc_norepo/$rc_notes out=$out_norepo"
fi
# An empty candidate must not spend an entry either: it names nothing, and
# evicting a record that does name something would be a bound working backwards.
run_gate "$state" check rigA "$repo" >/dev/null
run_gate "$state" record rigA "$repo" "real.go" "the only record here" >/dev/null
run_gate "$state" record rigA "$repo" "   " "whitespace is not a candidate" >/dev/null
nf="$(notes_file "$state" rigA)"
if [ "$(lines_of "$nf")" -eq 1 ] && grep -q -F "real.go" "$nf"; then
	report ok "a blank candidate does not spend an entry"
else
	report FAIL "a blank candidate does not spend an entry" "$(cat "$nf")"
fi
rm -rf "$state"

# ---------------------------------------------------------------------------
echo
echo "refactor-scan-gate notes self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
