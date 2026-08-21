#!/usr/bin/env bash
#
# Self-test for packs/switchyard-ops/assets/scripts/review-sweep.sh — the
# fallback reviewer's dispatcher.
#
# THE VERIFICATION CONTRACT
# -------------------------
#   "Each qualified open PR is dispatched to exactly one reviewer, and a
#    reviewer reads busy only while its assigned PR is still open without a
#    verdict."
#
# The second clause is the one this suite exists for, because its cheap wrong
# version passed every happy-path read for weeks: busy-ness is derived from
# assignment markers in the state dir, and the settle loop that clears them
# early iterates only PRs still OPEN against the lane base. A PR approved and
# then MERGED by merge-lane leaves that list, so its marker never settled and
# its reviewer read busy for the full REVIEW_ASSIGNMENT_TTL (90 min) while
# sitting idle — dispatch moved in waves exactly one TTL apart with qualified
# PRs waiting hours (observed 2026-08-21). Both directions are pinned:
#
#   A DEPARTED PR FREES ITS REVIEWER NOW. Merged or closed, same cycle — not
#   at TTL expiry — and by DELETING the marker, never by settling it:
#   departure is reversible (a mistaken close gets reopened, same head, same
#   key), and a durable `.settled` would suppress the returning PR's dispatch
#   for the 7-day GC window with no alarm. Only a verdict settles durably,
#   because only a verdict cannot un-happen. And a verdict on a still-OPEN PR
#   frees the reviewer too: the settled marker must stop counting toward
#   busy, not merely suppress re-dispatch of its own PR.
#
#   A LIVE ASSIGNMENT STILL SUPPRESSES. The PR is open, unreviewed, inside the
#   TTL: its own key is not re-dispatched, and its reviewer is handed nothing
#   else. Without this side, the cleanup fix could rot into "everyone is
#   always free" and put two reviewers on one PR.
#
#   AN UNTRUSTWORTHY LIST CLEARS NOTHING. Two shapes: a failed `gh pr list`
#   leaves an empty file that is NOT an empty list, and a page AT the fetch
#   limit may be a truncated view of a longer queue — mass-clearing on either
#   would free mid-review reviewers and double-dispatch their PRs. A genuinely
#   empty list (`[]`) is a real answer and clears everything. All three are
#   asserted, because they are separated only by parse success and a count.
#
#   THE TTL SURVIVES AS THE RECOVERY WINDOW. An assignment whose PR is still
#   open with no verdict past the TTL is re-dispatched — the lost-nudge case
#   the TTL exists for, deliberately not narrowed by the settle fix.
#
# It runs hermetically: a throwaway city plus stub `gc` and `gh` on PATH, and
# one real (empty) git repo per city because the sweep reads the rig's origin
# remote for its owner/repo slug. No real city, session, or forge is involved.
# Needs jq and git (skips without them).
#
# Run:  bash packs/switchyard-ops/assets/scripts/review-sweep.test.sh

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
# Fixtures. Every case builds a FRESH city: markers and nudge logs accumulate,
# and marker state across cycles is the exact subject under test — a reused
# fixture could pass a case on an earlier case's markers.
# ---------------------------------------------------------------------------

# new_city — scaffold a throwaway city plus stubs, and echo its path.
#
# One rig, `rigA`, opted into the lane, with one live reviewer session. The
# rig is a real empty git repo because the sweep derives the owner/repo slug
# from `git -C <rig> remote get-url origin` — stubbing git would blind the
# suite to that read breaking.
new_city() {
	local city
	city="$(mktemp -d)"
	mkdir -p "$city/bin" "$city/state"
	printf 'REVIEW_LANE_RIGS="rigA"\n' >"$city/state/roster.conf"

	git init -q "$city/rigA" 2>/dev/null
	git -C "$city/rigA" remote add origin "git@github.com:acme/rigA.git"

	echo '[]' >"$city/rigs.json"
	cat >"$city/agents.json" <<'JSON'
{"agents":[{"qualified_name":"rigA/switchyard-ops.reviewer","pool":{"max":2},"suspended":false}]}
JSON
	cat >"$city/sessions.json" <<'JSON'
{"sessions":[{"template":"rigA/switchyard-ops.reviewer","alias":"rigA-reviewer-1","state":"active"}]}
JSON

	# The open-PR list `gh pr list` returns; empty means no open PRs.
	echo '[]' >"$city/queue.json"

	cat >"$city/bin/gc" <<'STUB'
#!/bin/sh
case "$1 $2" in
"agent list") cat "$GC_CITY/agents.json" ;;
"rig list") cat "$GC_CITY/rigs.json" ;;
"session list") cat "$GC_CITY/sessions.json" ;;
"session nudge")
	printf 'NUDGE %s\n' "$3" >>"$GC_CITY/nudged.log"
	printf '%s\n' "$4" >>"$GC_CITY/nudged.log"
	;;
