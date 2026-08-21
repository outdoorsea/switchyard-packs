#!/usr/bin/env bash
#
# Self-test for packs/switchyard-ops/assets/scripts/balance-sweep.sh — the
# factory balancer's measure-and-clamp pass.
#
# THE VERIFICATION CONTRACT
# -------------------------
#   "balance-sweep computes per-lane concurrency targets for brakeman and
#    reviewer clamped into operator floors and ceilings read from
#    BALANCER_BOUNDS in roster.conf, and atomically writes them to
#    balancer.targets in the pack state dir, never above the lane agent's
#    resolved max_active_sessions"
#
# Four clauses, each pinned in both directions, because each has a cheap wrong
# version that passes a happy-path read:
#
#   BOTH LANES, NOT ONE. A balancer that computed only brakeman targets would
#   look correct on every brakeman assertion while leaving the reviewer lane
#   hand-set forever. Both are asserted from the same run.
#
#   THE CLAMP BINDS IN BOTH DIRECTIONS. Demand above the ceiling clamps DOWN,
#   demand below the floor clamps UP. A clamp written as min() alone passes
#   every over-demand case and silently never honours a floor.
#
#   max_active_sessions IS AN ABSOLUTE CAP, NOT A THIRD BOUND. The dangerous
#   case is a floor set ABOVE the agent's resolved capacity: "clamp into the
#   bounds" and "never above max_active_sessions" then disagree, and the
#   criterion says which wins. A balancer applying the floor last publishes a
#   target the lane can never reach, and the spawn site would chase it every
#   cycle. Asserted explicitly.
#
#   THE WRITE IS ATOMIC AND OPT-IN. A reader may see the old file or the new
#   one, never a half-written one, and no temp file may be left behind — the
#   consumers treat a malformed file as absent, so a stray partial write is
#   indistinguishable from the balancer being off. And with BALANCER_RIGS
#   unset NOTHING is written at all, which is the invariant that keeps an
#   unopted city byte-for-byte unchanged.
#
# It runs hermetically: a throwaway city plus stub `gc`, `gh` and `curl` on
# PATH. No real city, session, forge or switchyard instance is involved.
# Needs jq (skips without it).
#
# The order is POSIX sh and ships to cities that are not Ubuntu, so CI runs this
# suite a second time under dash via BALANCE_TEST_SH — the same knob as the
# sibling suites (REVIEW_TEST_SH, REPAIR_TEST_SH, CONDUCTOR_TEST_SH).
#
# Run:  bash packs/switchyard-ops/assets/scripts/balance-sweep.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SWEEP="$HERE/balance-sweep.sh"

if ! command -v jq >/dev/null 2>&1; then
	echo "SKIP — balance-sweep self-test needs jq (not on PATH)"
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

# ---------------------------------------------------------------------------
# Fixtures. Every case builds a FRESH city: the targets file is the subject
# under test, so a reused fixture could pass a case on an earlier case's file.
# ---------------------------------------------------------------------------

# new_city <pool_depth> <pr_depth> [brakeman_max] [reviewer_max]
#
# One rig, `rigA`, with a brakeman and a reviewer agent. Pool depth is the
# claimable-bead count the switchyard API reports; PR depth is the number of
# open PRs `gh pr list` returns.
new_city() {
	local city pool_depth pr_depth bmax rmax
	pool_depth="$1"
	pr_depth="$2"
	bmax="${3:-9}"
	rmax="${4:-9}"
	city="$(mktemp -d)"
	mkdir -p "$city/bin" "$city/state"

	# The rig is a real empty git repo: the reviewer demand read derives the
	# owner/repo slug from `git remote get-url origin`, and stubbing git would
	# blind the suite to that read breaking.
	git init -q "$city/rigA" 2>/dev/null
	git -C "$city/rigA" remote add origin "git@github.com:acme/rigA.git"

	# The project list the pack's token can reach. rigA resolves by slug
	# equality, the same rule every other consumer uses.
	cat >"$city/projects.json" <<'JSON'
{"projects":[{"tenant_slug":"acme","slug":"rigA"}]}
JSON

	echo '[]' >"$city/rigs.json"
	cat >"$city/agents.json" <<JSON
{"agents":[
 {"qualified_name":"rigA/switchyard-ops.brakeman","pool":{"max":$bmax},"suspended":false},
 {"qualified_name":"rigA/switchyard-ops.reviewer","pool":{"max":$rmax},"suspended":false}
]}
JSON

	# The pool read: `total` is the claimable depth balance-sweep measures.
	printf '{"total":%s,"beads":[]}\n' "$pool_depth" >"$city/pool.json"

	# `gh pr list` returns one object per open PR awaiting review.
	jq -nc --argjson n "$pr_depth" '[range($n) | {number: (.+1)}]' >"$city/queue.json"

	cat >"$city/bin/gc" <<'STUB'
#!/bin/sh
case "$1 $2" in
"agent list") cat "$GC_CITY/agents.json" ;;
"rig list") cat "$GC_CITY/rigs.json" ;;
"mail send") printf 'MAIL\n' >>"$GC_CITY/mailed.log" ;;
esac
exit 0
STUB

	# The reviewed-but-unmerged queue the backpressure probe reads. Empty by
	# default, so every case that predates backpressure keeps its old answer.
	echo '[]' >"$city/merge_queue.json"

	cat >"$city/bin/gh" <<'STUB'
