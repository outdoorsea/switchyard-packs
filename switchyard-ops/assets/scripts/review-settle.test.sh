#!/usr/bin/env bash
#
# Self-test for the SETTLED LEDGER half of
# packs/switchyard-ops/assets/scripts/review-sweep.sh — what a finished
# review's settled marker records, and when a verdict carries across a rebase.
#
# THE VERIFICATION CONTRACT
# -------------------------
#   "A finished review settles the exact head it judged, recording the verdict
#    and the content's patch-id — and a later head that is CONTENT-IDENTICAL
#    (a clean rebase after the base moved) inherits that verdict instead of
#    being re-reviewed, while a head whose content actually changed is
#    reviewed fresh."
#
# WHY THIS IS GUARDED. The failure it pins was a live token-burn loop
# (observed 2026-08-21): pr-refresh rebases open PRs whenever the base moves;
# a rebase rewrites committer dates, so the standing reject comment predates
# the new head's last commit; review-sweep re-dispatched a full review of
# byte-identical content, which rejected again, forever — one full review's
# tokens per base move, per rejected PR. The fix rests on `git patch-id
# --stable`, which ignores line numbers, so both directions must be pinned:
# same content -> same id -> verdict carries; changed content -> different id
# -> fresh review. A suite that asserted only the first would pass a sweep
# that never reviews a rebased PR again at all.
#
# The suite builds REAL repositories (a bare origin carrying refs/pull/N/head,
# a rig clone, real rebases) because the claims under test are claims about
# git — integration-lane.test.sh's rule. gc and gh are stubs. Needs jq and git
# (skips without them).
#
# Named review-settle (not review-sweep) deliberately: it pins the SETTLE
# LEDGER half of review-sweep.sh, and a sibling suite covering the lane's
# dispatch throughput can exist beside it without the two colliding on a name.
#
# Run:  bash packs/switchyard-ops/assets/scripts/review-settle.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SWEEP="$HERE/review-sweep.sh"

for tool in jq git; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "SKIP — review-sweep self-test needs $tool (not on PATH)"
		exit 0
	fi
done

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

# ---------------------------------------------------------------------------
# Fixtures. Every case builds a FRESH city with a real origin + rig clone.
# ---------------------------------------------------------------------------

# new_city — scaffold a throwaway city: a bare origin with a `staging` base
# and one PR branch published at refs/pull/5/head, a rig clone of it, and
# stub gc/gh. Echoes the city path; the current PR head sha lands in
# $city/head.
new_city() {
	local city work sha
	city="$(mktemp -d)"
	mkdir -p "$city/bin" "$city/state"

	git init -q --bare "$city/origin.git"
	git -C "$city/origin.git" symbolic-ref HEAD refs/heads/staging
	work="$city/seed"
	git init -q "$work"
	git -C "$work" config user.email review-sweep-test@example.invalid
	git -C "$work" config user.name "review-sweep test"
	git -C "$work" checkout -q -b staging
	echo base >"$work/f.txt"
	git -C "$work" add f.txt && git -C "$work" commit -qm "base"
	git -C "$work" remote add origin "$city/origin.git"
	git -C "$work" push -q origin staging
	git -C "$work" checkout -q -b feat
	echo change >"$work/g.txt"
	git -C "$work" add g.txt && git -C "$work" commit -qm "feat work"
	git -C "$work" push -q origin feat
	sha="$(git -C "$work" rev-parse feat)"
	git -C "$city/origin.git" update-ref refs/pull/5/head "$sha"
	printf '%s' "$sha" >"$city/head"

	git clone -q "$city/origin.git" "$city/rigA"

	jq -n --arg p "$city/rigA" '[{"name":"rigA","path":$p}]' >"$city/rigs.json"
	cat >"$city/sessions.json" <<'JSON'
{"sessions":[{"template":"rigA/switchyard-ops.reviewer","alias":"rigA-reviewer-adhoc-stub","state":"active"}]}
JSON
	echo '{"agents":[]}' >"$city/agents.json"

	cat >"$city/bin/gc" <<'STUB'
#!/bin/sh
case "$1 $2" in
"rig list") cat "$GC_CITY/rigs.json" ;;
"agent list") cat "$GC_CITY/agents.json" ;;
"session list") cat "$GC_CITY/sessions.json" ;;
"session nudge")
	printf 'NUDGE %s\n' "$3" >>"$GC_CITY/nudged.log"
	printf '%s\n' "$4" >>"$GC_CITY/nudged.log"
	;;