"session new") printf 'SPAWN %s\n' "$3" >>"$GC_CITY/spawned.log" ;;
"mail send")
	shift 2
	subj=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--subject) subj="$2"; shift 2 ;;
		*) shift ;;
		esac
	done
	printf 'SUBJ %s\n' "$subj" >>"$GC_CITY/mailed.log"
	;;
esac
exit 0
STUB

	# The stub honors --limit by slicing the fixture array, because the sweep's
	# truncation guard is ABOUT pagination: a stub that returned the whole
	# queue regardless would let the guard be asserted against a count that
	# can never exceed the page, i.e. against nothing.
	cat >"$city/bin/gh" <<'STUB'
#!/bin/sh
[ -f "$GC_CITY/gh-broken" ] && exit 1
case "$1 $2" in
"pr list")
	lim=""
	prev=""
	for a in "$@"; do
		[ "$prev" = "--limit" ] && lim="$a"
		prev="$a"
	done
	if [ -n "$lim" ]; then
		jq --argjson n "$lim" '.[0:$n]' "$GC_CITY/queue.json"
	else
		cat "$GC_CITY/queue.json"
	fi
	;;
"pr view") cat "$GC_CITY/meta-$3.json" 2>/dev/null || exit 1 ;;
*) exit 1 ;;
esac
exit 0
STUB

	chmod +x "$city/bin/gc" "$city/bin/gh"
	printf '%s' "$city"
}

# open_pr CITY NUM HEAD — an open, fully qualified PR: not draft, no labels,
# no reviewDecision, an old head commit (outside any grace window), no
# comments, no CI checks.
open_pr() {
	local t
	t="$(mktemp)"
	jq --argjson n "$2" --arg h "$3" \
		'. += [{"number":$n,"isDraft":false,"labels":[],"createdAt":"2026-01-01T00:00:00Z","headRefOid":$h,"reviewDecision":""}]' \
		"$1/queue.json" >"$t" && mv "$t" "$1/queue.json" || rm -f "$t"
	cat >"$1/meta-$2.json" <<'JSON'
{"comments":[],"commits":[{"messageHeadline":"work","committedDate":"2026-01-01T00:00:00Z"}],"statusCheckRollup":[]}
JSON
}

# close_pr CITY NUM — the PR leaves the open list (merged or closed).
close_pr() {
	local t
	t="$(mktemp)"
	jq --argjson n "$2" 'map(select(.number != $n))' \
		"$1/queue.json" >"$t" && mv "$t" "$1/queue.json" || rm -f "$t"
}

# verdict CITY NUM — a finished review lands as a marker comment AFTER the
# head's last commit, on a PR that stays open.
verdict() {
	local t
	t="$(mktemp)"
	jq '.comments += [{"body":"Verdict: APPROVE","createdAt":"2026-06-01T00:00:00Z"}]' \
		"$1/meta-$2.json" >"$t" && mv "$t" "$1/meta-$2.json" || rm -f "$t"
}

# marker_for CITY NUM HEAD — the assignment marker's path, derived with the
# sweep's own key recipe (slug#num@head, non-alnum -> '-').
marker_for() {
	printf '%s/state/review-assignments/%s' "$1" \
		"$(printf '%s' "acme/rigA#$2@$3" | tr -c 'A-Za-z0-9' '-')"
}

