#!/usr/bin/env bash
#
# Self-test for the MARKER FORMAT of
# packs/switchyard-ops/assets/scripts/refactor-scan-gate.sh
# (switchyard PRD #413 P0, crit:987e51b92b4a).
#
# THE VERIFICATION CONTRACT
# -------------------------
#   "A marker written under the previous commit-sha key is treated as absent
#    rather than misread, consistent with the script's existing fail-open
#    behaviour"
#
# WHY THIS IS ITS OWN SUITE, and not folded into refactor-scan-gate.test.sh. That
# sibling asserts WHICH object the allowance is spent against. This one asserts
# what happens to a marker written against a DIFFERENT one — and the two can be
# got wrong independently. A gate that keys correctly and still reads a superseded
# marker as though it were its own passes every case the sibling has, because
# every fixture there is written by the build under test.
#
# WHAT MAKES THAT FAILURE INVISIBLE TO INSPECTION. A commit sha and a tree sha are
# both 40 lowercase hex characters. An untagged "<40-hex> <count>" line does not
# say which kind of object its hash names, so a marker from the commit-keyed build
# parses clean and lands in last_tree, where it is compared as if a pass had been
# recorded against that tree — and printed back to the operator as "last scanned
# tree <a commit sha>". It is saved from also producing a wrong SKIP only by the
# two hashes happening to differ: an accident of SHA-1 spreading two object types
# over one space, not a decision the script makes. The criterion asks for ABSENT,
# which is a rule; "does not happen to match" is not one.
#
# So the fixtures here seed the marker with the value the gate is actually
# comparing against — the TREE sha, the key in force — rather than a commit sha
# the hashes would reject for free. Cases 1 and 3 are the load-bearing pair: under
# a reader that tolerated a missing or unchecked tag, each of them matches at the
# allowance and answers SKIP. Only treating them as absent produces PROCEED, so
# neither can pass vacuously. Case 3a then pins the literal on-disk shape the
# fleet is carrying today.
#
# CONSISTENT WITH FAIL-OPEN is the other half, and it is why every assertion about
# a superseded marker is on the PROCEED side. Such a marker must resolve to
# PROCEED through the same path a missing one does (cases 1, 3, 3a, 9), must not
# carry its count forward (case 2), and must not have broken the gate's ability to
# say SKIP at all (cases 4, 5, 7) — a "treat it as absent" that also swallowed
# well-formed markers would satisfy the letter of the criterion by retiring the
# lane, which is the one direction this gate must never fail in.
#
# It runs hermetically: a throwaway git repo plus a throwaway pack state dir via
# GC_PACK_STATE_DIR. No real city, rig, session or switchyard instance is
# involved. Needs git (skips without it).
#
# Run:  bash packs/switchyard-ops/assets/scripts/refactor-scan-gate-marker.test.sh
#       GATE_MARKER_TEST_SH=dash bash .../refactor-scan-gate-marker.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/refactor-scan-gate.sh"

# The gate is POSIX sh and ships to cities that are not Ubuntu, so the suite can
# be re-run under another shell. `sh` is the default; CI also runs it under dash.
SH="${GATE_MARKER_TEST_SH:-sh}"

if ! command -v git >/dev/null 2>&1; then
	echo "SKIP — refactor-scan-gate marker self-test needs git (not on PATH)"
	exit 0
fi
if ! command -v "$SH" >/dev/null 2>&1; then
	echo "SKIP — refactor-scan-gate marker self-test needs $SH (not on PATH)"
	exit 0
fi

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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A throwaway repo with one commit. Every case here is about how a marker line is
# READ, not about which object the gate resolves — the sibling suite owns that —
# so one commit is enough and keeps the fixtures legible.
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" config user.email gate@test.invalid
git -C "$REPO" config user.name 'Gate Test'
: > "$REPO/a"
git -C "$REPO" add a
git -C "$REPO" -c commit.gpgsign=false commit -qm 'seed'
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
TREE_SHA="$(git -C "$REPO" rev-parse "HEAD^{tree}")"