"session new") printf 'SPAWN %s\n' "$3" >>"$GC_CITY/spawned.log" ;;
"mail send")
	subj=""
	while [ $# -gt 0 ]; do
		case "$1" in
		-s | --subject) subj="$2"; shift 2 ;;
		-m | --body) shift 2 ;;
		*) shift ;;
		esac
	done
	printf 'SUBJ %s\n' "$subj" >>"$GC_CITY/mailed.log"
	;;
esac
exit 0
STUB

	cat >"$city/bin/gh" <<'STUBGH'
#!/bin/sh
case "$1 $2" in
"pr list") cat "$GC_CITY/prlist.json" ;;
"pr view") cat "$GC_CITY/prview-$3.json" 2>/dev/null ;;
esac
exit 0
STUBGH

	chmod +x "$city/bin/gc" "$city/bin/gh"

	set_pr_fixtures "$city"
	printf '%s' "$city"
}

# set_pr_fixtures CITY — (re)write the gh fixtures from the CURRENT PR head in
# $CITY/head: one open PR #5 against staging, one non-merge commit, no
# comments yet. Cases layer verdict comments on with reject()/approve().
set_pr_fixtures() {
	local sha
	sha="$(cat "$1/head")"
	jq -n --arg h "$sha" \
		'[{"number":5,"isDraft":false,"labels":[],"createdAt":"2026-08-01T00:00:00Z",
		   "headRefOid":$h,"reviewDecision":""}]' >"$1/prlist.json"
	jq -n \
		'{"comments":[],
		  "commits":[{"messageHeadline":"feat work","committedDate":"2026-08-01T00:00:00Z"}],
		  "statusCheckRollup":[]}' >"$1/prview-5.json"
}

# verdict CITY BODY_PREFIX AT — post a marker-comment verdict on PR #5.
verdict() {
	local t
	t="$(mktemp)"
	jq --arg b "$2

reviewed at some head" --arg at "$3" \
		'.comments += [{"createdAt":$at,"body":$b,"author":{"login":"stub-reviewer"}}]' \
		"$1/prview-5.json" >"$t" && mv "$t" "$1/prview-5.json" || rm -f "$t"
}

# rebase_pr CITY — advance staging in the origin, cleanly rebase the PR branch
# onto it (content-preserving), republish refs/pull/5/head, and refresh the gh
# fixtures with the new head and a FRESH commit date — the exact state
# pr-refresh leaves behind, where the standing verdict predates the head.
rebase_pr() {
	local work sha
	work="$1/seed"
	git -C "$work" checkout -q staging
	echo more >>"$work/f.txt"
	git -C "$work" add f.txt && git -C "$work" commit -qm "staging moves"
	git -C "$work" push -q origin staging
	git -C "$work" checkout -q feat
	git -C "$work" rebase -q staging
	git -C "$work" push -qf origin feat
	sha="$(git -C "$work" rev-parse feat)"
	git -C "$1/origin.git" update-ref refs/pull/5/head "$sha"
	printf '%s' "$sha" >"$1/head"
	set_pr_fixtures "$1"
	local t
	t="$(mktemp)"
	jq '.commits[0].committedDate = "2026-08-10T00:00:00Z"' "$1/prview-5.json" >"$t" &&
		mv "$t" "$1/prview-5.json" || rm -f "$t"
}

# amend_pr CITY — change the PR's CONTENT (a new head whose diff differs),
# republish, refresh fixtures with a fresh commit date.
amend_pr() {
	local work sha
	work="$1/seed"
	git -C "$work" checkout -q feat
	echo different >>"$work/g.txt"
	git -C "$work" add g.txt && git -C "$work" commit -qm "actually new content"
	git -C "$work" push -qf origin feat
	sha="$(git -C "$work" rev-parse feat)"
	git -C "$1/origin.git" update-ref refs/pull/5/head "$sha"
	printf '%s' "$sha" >"$1/head"
	set_pr_fixtures "$1"
	local t
	t="$(mktemp)"
	jq '.commits[0].committedDate = "2026-08-10T00:00:00Z"' "$1/prview-5.json" >"$t" &&
		mv "$t" "$1/prview-5.json" || rm -f "$t"
}

# settled_file CITY — the settled-marker path for the CURRENT head, using the
# sweep's own key transform (slug = the origin URL with .git stripped).
settled_file() {
	printf '%s/state/review-assignments/%s.settled' "$1" \
		"$(printf '%s' "$1/origin#5@$(cat "$1/head")" | tr -c 'A-Za-z0-9' '-')"
}

REVIEW_TEST_SH="${REVIEW_TEST_SH:-sh}"