#!/bin/sh
# The sweep makes TWO different `gh pr list` reads: the reviewer lane's own
# open-PR queue (--json number) and the backpressure probe's reviewed-but-
# unmerged queue (--json ...reviewDecision...). This stub dispatches on the
# REQUESTED FIELDS rather than on --base, because REVIEW_LANE_BASE and
# MERGE_LANE_BASE are both `staging` by default: the base cannot tell the two
# apart, and a stub answering both alike would hide the second read entirely.
for a in "$@"; do
	case "$a" in
	*reviewDecision*)
		# An unreadable probe is a distinct outcome from an empty queue, so
		# the fixture can ask for a failing read specifically.
		[ -f "$GC_CITY/merge_fail" ] && exit 1
		cat "$GC_CITY/merge_queue.json"
		exit 0
		;;
	esac
done
cat "$GC_CITY/queue.json"
STUB


	# curl is how sy_api_get reaches switchyard. The token rides in on stdin as
	# a curl config, so it is drained and ignored here. The stub dispatches on
	# the URL — the last argument — because the sweep makes TWO different calls
	# and a stub answering both alike would resolve every rig to nothing.
	cat >"$city/bin/curl" <<'STUB'
#!/bin/sh
cat >/dev/null 2>&1
for a in "$@"; do url="$a"; done
case "$url" in
*/pool*) cat "$GC_CITY/pool.json" ;;
*/api/v1/projects) cat "$GC_CITY/projects.json" ;;
*) exit 1 ;;
esac
STUB

	chmod +x "$city/bin/gc" "$city/bin/gh" "$city/bin/curl"
	printf '%s' "$city"
}

# run_sweep <city> — run balance-sweep against a fixture city.
run_sweep() {
	local city="$1"
	shift
	(
		cd "$city" || exit 1
		PATH="$city/bin:$PATH" \
			GC_CITY="$city" \
			GC_PACK_STATE_DIR="$city/state" \
			GC_PACK_DIR="$HERE/.." \
			SWITCHYARD_API_TOKEN="sy_test" \
			SY_NS="switchyard-ops" \
			"$@" \
			"${BALANCE_TEST_SH:-sh}" "$SWEEP" 2>&1
	)
}

# target_for <city> <lane> — the published target for rigA's <lane>, or empty.
target_for() {
	awk -v lane="$2" '$1=="target" && $2=="rigA" && $3==lane {print $4}' \
		"$1/state/balancer.targets" 2>/dev/null
}

# merge_queue <city> <approved> [unreviewed] [approved_drafts] — the reviewed-
# but-unmerged queue the backpressure probe reads.
#
# The noise arguments are the point: only the APPROVED, non-draft PRs are the
# merge lane's backlog. A probe counting the whole open queue would read a busy
# review lane as a jammed merge lane and throttle the factory on it.
#
# The noise counts are sized to CROSS the threshold when wrongly included: 9
# approved drafts push a 2-deep backlog to 11, past the default 6. A fixture
# with fewer would pass whether or not drafts were excluded.
merge_queue() {
	jq -nc --argjson a "$2" --argjson u "${3:-0}" --argjson d "${4:-0}" '
		[range($a) | {number: (. + 1),   isDraft: false, reviewDecision: "APPROVED"}]
		+ [range($u) | {number: (. + 100), isDraft: false, reviewDecision: "REVIEW_REQUIRED"}]
		+ [range($d) | {number: (. + 200), isDraft: true,  reviewDecision: "APPROVED"}]' \
		>"$1/merge_queue.json"
}