# Guard the fixture itself: if these ever coincided, case 3a would stop being
# about the commit key and every "the hashes saved it" claim below would be void.
if [ "$HEAD_SHA" = "$TREE_SHA" ]; then
	echo "FAIL — fixture repo has HEAD sha == tree sha; the suite cannot distinguish the keys"
	exit 1
fi

# The key kind the build under test decides on, read from the script rather than
# hardcoded — this suite is about the tag MECHANISM, so it must keep asserting the
# right thing if the key is ever changed again. The superseded kind is then simply
# "the other one".
KIND="$(sed -n 's/^KEY_KIND=\([A-Za-z0-9_-]*\).*/\1/p' "$GATE" | head -n1)"
if [ -z "$KIND" ]; then
	echo "FAIL — could not read KEY_KIND from $GATE; the marker tag is the whole subject of this suite"
	exit 1
fi
case "$KIND" in
commit) SUPERSEDED_KIND=tree ;;
*) SUPERSEDED_KIND=commit ;;
esac

# KEY_SHA — the hash the gate is comparing against under the key in force. The
# fixtures use it precisely so that a marker the reader ought to discard would
# otherwise MATCH.
case "$KIND" in
commit) KEY_SHA="$HEAD_SHA" ;;
*) KEY_SHA="$TREE_SHA" ;;
esac

# run_gate MODE MARKER_CONTENT — a fresh state dir per case, seeded with exactly
# MARKER_CONTENT (or left empty when that is the literal string __none__).
#
# It sets the globals OUT (the verdict), RC (the exit code) and STATE_FILE, and is
# deliberately NOT called inside a command substitution: the gate's exit code is
# half of every assertion here (0 = PROCEED, 10 = SKIP) and the marker it leaves
# behind is the other half, and a subshell loses both.
STATE_DIR=""
STATE_FILE=""
CASE_N=0
OUT=""
RC=0
run_gate() { # <check|peek> <marker-content-or-__none__>
	CASE_N=$((CASE_N + 1))
	STATE_DIR="$TMP/state.$CASE_N"
	mkdir -p "$STATE_DIR"
	STATE_FILE="$STATE_DIR/refactor-scan.testrig.state"
	if [ "$2" != "__none__" ]; then
		printf '%s' "$2" > "$STATE_FILE"
	fi
	rerun_gate "$1"
}

# rerun_gate MODE — another call against the state dir the last run left behind,
# for the cases that need the writer and the reader to meet.
rerun_gate() { # <check|peek>
	OUT="$(GC_CITY="$TMP/city" GC_PACK_STATE_DIR="$STATE_DIR" \
		"$SH" "$GATE" "$1" testrig "$REPO" 2>&1)"
	RC=$?
}