# run_sweep CITY — one sweep cycle. Grace is 0: these cases are about the
# settle ledger, not the primary-reviewer handoff.
run_sweep() {
	printf 'REVIEW_LANE_RIGS="rigA"\nREVIEW_LANE_GRACE_SECONDS="0"\n' >"$1/state/roster.conf"
	GC_CITY="$1" \
		GC_PACK_STATE_DIR="$1/state" \
		PATH="$1/bin:$PATH" \
		"$REVIEW_TEST_SH" "$SWEEP" >/dev/null 2>&1
}

nudges() {
	local n
	[ -f "$1/nudged.log" ] || { echo 0; return 0; }
	n="$(grep -c '^NUDGE ' "$1/nudged.log" 2>/dev/null)"
	echo "${n:-0}"
}

# ---------------------------------------------------------------------------
# 1. POSITIVE CONTROL — an unreviewed PR still dispatches a review. Without
#    this, every no-dispatch assertion below is satisfiable by a sweep that
#    dispatches nothing at all.
# ---------------------------------------------------------------------------
c="$(new_city)"
run_sweep "$c"
n="$(nudges "$c")"
if [ "$n" = 1 ] && grep -q '^REVIEW ' "$c/nudged.log" 2>/dev/null; then
	report ok "an unreviewed PR dispatches exactly one review"
else
	report FAIL "an unreviewed PR dispatches exactly one review" "nudged $n"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 2. A FINISHED REVIEW SETTLES WITH VERDICT + PATCH-ID. The verdict is what
#    pr-rework-sweep reads to see a rejected rebased head; the patch-id is
#    what lets the verdict carry. An empty touch-file records neither.
# ---------------------------------------------------------------------------
c="$(new_city)"
verdict "$c" "Verdict: REQUEST CHANGES" "2026-08-02T00:00:00Z"
run_sweep "$c"
sf="$(settled_file "$c")"
want_pid="$(git -C "$c/rigA" fetch -q origin staging 2>/dev/null
	git -C "$c/rigA" diff "origin/staging...$(cat "$c/head")" | git patch-id --stable | awk '{print $1}')"
got_v="$(awk 'NR==1{print $2}' "$sf" 2>/dev/null)"
got_pid="$(awk 'NR==1{print $3}' "$sf" 2>/dev/null)"
if [ "$(nudges "$c")" = 0 ] && [ "$got_v" = "reject" ] && [ -n "$want_pid" ] && [ "$got_pid" = "$want_pid" ]; then
	report ok "a standing reject settles its head with the verdict and the content's patch-id"
else
	report FAIL "a standing reject settles its head with the verdict and the content's patch-id" \
		"nudged $(nudges "$c"), marker: $(cat "$sf" 2>/dev/null || echo missing), want pid $want_pid"
fi

# ---------------------------------------------------------------------------
# 3. THE VERDICT CARRIES ACROSS A CONTENT-IDENTICAL REBASE. Same city: the
#    base moves, pr-refresh's rebase mints a new head whose committer date
#    postdates the reject — the exact token-burn state. NO review may be
#    dispatched, and the new head must be settled as rejected so
#    pr-rework-sweep sees a standing reject on it.
# ---------------------------------------------------------------------------
rebase_pr "$c"
run_sweep "$c"
sf2="$(settled_file "$c")"
got_v2="$(awk 'NR==1{print $2}' "$sf2" 2>/dev/null)"
if [ "$(nudges "$c")" = 0 ] && [ "$got_v2" = "reject" ]; then
	report ok "a content-identical rebased head inherits the reject instead of a re-review"
else
	report FAIL "a content-identical rebased head inherits the reject instead of a re-review" \
		"nudged $(nudges "$c"), marker: $(cat "$sf2" 2>/dev/null || echo missing)"
fi

# ---------------------------------------------------------------------------
# 4. CHANGED CONTENT IS REVIEWED FRESH. Same city again: a head whose diff
#    actually differs must NOT inherit the verdict — that would let a wrong
#    fix (or an unrelated change) ride a stale reject past review forever.
# ---------------------------------------------------------------------------
amend_pr "$c"
run_sweep "$c"
n="$(nudges "$c")"
sf3="$(settled_file "$c")"
if [ "$n" = 1 ] && [ ! -f "$sf3" ]; then
	report ok "a head with changed content is dispatched for a fresh review"
else
	report FAIL "a head with changed content is dispatched for a fresh review" \
		"nudged $n, marker: $(cat "$sf3" 2>/dev/null || echo absent)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 5. AN OLD-STYLE EMPTY SETTLED MARKER DEGRADES TO A REVIEW, NEVER A CRASH OR