TARGETS="state/balancer.targets"

# ---------------------------------------------------------------------------
# 1. Both lanes get a target, from one run.
# ---------------------------------------------------------------------------
city="$(new_city 3 2)"
printf 'BALANCER_RIGS="rigA"\n' >"$city/state/roster.conf"
out="$(run_sweep "$city")"
b="$(target_for "$city" brakeman)"
r="$(target_for "$city" reviewer)"
if [ "$b" = 3 ] && [ "$r" = 2 ]; then
	report ok "both lanes get a target from one run (brakeman=3 reviewer=2)"
else
	report FAIL "both lanes get a target from one run" "brakeman=${b:-<none>} reviewer=${r:-<none>}; out: $out"
fi

# The file must identify itself well enough for a consumer to reject a foreign
# or truncated one: a version line and a numeric generation stamp.
if grep -q '^version 1$' "$city/$TARGETS" 2>/dev/null &&
	awk '$1=="generated_at" && $2 ~ /^[0-9]+$/ {found=1} END{exit !found}' "$city/$TARGETS" 2>/dev/null; then
	report ok "the targets file carries a version and a numeric generated_at"
else
	report FAIL "the targets file carries a version and a numeric generated_at" "$(cat "$city/$TARGETS" 2>&1)"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# 2. The clamp binds in BOTH directions.
# ---------------------------------------------------------------------------
city="$(new_city 99 0)"
printf 'BALANCER_RIGS="rigA"\nBALANCER_BOUNDS="brakeman=1:4 reviewer=2:5"\n' >"$city/state/roster.conf"
out="$(run_sweep "$city")"
b="$(target_for "$city" brakeman)"
r="$(target_for "$city" reviewer)"
if [ "$b" = 4 ]; then
	report ok "demand above the ceiling clamps DOWN to it (99 -> 4)"
else
	report FAIL "demand above the ceiling clamps DOWN to it" "brakeman=${b:-<none>}; out: $out"
fi
if [ "$r" = 2 ]; then
	report ok "demand below the floor clamps UP to it (0 -> 2)"
else
	report FAIL "demand below the floor clamps UP to it" "reviewer=${r:-<none>}; out: $out"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# 3. max_active_sessions is an ABSOLUTE cap — it beats the ceiling AND the floor.
# ---------------------------------------------------------------------------
city="$(new_city 99 99 2 1)"
printf 'BALANCER_RIGS="rigA"\nBALANCER_BOUNDS="brakeman=1:8 reviewer=6:8"\n' >"$city/state/roster.conf"
out="$(run_sweep "$city")"
b="$(target_for "$city" brakeman)"
r="$(target_for "$city" reviewer)"
if [ "$b" = 2 ]; then
	report ok "a ceiling above max_active_sessions is capped by it (8 -> 2)"
else
	report FAIL "a ceiling above max_active_sessions is capped by it" "brakeman=${b:-<none>}; out: $out"
fi
if [ "$r" = 1 ]; then
	report ok "a FLOOR above max_active_sessions is capped by it too (6 -> 1)"
else
	report FAIL "a FLOOR above max_active_sessions is capped by it too" "reviewer=${r:-<none>}; out: $out"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# 4. A malformed bound falls back to the default rather than taking the lane
#    down — the same rule SY_FANOUT_THRESHOLD documents for a typo.
# ---------------------------------------------------------------------------
city="$(new_city 3 1)"
printf 'BALANCER_RIGS="rigA"\nBALANCER_BOUNDS="brakeman=high:low reviewer=1:2"\n' >"$city/state/roster.conf"
out="$(run_sweep "$city")"
b="$(target_for "$city" brakeman)"
r="$(target_for "$city" reviewer)"
if [ -n "$b" ] && [ "$b" -ge 0 ] 2>/dev/null && [ "$r" = 1 ]; then
	report ok "a malformed bound falls back to the default and the other lane is unaffected"
