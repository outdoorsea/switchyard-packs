#!/usr/bin/env bash
#
# Self-test for packs/switchyard-ops/assets/scripts/refactor-scan-gate.sh — the
# refactor-scout lane's IN-SESSION pass gate.
#
# THE VERIFICATION CONTRACT
# -------------------------
#   "refactor-scan-gate.sh keys its marker on the repo's tree object rather than
#    the commit sha, so two commits with byte-identical trees share one pass
#    allowance instead of receiving one each"
#
# WHY A SHA KEY WAS THE WRONG KEY (switchyard PRD #413). The gate's premise is
# about CONTENT — the scout prompt's own wording is that an unmoved repo means "a
# scan now re-derives the same ranking from the same history". The commit sha
# stood in for that, and it stops standing in for it on exactly the commit kind
# this fleet produces most: across switchyard-forge's 207 commits, 80 are merges
# and 42 of those (52.5%) have a tree byte-identical to a parent. The symptom is
# not a skipped pass, it is a LOST RESET — a tree appearing under N shas was
# authorised 2N passes instead of 2. One measured instance ran three passes
# against a ceiling of two.
#
# So the assertions below are about the ALLOWANCE SURVIVING A NEW COMMIT SHA, and
# they are written on exit codes plus the marker file, never on the verdict text
# alone: a gate that prints SKIP and exits 0 authorises the pass anyway, and that
# failure is invisible to a stdout-only assertion. The scout branches on the exit
# code (0 = run, 10 = stop), so the exit code is the actual contract.
#
# Two shapes of tree-identical commit are pinned separately, because they fail
# differently under a sha key and one is far easier to dismiss as exotic:
#
#   THE EMPTY / MESSAGE-ONLY COMMIT is the minimal case — same tree, new sha,
#   nothing else moving. If this one resets the count, the key is not content.
#
#   THE MERGE is the case that actually spends the money here, and it is the one
#   a fixture is tempted to skip because it needs three commits and a branch. It
#   is included in full: a marker stamped at a branch tip, then a --no-ff merge of
#   that branch whose tree equals it byte for byte. Its assertions reach the pass
#   COUNT the marker still holds, not just the refusal the gate printed — the
#   difference is a gate that refuses once and re-arms, which leaks the PRD's 2N
#   passes one call later and is invisible to an exit-code-only case.
#
# The negative controls matter as much: a real content change MUST re-arm the
# gate, and a never-scanned repo MUST proceed. Without them, "the count did not
# reset" is also satisfied by a gate that has quietly stopped authorising
# anything — which is the failure the gate's own header calls out as invisible,
# because a lane that never runs can never report that it isn't running.
#
# It runs hermetically: throwaway state dirs and real git repos (the gate reads a
# real tree, so a faked one would test the fixture). No city, session or
# switchyard instance is involved. Needs git.
#
# The gate is POSIX sh and ships to cities that are not Ubuntu, so CI runs this
# suite a second time under dash via GATE_TEST_SH — the same knob as the sibling
# suites (REFACTOR_TEST_SH, BALANCE_TEST_SH, REVIEW_TEST_SH).
#
# Run:  bash packs/switchyard-ops/assets/scripts/refactor-scan-gate.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/refactor-scan-gate.sh"
PACK="$HERE/../.."

if ! command -v git >/dev/null 2>&1; then
	echo "SKIP — refactor-scan-gate self-test needs git (not on PATH)"
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

# Substring assertions with NO pipeline — `printf | grep -q` under pipefail
# SIGPIPEs its producer on the success path; herestrings cannot.
has() { grep -q -- "$2" <<<"$1"; }

GATE_TEST_SH="${GATE_TEST_SH:-sh}"

# ---------------------------------------------------------------------------
# Fixtures. Every case builds a FRESH state dir: the gate's whole subject is
# cross-pass state, so a dir reused across cases would let a later case pass on
# an earlier case's marker rather than its own.
# ---------------------------------------------------------------------------