#    A WRONG CARRY. Markers written before verdicts were recorded are empty;
#    a rebase behind one must fall through to a normal dispatch.
# ---------------------------------------------------------------------------
c="$(new_city)"
verdict "$c" "Verdict: REQUEST CHANGES" "2026-08-02T00:00:00Z"
mkdir -p "$c/state/review-assignments"
: >"$(settled_file "$c")" # the pre-change shape: an empty touch-file
rebase_pr "$c"
run_sweep "$c"
n="$(nudges "$c")"
if [ "$n" = 1 ]; then
	report ok "an empty legacy settled marker falls through to a fresh review"
else
	report FAIL "an empty legacy settled marker falls through to a fresh review" "nudged $n"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 6. AN APPROVE SETTLES AS approve — the ledger must not collapse the two
#    verdicts, or pr-rework-sweep would dispatch rework onto approved heads
#    after every rebase. AND AN APPROVE NEVER CARRIES ACROSS A REBASE:
#    merge-lane's approve evidence is a comment newer than the head's last
#    commit (it does not read this ledger), so a carried approve would
#    suppress exactly the re-dispatch that regenerates the mergeable
#    evidence — the PR would sit settled-approved, unmergeable and
#    un-re-reviewable, until the marker prune. The rebased approved head must
#    be dispatched for a fresh review instead.
# ---------------------------------------------------------------------------
c="$(new_city)"
verdict "$c" "Verdict: APPROVE" "2026-08-02T00:00:00Z"
run_sweep "$c"
got_v="$(awk 'NR==1{print $2}' "$(settled_file "$c")" 2>/dev/null)"
if [ "$(nudges "$c")" = 0 ] && [ "$got_v" = "approve" ]; then
	report ok "a standing approve settles its head as approve"
else
	report FAIL "a standing approve settles its head as approve" \
		"nudged $(nudges "$c"), verdict: ${got_v:-missing}"
fi
rebase_pr "$c"
run_sweep "$c"
n="$(nudges "$c")"
sf_ap="$(settled_file "$c")"
if [ "$n" = 1 ] && [ ! -f "$sf_ap" ]; then
	report ok "a content-identical rebase of an APPROVED head is re-dispatched, never carried"
else
	report FAIL "a content-identical rebase of an APPROVED head is re-dispatched, never carried" \
		"nudged $n, marker: $(cat "$sf_ap" 2>/dev/null || echo absent)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 7. ONE PATCH-ID, TWO VERDICTS — THE NEWEST WINS. The same content can be
#    rejected at head A, carried to head B, and then APPROVED at B after a
#    re-review: three markers, one patch-id, two different verdicts. The glob
#    is lexicographic over a tr'd sha, so a first-match lookup could hand back
#    the SUPERSEDED reject and route rework onto content a reviewer has since
#    approved. The latest judgment of a given content stands — and because an
#    approve never carries, resolving to approve falls through to a fresh
#    dispatch, the safe direction.
# ---------------------------------------------------------------------------
c="$(new_city)"
verdict "$c" "Verdict: REQUEST CHANGES" "2026-08-02T00:00:00Z"
run_sweep "$c" # settles head A as reject, with a patch-id
pid="$(awk 'NR==1{print $3}' "$(settled_file "$c")" 2>/dev/null)"
# A LATER marker for the same content carrying the opposite verdict. Its key
# names a head that sorts AFTER any real sha — `z` outranks every hex digit —
# so the glob reaches the REJECT first. That ordering is the whole point: with
# a first-match lookup the stale reject wins and this case fails, which is what
# makes it a guard rather than a restatement of the glob's accidental order.
printf '9999999999 approve %s\n' "$pid" \
	>"$c/state/review-assignments/$(printf '%s' "$c/origin#5@zlaterhead" | tr -c 'A-Za-z0-9' '-').settled"
rebase_pr "$c"
rm -f "$c/nudged.log"
run_sweep "$c"
sf7="$(settled_file "$c")"
carried="$(awk 'NR==1{print $2}' "$sf7" 2>/dev/null)"
if [ "$carried" != "reject" ] && [ "$(nudges "$c")" = 1 ]; then
	report ok "a superseded reject does not win the patch-id tie against a newer approve"
else
	report FAIL "a superseded reject does not win the patch-id tie against a newer approve" \
		"carried '$carried', nudged $(nudges "$c") (want: not reject, 1 dispatch)"
fi
rm -rf "$c"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