else
	report FAIL "a malformed bound falls back to the default" "brakeman=${b:-<none>} reviewer=${r:-<none>}; out: $out"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# 5. The write is atomic, and leaves no temp behind.
# ---------------------------------------------------------------------------
city="$(new_city 5 5)"
printf 'BALANCER_RIGS="rigA"\n' >"$city/state/roster.conf"
printf 'version 1\ngenerated_at 1\ntarget rigA brakeman 99\n' >"$city/$TARGETS"
out="$(run_sweep "$city")"
strays="$(find "$city/state" -name 'balancer.targets.*' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$strays" = 0 ]; then
	report ok "no temp file is left beside the targets file"
else
	report FAIL "no temp file is left beside the targets file" "$strays stray file(s)"
fi
# A rewrite must fully REPLACE the previous generation, not append to it: two
# targets for one (rig, lane) is a file whose meaning depends on read order.
dupes="$(awk '$1=="target" {print $2, $3}' "$city/$TARGETS" 2>/dev/null | sort | uniq -d | wc -l | tr -d ' ')"
if [ "$dupes" = 0 ] && [ "$(target_for "$city" brakeman)" = 5 ]; then
	report ok "a rewrite replaces the previous generation rather than appending"
else
	report FAIL "a rewrite replaces the previous generation" "dupes=$dupes brakeman=$(target_for "$city" brakeman); out: $out"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# 6. THE OPT-IN INVARIANT. BALANCER_RIGS unset writes nothing at all.
# ---------------------------------------------------------------------------
city="$(new_city 7 7)"
: >"$city/state/roster.conf"
out="$(run_sweep "$city")"
if [ ! -e "$city/$TARGETS" ]; then
	report ok "BALANCER_RIGS unset writes no targets file at all"
else
	report FAIL "BALANCER_RIGS unset writes no targets file at all" "$(cat "$city/$TARGETS" 2>&1)"
fi
rm -rf "$city"

# An unopted city must also not leave a STALE file readable as fresh. If a file
# already exists and the balancer is switched off, it is left exactly as it was
# — the consumers' staleness check is what retires it, not a silent deletion.
city="$(new_city 7 7)"
: >"$city/state/roster.conf"
printf 'version 1\ngenerated_at 1\ntarget rigA brakeman 42\n' >"$city/$TARGETS"
out="$(run_sweep "$city")"
if [ "$(target_for "$city" brakeman)" = 42 ]; then
	report ok "an unopted city leaves an existing targets file untouched"
else
	report FAIL "an unopted city leaves an existing targets file untouched" "$(cat "$city/$TARGETS" 2>&1); out: $out"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# 7. BACKPRESSURE. A merge lane that cannot drain is not helped by more work
#    arriving behind it, so a deep reviewed-but-unmerged queue clamps the two
#    upstream lanes to their floors instead of scaling them on their own demand.
#
#    Both lanes are asserted from the same run: backpressure that throttled
#    only the builders would leave reviewers piling more approved PRs onto the
#    queue that is already the bottleneck.
# ---------------------------------------------------------------------------
city="$(new_city 99 9)"
merge_queue "$city" 9
printf 'BALANCER_RIGS="rigA"\nBALANCER_BOUNDS="brakeman=1:6 reviewer=2:5"\n' >"$city/state/roster.conf"
out="$(run_sweep "$city")"
b="$(target_for "$city" brakeman)"
r="$(target_for "$city" reviewer)"
if [ "$b" = 1 ] && [ "$r" = 2 ]; then
	report ok "a deep reviewed-but-unmerged queue clamps BOTH lanes to their floors (9 approved > 6)"
else
	report FAIL "a deep reviewed-but-unmerged queue clamps BOTH lanes to their floors" "brakeman=${b:-<none>} (want 1) reviewer=${r:-<none>} (want 2); out: $out"
fi
rm -rf "$city"

# Under the threshold nothing changes — AND only REVIEWED, non-draft PRs count
# toward it. This queue is 25 open PRs deep but only 2 of them are waiting on
# the merge lane; the rest are the reviewer's own work and a draft nobody has
# finished. An implementation counting the whole open queue would throttle the
# factory here on a backlog that is not the merge lane's at all.
city="$(new_city 99 9)"
merge_queue "$city" 2 20 9
printf 'BALANCER_RIGS="rigA"\nBALANCER_BOUNDS="brakeman=1:6 reviewer=2:5"\n' >"$city/state/roster.conf"
out="$(run_sweep "$city")"
b="$(target_for "$city" brakeman)"
r="$(target_for "$city" reviewer)"
if [ "$b" = 6 ] && [ "$r" = 5 ]; then
	report ok "only reviewed non-draft PRs count, so 2 approved among 25 open does not clamp"