# The shell the sweep itself runs under — same knob as the sibling suites, so
# CI can run the POSIX order under dash explicitly.
REVIEW_TEST_SH="${REVIEW_TEST_SH:-sh}"

# run_sweep CITY [TTL] [LIMIT] — one sweep cycle. Grace is off: the
# primary-reviewer wait is not under test here, and leaving it on would make
# every case park its PRs behind a wall-clock comparison against fixture
# dates. LIMIT is the open-PR page size, so the full-page (possibly
# truncated) guard is testable without 100 fixture PRs.
run_sweep() {
	GC_CITY="$1" \
		GC_PACK_STATE_DIR="$1/state" \
		REVIEW_ASSIGNMENT_TTL="${2:-5400}" \
		REVIEW_LANE_LIST_LIMIT="${3:-100}" \
		REVIEW_LANE_GRACE_SECONDS=0 \
		PATH="$1/bin:$PATH" \
		"$REVIEW_TEST_SH" "$SWEEP" >/dev/null 2>&1
}

# nudges CITY — dispatches routed in total (stub NUDGE header lines; counting
# body matches would double every route). grep -c prints its 0 AND exits 1,
# so the count is captured and defaulted rather than || echo'd.
nudges() {
	local n
	[ -f "$1/nudged.log" ] || { echo 0; return 0; }
	n="$(grep -c '^NUDGE ' "$1/nudged.log" 2>/dev/null)"
	echo "${n:-0}"
}

spawns() {
	local n
	[ -f "$1/spawned.log" ] || { echo 0; return 0; }
	n="$(grep -c '^SPAWN ' "$1/spawned.log" 2>/dev/null)"
	echo "${n:-0}"
}

# set_pool_max CITY N — the reviewer agent's resolved ceiling, as
# `gc agent list --json` reports it. The balancer cap is only observable
# against a ceiling with headroom above the live pool, so the balancer cases
# below raise it above the fixture default.
set_pool_max() {
	cat >"$1/agents.json" <<JSON
{"agents":[{"qualified_name":"rigA/switchyard-ops.reviewer","pool":{"max":$2},"suspended":false}]}
JSON
}

# balancer_targets CITY BODY — publish BODY as the balancer's targets file in
# the state dir the sweep reads. BODY is written VERBATIM on purpose: a case
# asserting on a malformed file must be able to write one, which a helper that
# formatted the fields for it could not express.
balancer_targets() {
	printf '%s\n' "$2" >"$1/state/balancer.targets"
}

# ---------------------------------------------------------------------------
# 1. POSITIVE CONTROL — load-bearing. If a qualified PR did not dispatch, every
#    negative case below would pass vacuously by dispatching nothing at all.
# ---------------------------------------------------------------------------
c="$(new_city)"
open_pr "$c" 1 aaa111
run_sweep "$c"
n="$(nudges "$c")"
m="$(marker_for "$c" 1 aaa111)"
if [ "$n" = 1 ] && grep -q '^REVIEW acme/rigA#1 ' "$c/nudged.log" 2>/dev/null && [ -f "$m" ]; then
	report ok "a qualified open PR is dispatched once and its assignment marker written"
else
	report FAIL "a qualified open PR is dispatched once and its assignment marker written" \
		"nudges=$n marker=$([ -f "$m" ] && echo yes || echo no)"
fi

# The marker must name its PR in field 3 — the settle pre-pass keys on it, and
# the filename cannot carry it (tr is lossy; one slug can prefix another).
f3="$(awk 'NR==1{print $3}' "$m" 2>/dev/null)"
if [ "$f3" = "acme/rigA#1" ]; then
	report ok "the marker records slug#num as its third field"
else
	report FAIL "the marker records slug#num as its third field" "field 3 = '$f3'"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 2. A LIVE ASSIGNMENT SUPPRESSES ITS OWN PR. Open, unreviewed, inside the