# new_repo DIR — a real git repo with one commit. The gate resolves a real tree.
new_repo() {
	mkdir -p "$1"
	git -C "$1" init -q 2>/dev/null
	git -C "$1" config user.email t@t.test
	git -C "$1" config user.name t
	echo seed >"$1/f"
	git -C "$1" add f
	git -C "$1" commit -qm seed
}

# commit_content DIR — a commit that CHANGES the tree. The re-arming signal.
commit_content() {
	echo "$RANDOM$RANDOM" >>"$1/f"
	git -C "$1" add f
	git -C "$1" commit -qm move
}

# commit_same_tree DIR — a new commit sha over a byte-identical tree. This is
# the whole subject of this suite in one line: under the old key it reset the
# allowance, under the new key it must not.
commit_same_tree() {
	git -C "$1" commit -q --allow-empty -m "message only $RANDOM"
}

new_state() { mktemp -d; }

# run_gate STATE MODE RIG REPO — one gate call, via the named shell. Prints the
# verdict; the caller reads $? for the decision that actually binds.
run_gate() {
	GC_PACK_STATE_DIR="$1" GC_PACK_DIR="$PACK" \
		"$GATE_TEST_SH" "$GATE" "$2" "$3" "$4" 2>&1
}

marker() { cat "$1/refactor-scan.$2.state" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 1. NEVER SCANNED PROCEEDS — the positive control. Without it every "the
#    allowance was not reset" assertion below is also satisfied by a gate that
#    has stopped authorising anything at all.
# ---------------------------------------------------------------------------
state="$(new_state)"; repo="$state/rigA"; new_repo "$repo"
out="$(run_gate "$state" check rigA "$repo")"; rc=$?
if [ "$rc" -eq 0 ] && has "$out" PROCEED; then
	report ok "a never-scanned repo proceeds"
else
	report FAIL "a never-scanned repo proceeds" "rc=$rc out=$out"
fi

# ---------------------------------------------------------------------------
# 2. THE MARKER HOLDS THE TREE. Asserted against `rev-parse` directly, because
#    a commit sha and a tree sha are both 40 hex characters: a marker keyed on
#    the wrong one is indistinguishable from a correct one by inspection, and
#    every behavioural case below would still pass on a repo whose history was
#    linear. This is the case that names WHICH object the key is.
# ---------------------------------------------------------------------------
want_tree="$(git -C "$repo" rev-parse "HEAD^{tree}")"
head_sha="$(git -C "$repo" rev-parse HEAD)"
got="$(marker "$state" rigA)"
if [ "$got" = "tree $want_tree 1" ]; then
	report ok "the stamped marker holds the tree object, not the commit sha"
else
	report FAIL "the stamped marker holds the tree object, not the commit sha" \
		"marker=[$got] tree=$want_tree head=$head_sha"
fi
rm -rf "$state"

# ---------------------------------------------------------------------------
# 3. THE CORE CASE: a new commit sha over an identical tree SHARES the
#    allowance. Three passes are attempted across three distinct commit shas.
#    Under the old commit key, pass 3 would be "pass 1 at a new sha" and would
#    proceed — the lost reset, worth 2N passes per tree. Under the tree key the
#    third must be refused with exit 10.
# ---------------------------------------------------------------------------
state="$(new_state)"; repo="$state/rigA"; new_repo "$repo"
run_gate "$state" check rigA "$repo" >/dev/null; rc1=$?
commit_same_tree "$repo"
out2="$(run_gate "$state" check rigA "$repo")"; rc2=$?
commit_same_tree "$repo"
out3="$(run_gate "$state" check rigA "$repo")"; rc3=$?
if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$rc3" -eq 10 ]; then
	report ok "two commits with identical trees share one allowance (third pass refused)"
else
	report FAIL "two commits with identical trees share one allowance (third pass refused)" \
		"rc=$rc1/$rc2/$rc3 out2=$out2 out3=$out3"
fi
# The second pass must be counted as the SECOND, not re-started as a first. A
# gate that reset the count and happened to skip for another reason would pass
# the exit-code assertion above while still leaking the allowance.
if has "$out2" "pass 2"; then
	report ok "the pass at the second commit counts as pass 2 of the allowance"
else
	report FAIL "the pass at the second commit counts as pass 2 of the allowance" "$out2"
fi

# ---------------------------------------------------------------------------
# 4. THE SKIP STAYS LEGIBLE. The gate now refuses at a commit sha it has never
#    seen, which reads as a bug unless the verdict says so. It must name the
#    commit a human recognises AND the tree it actually judged on.
# ---------------------------------------------------------------------------
skip_head="$(git -C "$repo" rev-parse HEAD)"
skip_tree="$(git -C "$repo" rev-parse "HEAD^{tree}")"
if has "$out3" "$skip_head" && has "$out3" "$skip_tree"; then
	report ok "the SKIP verdict names both the commit sha and the tree"
else
	report FAIL "the SKIP verdict names both the commit sha and the tree" \
		"head=$skip_head tree=$skip_tree out=$out3"
fi

# ---------------------------------------------------------------------------
# 5. A REAL CONTENT CHANGE RE-ARMS. The other half of the contract: keying on
#    content must not mean keying on nothing. Same exhausted state dir.
# ---------------------------------------------------------------------------
commit_content "$repo"
out="$(run_gate "$state" check rigA "$repo")"; rc=$?
if [ "$rc" -eq 0 ] && has "$out" PROCEED; then
	report ok "a commit that changes the tree re-arms the gate"
else
	report FAIL "a commit that changes the tree re-arms the gate" "rc=$rc out=$out"
fi
rm -rf "$state"

# ---------------------------------------------------------------------------
# 6. THE MERGE CASE — 52.5% of this fleet's merges, and the reason the PRD
#    exists. The marker is stamped to exhaustion at a branch tip; HEAD then
#    becomes a --no-ff merge commit whose tree is byte-identical to that tip.
#    A sha-keyed gate sees an unseen sha and hands out a fresh pair of passes.
#
#    PINNED ON THE COUNT, NOT ONLY THE VERDICT. One refusal is the cheap half of
#    this case, and asserting it alone leaves the PRD's actual symptom uncovered:
#    a gate that answers SKIP and then re-arms its own marker leaks the same 2N
#    passes per tree, just one call later. That mutant — a `gate_stamp 0` on the
#    refusal path — passes an exit-code-only version of this case while running
#    UNBOUNDED passes at one tree, because each refusal hands the next call a
#    fresh allowance. So the count is read where it lives, in the marker, and the
#    refusal is exercised twice to show it is a standing verdict rather than a
#    one-shot. The marker is compared against the one the exhausted tip left,
#    which states "not reset" without restating the allowance's default.
# ---------------------------------------------------------------------------
state="$(new_state)"; repo="$state/rigA"; new_repo "$repo"
base="$(git -C "$repo" symbolic-ref --short HEAD)"
git -C "$repo" checkout -q -b side
commit_content "$repo"
tip_tree="$(git -C "$repo" rev-parse "HEAD^{tree}")"
run_gate "$state" check rigA "$repo" >/dev/null   # pass 1 at the tip
run_gate "$state" check rigA "$repo" >/dev/null   # pass 2 — allowance spent
tip_marker="$(marker "$state" rigA)"
git -C "$repo" checkout -q "$base"
git -C "$repo" merge -q --no-ff -m merge side
merge_tree="$(git -C "$repo" rev-parse "HEAD^{tree}")"
out="$(run_gate "$state" check rigA "$repo")"; rc=$?
after_marker="$(marker "$state" rigA)"
# A second refusal at the same merge HEAD. Under a gate that reset the count on
# the way out, THIS is the call that proceeds — the leak, in the only place it
# is observable from outside.
out2="$(run_gate "$state" check rigA "$repo")"; rc2=$?
# The fixture is only testing the PRD's case if the merge really is tree-identical
# AND the tip really did exhaust the allowance. Either one silently untrue turns
# every assertion below into a tautology.
#
# The exhaustion guard reads the COUNT FIELD alone, deliberately, and not the
# whole marker: which object the key is belongs to case 2, and a guard that also
# demanded the tree here would fire on a sha-keyed regression — swallowing this
# case's own verdict behind "your fixture is broken" on the one regression it
# exists to name.
tip_n="${tip_marker##* }"
if [ "$merge_tree" != "$tip_tree" ]; then
	report FAIL "the merge fixture produces a tree-identical merge commit" \
		"tip=$tip_tree merge=$merge_tree — fixture is not testing the PRD's case"
elif [ "$tip_n" != 2 ]; then
	report FAIL "the merge fixture exhausts the allowance at the branch tip" \
		"marker=[$tip_marker] want count 2 — fixture is not testing the PRD's case"
else
	if [ "$rc" -eq 10 ]; then
		report ok "a merge commit whose tree equals its parent's does not reset the count"
	else
		report FAIL "a merge commit whose tree equals its parent's does not reset the count" \
			"rc=$rc out=$out"
	fi
	if [ "$after_marker" = "$tip_marker" ]; then
		report ok "the refused merge leaves the marker's tree and count exactly as the tip left them"
	else
		report FAIL "the refused merge leaves the marker's tree and count exactly as the tip left them" \
			"after=[$after_marker] tip=[$tip_marker]"
	fi
	if [ "$rc2" -eq 10 ]; then
		report ok "the merge is refused again on the next call — the refusal does not re-arm the gate"
	else
		report FAIL "the merge is refused again on the next call — the refusal does not re-arm the gate" \
			"rc=$rc2 out=$out2"
	fi
fi
rm -rf "$state"

# ---------------------------------------------------------------------------
# 7. `peek` STILL DOES NOT STAMP. The read-only form is what an operator uses to
#    inspect the lane by hand, and a peek that consumed an allowance would spend
#    the lane's budget on debugging it.
# ---------------------------------------------------------------------------
state="$(new_state)"; repo="$state/rigA"; new_repo "$repo"
run_gate "$state" peek rigA "$repo" >/dev/null; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$(marker "$state" rigA)" ]; then
	report ok "peek proceeds without stamping a pass"
else
	report FAIL "peek proceeds without stamping a pass" "rc=$rc marker=[$(marker "$state" rigA)]"
fi
rm -rf "$state"

# ---------------------------------------------------------------------------
# 8. FAIL OPEN when the tree is unreadable. Resolving `HEAD^{tree}` is one more
#    thing that can fail than resolving HEAD was, so the fail-open branch is
#    re-pinned rather than assumed to have survived the key change.
# ---------------------------------------------------------------------------
state="$(new_state)"; repo="$state/rigA"; new_repo "$repo"; rm -rf "$repo/.git"
out="$(run_gate "$state" check rigA "$repo")"; rc=$?
if [ "$rc" -eq 0 ] && has "$out" PROCEED; then
	report ok "a repo with no resolvable tree fails OPEN"
else
	report FAIL "a repo with no resolvable tree fails OPEN" "rc=$rc out=$out"
fi
rm -rf "$state"

# ---------------------------------------------------------------------------
# 9. CHANGEOVER. A marker left by the previous, commit-keyed build is an
#    untagged two-field line holding a commit sha. It must not be read as
#    "already scanned"; the worst it may cost is one extra authorised pass, once
#    per rig, which is the direction this gate is allowed to fail in.
#
#    This case is the end-to-end shape only. WHY it is absent — by the key-kind
#    tag, a rule, rather than by the commit and tree hashes happening to differ —
#    is pinned in refactor-scan-gate-marker.test.sh, which is the suite that can
#    tell those two apart.
# ---------------------------------------------------------------------------
state="$(new_state)"; repo="$state/rigA"; new_repo "$repo"
printf '%s %s\n' "$(git -C "$repo" rev-parse HEAD)" 2 >"$state/refactor-scan.rigA.state"
out="$(run_gate "$state" check rigA "$repo")"; rc=$?
if [ "$rc" -eq 0 ] && has "$out" PROCEED; then
	report ok "a marker written under the old commit-sha key does not answer SKIP"
else
	report FAIL "a marker written under the old commit-sha key does not answer SKIP" "rc=$rc out=$out"
fi
rm -rf "$state"

# ---------------------------------------------------------------------------
echo
echo "refactor-scan-gate self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