else
	report FAIL "only reviewed non-draft PRs count, so 2 approved among 25 open does not clamp" "brakeman=${b:-<none>} (want 6) reviewer=${r:-<none>} (want 5); out: $out"
fi
rm -rf "$city"

# The threshold is an EXCEEDS, not a reaches: a backlog exactly at it is the
# lane holding its line, and throttling there would clamp a factory that is
# keeping up. One either side of the boundary, since `-gt` and `-ge` differ on
# exactly one value and every other case in this file is far from it.
city="$(new_city 99 9)"
merge_queue "$city" 6
printf 'BALANCER_RIGS="rigA"\nBALANCER_BOUNDS="brakeman=1:6 reviewer=2:5"\nBALANCER_MERGE_BACKPRESSURE="6"\n' >"$city/state/roster.conf"
out="$(run_sweep "$city")"
b_at="$(target_for "$city" brakeman)"
rm -rf "$city"

city="$(new_city 99 9)"
merge_queue "$city" 7
printf 'BALANCER_RIGS="rigA"\nBALANCER_BOUNDS="brakeman=1:6 reviewer=2:5"\nBALANCER_MERGE_BACKPRESSURE="6"\n' >"$city/state/roster.conf"
out="$(run_sweep "$city")"
b_over="$(target_for "$city" brakeman)"
rm -rf "$city"

if [ "$b_at" = 6 ] && [ "$b_over" = 1 ]; then
	report ok "the threshold is an exceeds: 6 holds (6), 7 throttles (1)"
else
	report FAIL "the threshold is an exceeds: 6 holds, 7 throttles" "at=${b_at:-<none>} (want 6) over=${b_over:-<none>} (want 1)"
fi

# The floor is where backpressure sends a lane, but max_active_sessions still
# beats it — the same order the unthrottled path uses. A backpressure branch
# that published the floor RAW would put an unreachable target on the file at
# exactly the moment the factory is under strain.
city="$(new_city 99 9 2 9)"
merge_queue "$city" 9
printf 'BALANCER_RIGS="rigA"\nBALANCER_BOUNDS="brakeman=6:8 reviewer=2:5"\n' >"$city/state/roster.conf"
out="$(run_sweep "$city")"
b="$(target_for "$city" brakeman)"
if [ "$b" = 2 ]; then
	report ok "a floor above capacity still resolves DOWN to capacity under backpressure (6 -> 2)"
else
	report FAIL "a floor above capacity still resolves DOWN to capacity under backpressure" "brakeman=${b:-<none>} (want 2, never 6); out: $out"
fi
rm -rf "$city"

# An UNREADABLE probe is not a deep queue. Throttling the whole factory to its
# floors because one `gh` call timed out is the outage the balancer exists to
# prevent, so an unreadable signal changes no target and is named in the report.
city="$(new_city 99 9)"
: >"$city/merge_fail"
printf 'BALANCER_RIGS="rigA"\nBALANCER_BOUNDS="brakeman=1:6 reviewer=2:5"\n' >"$city/state/roster.conf"
out="$(run_sweep "$city")"
b="$(target_for "$city" brakeman)"
r="$(target_for "$city" reviewer)"
if [ "$b" = 6 ] && [ "$r" = 5 ]; then
	report ok "an unreadable backpressure probe changes no target"
else
	report FAIL "an unreadable backpressure probe changes no target" "brakeman=${b:-<none>} (want 6) reviewer=${r:-<none>} (want 5); out: $out"
fi
case "$out" in
*backpressure-unreadable*) report ok "an unreadable backpressure probe is named in the report" ;;
*) report FAIL "an unreadable backpressure probe is named in the report" "out: $out" ;;
esac
rm -rf "$city"