#    TTL: further cycles re-dispatch nothing.
# ---------------------------------------------------------------------------
c="$(new_city)"
open_pr "$c" 1 aaa111
run_sweep "$c"
run_sweep "$c"
run_sweep "$c"
n="$(nudges "$c")"
if [ "$n" = 1 ]; then
	report ok "three cycles over one live assignment dispatch it exactly once"
else
	report FAIL "three cycles over one live assignment dispatch it exactly once" "nudges=$n"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 3. A REVIEWER MID-REVIEW IS BUSY. Its PR still open, no verdict: a second
#    candidate must not be nudged onto it (that drops the first assignment on
#    the floor) — the sweep spawns toward the pool ceiling instead.
# ---------------------------------------------------------------------------
c="$(new_city)"
open_pr "$c" 1 aaa111
run_sweep "$c"
open_pr "$c" 2 bbb222
run_sweep "$c"
n="$(nudges "$c")"
s="$(spawns "$c")"
if [ "$n" = 1 ] && [ "$s" = 1 ]; then
	report ok "a reviewer holding a live open-PR assignment is not handed a second PR"
else
	report FAIL "a reviewer holding a live open-PR assignment is not handed a second PR" \
		"nudges=$n spawns=$s"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 4. THE THROUGHPUT FIX — a MERGED PR frees its reviewer the same cycle. The
#    marker is DELETED because its PR left the open list, and the next
#    qualified PR goes to that reviewer NOW, not one TTL later.
# ---------------------------------------------------------------------------
c="$(new_city)"
open_pr "$c" 1 aaa111
run_sweep "$c"
close_pr "$c" 1 # merged by merge-lane between sweeps
open_pr "$c" 2 bbb222
run_sweep "$c"
n="$(nudges "$c")"
m="$(marker_for "$c" 1 aaa111)"
if [ "$n" = 2 ] && [ ! -f "$m" ] && [ ! -f "$m.settled" ] && grep -q '^REVIEW acme/rigA#2 ' "$c/nudged.log" 2>/dev/null; then
	report ok "a merged PR's marker is deleted and its reviewer takes the next PR same-cycle"
else
	report FAIL "a merged PR's marker is deleted and its reviewer takes the next PR same-cycle" \
		"nudges=$n marker=$([ -f "$m" ] && echo present || echo gone) settled=$([ -f "$m.settled" ] && echo yes || echo no)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 5. A VERDICT ON A STILL-OPEN PR ALSO FREES THE REVIEWER. The settled marker
#    must stop counting toward busy — not merely suppress its own PR — or every
#    COMPLETED review still idles its reviewer for the rest of the TTL.
# ---------------------------------------------------------------------------
c="$(new_city)"
open_pr "$c" 1 aaa111
run_sweep "$c"
verdict "$c" 1 # review finished; PR open, waiting on merge-lane
open_pr "$c" 2 bbb222
run_sweep "$c"
n="$(nudges "$c")"
s="$(spawns "$c")"
m="$(marker_for "$c" 1 aaa111)"
if [ "$n" = 2 ] && [ "$s" = 0 ] && [ -f "$m.settled" ]; then
	report ok "a verdict on a still-open PR frees the reviewer for the next PR"
else
	report FAIL "a verdict on a still-open PR frees the reviewer for the next PR" \
		"nudges=$n spawns=$s settled=$([ -f "$m.settled" ] && echo yes || echo no)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 6. AN EMPTY OPEN LIST IS A REAL ANSWER. `[]` parses and counts 0, so every
#    assignment for the slug is cleared even with nothing left to dispatch —
#    the reviewer is free for whatever opens next.
# ---------------------------------------------------------------------------
c="$(new_city)"
open_pr "$c" 1 aaa111
run_sweep "$c"
close_pr "$c" 1 # queue is now []
run_sweep "$c"
m="$(marker_for "$c" 1 aaa111)"
if [ ! -f "$m" ] && [ "$(nudges "$c")" = 1 ]; then
	report ok "an empty open-PR list clears the departed PR's marker"
else
	report FAIL "an empty open-PR list clears the departed PR's marker" \
		"marker=$([ -f "$m" ] && echo present || echo gone) nudges=$(nudges "$c")"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 7. A FETCH FAILURE CLEARS NOTHING. A broken `gh pr list` leaves an empty