# marker — the current contents of the case's marker file, or the empty string
# when it does not exist.
marker() { cat "$STATE_FILE" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 1. THE CRITERION. A marker in the previous, untagged two-field format — the
#    shape every marker on disk in the fleet has right now — is treated as
#    absent, so the gate PROCEEDs.
#
#    Seeded with the key in force's own hash and a count AT the allowance: under
#    the previous reader this exact line parses clean, matches, and answers SKIP,
#    and a new reader lenient about the missing tag would do the same. Only
#    treating it as absent produces PROCEED here.
# ---------------------------------------------------------------------------
run_gate check "$KEY_SHA 2
"
if [ "$RC" = 0 ] && [ "${OUT#PROCEED}" != "$OUT" ]; then
	report ok "an untagged legacy marker at the allowance is absent, not a SKIP"
else
	report FAIL "an untagged legacy marker at the allowance is absent, not a SKIP" "rc=$RC out=$OUT"
fi

# ---------------------------------------------------------------------------
# 2. ABSENT MEANS ABSENT, INCLUDING THE COUNT. Having proceeded past a legacy
#    marker, the gate restarts the allowance at 1 rather than carrying the
#    superseded count forward — a reader that salvaged the number while
#    discarding the hash would still be misreading the file.
# ---------------------------------------------------------------------------
if [ "$(marker)" = "$KIND $KEY_SHA 1" ]; then
	report ok "a legacy marker's count is discarded, not carried forward"
else
	report FAIL "a legacy marker's count is discarded, not carried forward" "marker=$(marker)"
fi

# ---------------------------------------------------------------------------
# 3. THE CASE THE HASHES CANNOT SAVE. A marker tagged with the SUPERSEDED key
#    kind, whose hash is the very value the gate is comparing against. If the tag
#    were written but not checked, this parses clean, matches, and answers SKIP at
#    the allowance. Absent by rule is the only thing that gets PROCEED out of it —
#    this is the case that separates "absent" from "did not happen to match".
# ---------------------------------------------------------------------------
run_gate check "$SUPERSEDED_KIND $KEY_SHA 2
"
if [ "$RC" = 0 ] && [ "${OUT#PROCEED}" != "$OUT" ]; then
	report ok "a marker under the superseded key kind is absent even when its hash matches"
else
	report FAIL "a marker under the superseded key kind is absent even when its hash matches" "rc=$RC out=$OUT"
fi

# ---------------------------------------------------------------------------
# 3a. THE LITERAL SHAPE ON DISK TODAY: an untagged two-field line holding a
#     COMMIT sha, which is what the commit-keyed build wrote. Weaker than cases 1
#     and 3 on its own — the hashes alone would reject it — but it is the actual
#     changeover input, and it must land on PROCEED and re-stamp under the key in
#     force rather than lingering.
# ---------------------------------------------------------------------------
run_gate check "$HEAD_SHA 2
"
if [ "$RC" = 0 ] && [ "${OUT#PROCEED}" != "$OUT" ] && [ "$(marker)" = "$KIND $KEY_SHA 1" ]; then
	report ok "the commit-keyed marker the fleet is carrying proceeds and is re-stamped"
else
	report FAIL "the commit-keyed marker the fleet is carrying proceeds and is re-stamped" \
		"rc=$RC out=$OUT marker=$(marker)"
fi

# ---------------------------------------------------------------------------
# 4. FAIL-OPEN IS NOT FAIL-ALWAYS. A well-formed marker under the key in force, at
#    the allowance, still SKIPs. Without this, "treat unrecognised markers as
#    absent" could be satisfied by treating EVERY marker as absent — which retires
#    the gate silently, the failure direction the script's FAIL OPEN note exists to
#    rule out.
# ---------------------------------------------------------------------------
run_gate check "$KIND $KEY_SHA 2
"
if [ "$RC" = 10 ] && [ "${OUT#SKIP}" != "$OUT" ]; then
	report ok "a well-formed marker at the allowance still SKIPs"
else
	report FAIL "a well-formed marker at the allowance still SKIPs" "rc=$RC out=$OUT"
fi

# ---------------------------------------------------------------------------
# 5. …and below the allowance it still spends the second pass and increments,
#    rather than restarting the count.
# ---------------------------------------------------------------------------
run_gate check "$KIND $KEY_SHA 1
"
if [ "$RC" = 0 ] && [ "${OUT#PROCEED}" != "$OUT" ] && [ "$(marker)" = "$KIND $KEY_SHA 2" ]; then
	report ok "a well-formed marker below the allowance increments"
else
	report FAIL "a well-formed marker below the allowance increments" "rc=$RC out=$OUT marker=$(marker)"
fi

# ---------------------------------------------------------------------------
# 6. THE WRITER STAMPS THE TAG. A pass authorised with no marker at all leaves a
#    three-field line naming the key kind — the property that lets the NEXT key
#    change be a rule rather than an accident.
# ---------------------------------------------------------------------------
run_gate check __none__
if [ "$RC" = 0 ] && [ "$(marker)" = "$KIND $KEY_SHA 1" ]; then
	report ok "the gate stamps a key-kind-tagged marker"
else
	report FAIL "the gate stamps a key-kind-tagged marker" "rc=$RC marker=$(marker)"
fi

# ---------------------------------------------------------------------------
# 7. WRITER AND READER MEET. Three consecutive checks from an empty state dir:
#    PROCEED, PROCEED, SKIP. Adding a field to the format is precisely the change
#    that can leave the writer emitting something its own reader rejects — which
#    would look like a working fail-open while the allowance never bound anything
#    again.
# ---------------------------------------------------------------------------
run_gate check __none__; rc1=$RC; out1=$OUT
rerun_gate check;         rc2=$RC; out2=$OUT
rerun_gate check;         rc3=$RC; out3=$OUT
if [ "$rc1" = 0 ] && [ "$rc2" = 0 ] && [ "$rc3" = 10 ] && [ "${out3#SKIP}" != "$out3" ]; then
	report ok "what the gate writes, the gate reads: PROCEED, PROCEED, SKIP"
else
	report FAIL "what the gate writes, the gate reads: PROCEED, PROCEED, SKIP" \
		"rc=$rc1/$rc2/$rc3 out1=$out1 out2=$out2 out3=$out3"
fi

# ---------------------------------------------------------------------------
# 8. THE EXISTING CORRUPTION CASES SURVIVE THE EXTRA FIELD. Each of these was
#    already absent before the tag; the widened line must not have turned any of
#    them into something that parses. The trailing-junk case is the one the
#    script's own comment singles out, restated for the three-field shape.
# ---------------------------------------------------------------------------
corrupt_ok=1
corrupt_detail=""
check_absent() { # <label> <content>
	run_gate check "$2"
	if [ "$RC" = 0 ] && [ "${OUT#PROCEED}" != "$OUT" ]; then
		return 0
	fi
	corrupt_ok=0
	corrupt_detail="$corrupt_detail [$1 rc=$RC out=$OUT]"
	return 1
}
check_absent "trailing junk" "$KIND $KEY_SHA 2 extra
"
check_absent "two lines" "$KIND $KEY_SHA 2
$KIND $KEY_SHA 2
"
check_absent "empty file" ""
check_absent "short sha" "$KIND ${KEY_SHA%??????} 2
"
check_absent "non-hex sha" "$KIND zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz 2
"
check_absent "non-numeric count" "$KIND $KEY_SHA two
"
check_absent "count field missing" "$KIND $KEY_SHA
"
check_absent "uppercase kind" "$(printf '%s' "$KIND" | tr '[:lower:]' '[:upper:]') $KEY_SHA 2
"
if [ "$corrupt_ok" = 1 ]; then
	report ok "every previously-corrupt marker shape is still absent under the three-field format"
else
	report FAIL "every previously-corrupt marker shape is still absent under the three-field format" "$corrupt_detail"
fi

# ---------------------------------------------------------------------------
# 9. PEEK DOES NOT MIGRATE. The read-only form reports the same PROCEED over a
#    legacy marker and leaves the file byte-identical. `peek` exists so a human can
#    inspect the lane without consuming a pass; silently rewriting the marker into
#    the new format would consume the changeover instead — the operator's next
#    `check` would then see a tagged marker nobody's pass wrote.
# ---------------------------------------------------------------------------
run_gate peek "$HEAD_SHA 2
"
if [ "$RC" = 0 ] && [ "${OUT#PROCEED}" != "$OUT" ] && [ "$(marker)" = "$HEAD_SHA 2" ]; then
	report ok "peek reads a legacy marker as absent without rewriting it"
else
	report FAIL "peek reads a legacy marker as absent without rewriting it" "rc=$RC out=$OUT marker=$(marker)"
fi

echo
echo "refactor-scan-gate marker self-test ($SH): $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