# Backpressure is tunable, and 0 switches it off: an operator who wants the
# lanes to follow demand regardless of the merge queue says so, and a deep
# queue then scales nothing down.
city="$(new_city 99 9)"
merge_queue "$city" 99
printf 'BALANCER_RIGS="rigA"\nBALANCER_BOUNDS="brakeman=1:6 reviewer=2:5"\nBALANCER_MERGE_BACKPRESSURE="0"\n' >"$city/state/roster.conf"
out="$(run_sweep "$city")"
b="$(target_for "$city" brakeman)"
if [ "$b" = 6 ]; then
	report ok "BALANCER_MERGE_BACKPRESSURE=0 disables the clamp entirely"
else
	report FAIL "BALANCER_MERGE_BACKPRESSURE=0 disables the clamp entirely" "brakeman=${b:-<none>} (want 6); out: $out"
fi
rm -rf "$city"

# A malformed threshold takes the default rather than the lane, the same rule
# BALANCER_BOUNDS and SY_FANOUT_THRESHOLD follow: a typo in a tuning knob must
# not decide whether the factory throttles.
city="$(new_city 99 9)"
merge_queue "$city" 9
printf 'BALANCER_RIGS="rigA"\nBALANCER_BOUNDS="brakeman=1:6 reviewer=2:5"\nBALANCER_MERGE_BACKPRESSURE="lots"\n' >"$city/state/roster.conf"
out="$(run_sweep "$city")"
b="$(target_for "$city" brakeman)"
if [ "$b" = 1 ]; then
	report ok "a malformed backpressure threshold falls back to the default (still clamps at 9)"
else
	report FAIL "a malformed backpressure threshold falls back to the default" "brakeman=${b:-<none>} (want 1); out: $out"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# 8. THE SERIAL STAGES ARE NEVER SCALED.
#
#    merge-lane and staging-promote are ordered for correctness — each merge
#    moves the base under every other PR — so "more concurrency" there means
#    two sessions merging into one branch. Their depth is a backpressure signal
#    and never a lane to widen.
#
#    Guarded in BOTH directions, because the cheap wrong version of this test
#    passes on a script that publishes no targets at all: the balanced set must
#    contain neither serial stage AND must still contain both parallel lanes.
# ---------------------------------------------------------------------------
lanes="$(awk -F'"' '/^BALANCE_LANES=/ {print $2; exit}' "$SWEEP")"
has_lane() { case " $lanes " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

serial_found=""
for l in merge-lane staging-promote merge_lane staging_promote; do
	has_lane "$l" && serial_found="$serial_found $l"
done
# Both directions. "Contains no serial stage" alone passes on an empty set, so
# the parallel lanes must still be there — otherwise a script that balanced
# nothing at all would read as honouring the invariant.
if [ -z "$serial_found" ] && has_lane brakeman && has_lane reviewer; then
	report ok "the balanced lane set is exactly the parallel lanes (got: $lanes)"
else
	report FAIL "the balanced lane set is exactly the parallel lanes" "got '$lanes'; serial:${serial_found:- none}"
fi

# And no run may publish a target for one, however an operator asks. Naming a
# serial stage in BALANCER_BOUNDS is documented as doing nothing — this is the
# case that holds that promise, under backpressure as well as under load.
city="$(new_city 99 9)"
merge_queue "$city" 9
printf 'BALANCER_RIGS="rigA"\nBALANCER_BOUNDS="brakeman=1:6 reviewer=2:5 merge-lane=1:4 staging-promote=1:4"\n' >"$city/state/roster.conf"
out="$(run_sweep "$city")"
if [ -z "$(target_for "$city" merge-lane)" ] && [ -z "$(target_for "$city" staging-promote)" ]; then
	report ok "naming a serial stage in BALANCER_BOUNDS publishes no target for it"
else
	report FAIL "naming a serial stage in BALANCER_BOUNDS publishes no target for it" "$(cat "$city/$TARGETS" 2>&1)"
fi
# Nothing anywhere in the file may carry a serial lane, whatever the lane set.
if ! awk '$1=="target" && ($3=="merge-lane" || $3=="staging-promote") {found=1} END{exit !found}' \
	"$city/$TARGETS" 2>/dev/null; then
	report ok "no target line in the published file names a serial stage"
else
	report FAIL "no target line in the published file names a serial stage" "$(cat "$city/$TARGETS" 2>&1)"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
echo
echo "balance-sweep self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