#    file, not an empty list; clearing on it would free every busy reviewer at
#    once and double-dispatch each in-flight PR when the fetch recovers.
# ---------------------------------------------------------------------------
c="$(new_city)"
open_pr "$c" 1 aaa111
run_sweep "$c"
: >"$c/gh-broken"
run_sweep "$c"
m="$(marker_for "$c" 1 aaa111)"
if [ -f "$m" ]; then
	report ok "a failed PR-list fetch clears no assignment"
else
	report FAIL "a failed PR-list fetch clears no assignment" "marker gone"
fi
rm -f "$c/gh-broken"
run_sweep "$c" # fetch recovered, PR still open and unreviewed
if [ "$(nudges "$c")" = 1 ]; then
	report ok "the assignment survives the blip and still suppresses re-dispatch"
else
	report FAIL "the assignment survives the blip and still suppresses re-dispatch" \
		"nudges=$(nudges "$c")"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 7b. A TRUNCATED PAGE CLEARS NOTHING, AND SAYS SO. The sweep fetches one PR
#     more than the limit; a count past the limit proves the queue overflows
#     the page, so absence from it is not departure — cleanup is suspended
#     and the mayor is mailed ONCE (a standing overflow would otherwise
#     silently reinstate the one-TTL waves forever). A complete queue exactly
#     AT the limit still cleans up: the queue draining below the +1 fetch is
#     what restores trust, not draining below the limit itself.
# ---------------------------------------------------------------------------
c="$(new_city)"
open_pr "$c" 1 aaa111
run_sweep "$c"
close_pr "$c" 1 # departed for real...
open_pr "$c" 2 bbb222
open_pr "$c" 3 ccc333
open_pr "$c" 4 ddd444 # ...but 3 open PRs overflow a 2-PR page: absence is not proof
run_sweep "$c" 5400 2
run_sweep "$c" 5400 2 # a second overflow cycle must NOT mail twice
m="$(marker_for "$c" 1 aaa111)"
n_mail="$(grep -c '^SUBJ review-sweep: acme/rigA has more open PRs than one page' "$c/mailed.log" 2>/dev/null)"
if [ -f "$m" ] && [ "${n_mail:-0}" = 1 ]; then
	report ok "an overflowing open list clears no assignment and mails the mayor once"
else
	report FAIL "an overflowing open list clears no assignment and mails the mayor once" \
		"marker=$([ -f "$m" ] && echo present || echo gone) mails=${n_mail:-0}"
fi
close_pr "$c" 4 # the queue drains to exactly the limit — complete, trustworthy
run_sweep "$c" 5400 2
if [ ! -f "$m" ]; then
	report ok "a complete queue exactly at the limit clears the departed PR's marker"
else
	report FAIL "a complete queue exactly at the limit clears the departed PR's marker" "marker present"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 7c. DEPARTURE IS REVERSIBLE — a PR closed by mistake and reopened with the
#     SAME head is dispatched again. Deletion (not a durable settle) is what
#     makes this work: a `.settled` written on departure would suppress the
#     returning head for the 7-day GC window, silently.
# ---------------------------------------------------------------------------
c="$(new_city)"
open_pr "$c" 1 aaa111
run_sweep "$c"
close_pr "$c" 1 # closed by mistake
run_sweep "$c"  # marker cleared
open_pr "$c" 1 aaa111 # reopened, same head
run_sweep "$c"
n="$(nudges "$c")"
if [ "$n" = 2 ]; then
	report ok "a closed-then-reopened PR with the same head is dispatched again"
else
	report FAIL "a closed-then-reopened PR with the same head is dispatched again" "nudges=$n"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 8. THE CLEANUP PRE-PASS TOUCHES ONLY ITS OWN SLUG'S MARKERS — the state dir
#    is shared across rigs, and markers written before field 3 existed are
#    left alone (they age out on the TTL exactly as before).
# ---------------------------------------------------------------------------
c="$(new_city)"
mkdir -p "$c/state/review-assignments"
now_epoch="$(date +%s)"
printf '%s %s %s\n' "$now_epoch" "other-alias" "acme/other#5" \
	>"$c/state/review-assignments/acme-other-5-ccc333"
printf '%s %s\n' "$now_epoch" "old-alias" \
	>"$c/state/review-assignments/acme-rigA-9-ddd444"
run_sweep "$c" # rigA's open list is empty
if [ -f "$c/state/review-assignments/acme-other-5-ccc333" ] &&
	[ -f "$c/state/review-assignments/acme-rigA-9-ddd444" ]; then
	report ok "another slug's marker and a pre-field-3 marker are never cleared"
else
	report FAIL "another slug's marker and a pre-field-3 marker are never cleared" \
		"$(ls "$c/state/review-assignments" 2>/dev/null | tr '\n' ' ')"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 9. THE TTL IS STILL THE LOST-NUDGE RECOVERY WINDOW. Open PR, no verdict,
#    assignment expired: dispatched again — the settle fix must not have
#    replaced expiry as the only escape for a nudge that died.
# ---------------------------------------------------------------------------
c="$(new_city)"
open_pr "$c" 1 aaa111
run_sweep "$c" 5400
run_sweep "$c" 0 # every assignment is now older than its window
n="$(nudges "$c")"
if [ "$n" = 2 ]; then
	report ok "an expired assignment on a still-open unreviewed PR is dispatched again"
else
	report FAIL "an expired assignment on a still-open unreviewed PR is dispatched again" \
		"nudges=$n"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 10. THE BALANCER CAP (switchyard PRD #397, crit:ab69e4cb6de0).
#
#     The balancer publishes a per-lane concurrency target; this sweep must
#     honour it as a CEILING on the reviewer lane, and must fall back to
#     today's behaviour byte-for-byte when there is no target to honour.
#
#     Every case below is the same scenario — three open PRs, one live
#     reviewer, an agent ceiling of 4 — so the spawn count is the whole
#     verdict. Today's behaviour spawns TWO: demand is 2 beyond the reviewer
#     that just took a PR, and the ceiling (4) minus the live pool (1) leaves
#     room for both. A honoured target of 2 leaves room for ONE.
#
#     The fall-back cases are deliberately paired with the positive one. On
#     their own they pass VACUOUSLY — a sweep that ignores the file entirely
#     satisfies every one of them — so they are only worth their runtime
#     beside a case that proves the file is read at all.
# ---------------------------------------------------------------------------

# balancer_scenario CITY — the shared shape described above.
balancer_scenario() {
	set_pool_max "$1" 4
	open_pr "$1" 1 aaa111
	open_pr "$1" 2 bbb222
	open_pr "$1" 3 ccc333
}

now="$(date +%s)"

# 10a. A present, fresh, well-formed target CAPS the ceiling. The load-bearing
#      case: without it every fall-back below is satisfied by doing nothing.
c="$(new_city)"
balancer_scenario "$c"
balancer_targets "$c" "version 1
generated_at $now
target rigA reviewer 2"
run_sweep "$c"
s="$(spawns "$c")"
if [ "$s" = 1 ]; then
	report ok "a fresh well-formed target caps the reviewer spawn ceiling"
else
	report FAIL "a fresh well-formed target caps the reviewer spawn ceiling" \
		"spawns=$s (want 1, today's uncapped behaviour is 2)"
fi
rm -rf "$c"

# 10b. NO FILE — the control for every case above and below, and the state of
#      any city that never opted the balancer in.
c="$(new_city)"
balancer_scenario "$c"
run_sweep "$c"
s="$(spawns "$c")"
if [ "$s" = 2 ]; then
	report ok "an absent targets file leaves the reviewer ceiling at today's value"
else
	report FAIL "an absent targets file leaves the reviewer ceiling at today's value" \
		"spawns=$s (want 2)"
fi
rm -rf "$c"

# 10c. A STALE FILE STEERS NOTHING. The balancer leaves its file behind when it
#      is switched off — retiring one is this consumer's job — so a balancer
#      that died an hour ago must stop capping rather than pin the lane at its
#      last target forever.
c="$(new_city)"
balancer_scenario "$c"
balancer_targets "$c" "version 1
generated_at $((now - 100000))
target rigA reviewer 2"
run_sweep "$c"
s="$(spawns "$c")"
if [ "$s" = 2 ]; then
	report ok "a stale targets file leaves the reviewer ceiling at today's value"
else
	report FAIL "a stale targets file leaves the reviewer ceiling at today's value" \
		"spawns=$s (want 2)"
fi
rm -rf "$c"

# 10d. A FAR-FUTURE STAMP IS NOT FRESH EITHER. The freshness window is
#      symmetric: keyed only on an upper bound, a clock skewed far forward
#      pins a long-dead file as permanently current and the check never
#      expires at all.
c="$(new_city)"
balancer_scenario "$c"
balancer_targets "$c" "version 1
generated_at $((now + 100000))
target rigA reviewer 2"
run_sweep "$c"
s="$(spawns "$c")"
if [ "$s" = 2 ]; then
	report ok "a far-future targets stamp leaves the reviewer ceiling at today's value"
else
	report FAIL "a far-future targets stamp leaves the reviewer ceiling at today's value" \
		"spawns=$s (want 2)"
fi
rm -rf "$c"

# 10e. MALFORMED IS ALL-OR-NOTHING. An unknown version, a missing stamp and a
#      non-numeric target each reject the file; so does a file whose lines are
#      individually fine except for one that is not. That last shape is the
#      one worth the case: a parser that skipped the junk line would honour
#      the good one beside it and cap the lane off a contract it has already
#      failed to verify.
for body in \
	"version 2
generated_at $now
target rigA reviewer 2" \
	"version 1
target rigA reviewer 2" \
	"version 1
generated_at $now
target rigA reviewer two" \
	"version 1
generated_at $now
target rigA reviewer 2
nonsense"; do
	malformed=$((${malformed:-0} + 1))
	c="$(new_city)"
	balancer_scenario "$c"
	balancer_targets "$c" "$body"
	run_sweep "$c"
	s="$(spawns "$c")"
	if [ "$s" = 2 ]; then
		report ok "malformed targets file #$malformed leaves the reviewer ceiling at today's value"
	else
		report FAIL "malformed targets file #$malformed leaves the reviewer ceiling at today's value" \
			"spawns=$s (want 2)"
	fi
	rm -rf "$c"
done

# 10f. ANOTHER LANE'S TARGET IS NOT THIS LANE'S. A brakeman target and another
#      rig's reviewer target are both well-formed and fresh; neither says
#      anything about rigA's reviewers, and a lookup matching on too little
#      would let the balancer throttle a lane it never measured.
c="$(new_city)"
balancer_scenario "$c"
balancer_targets "$c" "version 1
generated_at $now
target rigA brakeman 1
target rigB reviewer 1"
run_sweep "$c"
s="$(spawns "$c")"
if [ "$s" = 2 ]; then
	report ok "a target for another lane or rig leaves the reviewer ceiling at today's value"
else
	report FAIL "a target for another lane or rig leaves the reviewer ceiling at today's value" \
		"spawns=$s (want 2)"
fi
rm -rf "$c"

# 10g. A TARGET ABOVE THE CEILING NEVER RAISES IT. city.toml stays the
#      operator's hard bound: the balancer turns the dial within it. Run
#      against the fixture's own ceiling of 2 (one live reviewer, so one
#      slot), where a max() in place of the min() would spawn both.
c="$(new_city)"
open_pr "$c" 1 aaa111
open_pr "$c" 2 bbb222
open_pr "$c" 3 ccc333
balancer_targets "$c" "version 1
generated_at $now
target rigA reviewer 9"
run_sweep "$c"
s="$(spawns "$c")"
if [ "$s" = 1 ]; then
	report ok "a target above the agent ceiling does not raise the reviewer ceiling"
else
	report FAIL "a target above the agent ceiling does not raise the reviewer ceiling" \
		"spawns=$s (want 1)"
fi
rm -rf "$c"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
