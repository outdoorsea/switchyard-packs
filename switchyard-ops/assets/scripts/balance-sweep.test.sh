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

# stray_temps <city> — every temp file the sweep could leave beside its state.
#
# ALL THREE are checked, not just the targets temp. Each is `mktemp "<file>.XXXXXX"`
# against a state path, so they land in the state dir beside balancer.targets,
# balancer.history and balancer.log rather than in /tmp — nothing else collects
# them, and the paths that abandon a publish must clear all three before they
# drop the trap. An assertion written against the targets temp alone would keep
# passing while the other two accumulated, one pair per abandoned cycle.
#
# The live files carry no suffix, so a single-dot name never matches.
stray_temps() {
	find "$1/state" \
		\( -name 'balancer.targets.*' \
		   -o -name 'balancer.history.*' \
		   -o -name 'balancer.log.*' \) 2>/dev/null
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
strays="$(stray_temps "$city")"
if [ -z "$strays" ]; then
	report ok "no temp file is left beside the state files"
else
	report FAIL "no temp file is left beside the state files" "stray: $strays"
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
# HYSTERESIS (crit:8624d71e0801). A target RAISES only after the raise signal
# has persisted 2 consecutive cycles and LOWERS only after 6, and every applied
# change appends an old-to-new entry citing the justifying snapshot.
#
# These cases reuse ONE city across several runs on purpose — the whole subject
# is state carried BETWEEN cycles, so a fresh fixture per run would test
# nothing. That is the one deliberate exception to the fresh-city rule above.
#
# The asymmetry is the point: cheap to add a worker, expensive to lose one. A
# gate written with a single shared threshold passes every raise assertion and
# silently lowers just as eagerly, so both counts are pinned separately, and
# each is pinned at its boundary (holds at N-1, applies at N) rather than
# somewhere past it — a gate of 2 and a gate of 1 agree on every cycle except
# the first.
# ---------------------------------------------------------------------------
LOG="state/balancer.log"

# set_pool <city> <n> — the claimable depth the next cycle will measure.
set_pool() { printf '{"total":%s,"beads":[]}\n' "$2" >"$1/pool.json"; }

# log_has <city> <regex> — does the balancer log carry a matching entry?
log_has() { grep -Eq "$2" "$1/$LOG" 2>/dev/null; }

# log_count <city> — how many entries the balancer log carries.
log_count() { [ -f "$1/$LOG" ] && wc -l <"$1/$LOG" | tr -d ' ' || echo 0; }

# --- 12. The first publish is immediate: there is no old value to damp. ------
city="$(new_city 3 0)"
printf 'BALANCER_RIGS="rigA"\n' >"$city/state/roster.conf"
run_sweep "$city" >/dev/null
if [ "$(target_for "$city" brakeman)" = 3 ]; then
	report ok "the first-ever publish applies immediately (no prior target to damp)"
else
	report FAIL "the first-ever publish applies immediately" "brakeman=$(target_for "$city" brakeman)"
fi

# --- 13. A RAISE holds for one cycle and applies on the second. -------------
set_pool "$city" 7
run_sweep "$city" >/dev/null
held="$(target_for "$city" brakeman)"
if [ "$held" = 3 ]; then
	report ok "a raise is HELD on its first cycle (3 -> 7 suppressed, still 3)"
else
	report FAIL "a raise is HELD on its first cycle" "brakeman=${held:-<none>}, expected 3"
fi

run_sweep "$city" >/dev/null
applied="$(target_for "$city" brakeman)"
if [ "$applied" = 7 ]; then
	report ok "a raise APPLIES on its second consecutive cycle (3 -> 7)"
else
	report FAIL "a raise applies on its second consecutive cycle" "brakeman=${applied:-<none>}, expected 7"
fi

# The applied change is logged old-to-new, citing the snapshot that justified
# it. A log carrying only the new value cannot be audited against the file the
# consumers actually read.
if log_has "$city" '^.*rigA[[:space:]]+brakeman[[:space:]]+3[[:space:]]+->[[:space:]]+7' &&
	log_has "$city" 'snapshot=' && log_has "$city" 'demand=7'; then
	report ok "an applied raise appends an old-to-new entry citing the snapshot"
else
	report FAIL "an applied raise appends an old-to-new entry citing the snapshot" "$(cat "$city/$LOG" 2>&1)"
fi

# A HELD cycle changed no target, so it must add no entry. A log that recorded
# every cycle would make "every target change is logged" unfalsifiable.
before="$(log_count "$city")"
run_sweep "$city" >/dev/null
if [ "$(log_count "$city")" = "$before" ] && [ "$(target_for "$city" brakeman)" = 7 ]; then
	report ok "a cycle that changes no target appends no log entry"
else
	report FAIL "a cycle that changes no target appends no log entry" "before=$before after=$(log_count "$city")"
fi
rm -rf "$city"

# --- 14. A LOWER needs SIX consecutive cycles, not two. ---------------------
city="$(new_city 8 0)"
printf 'BALANCER_RIGS="rigA"\n' >"$city/state/roster.conf"
run_sweep "$city" >/dev/null   # publish 8

set_pool "$city" 1
i=1
lower_leak=""
while [ "$i" -le 5 ]; do
	run_sweep "$city" >/dev/null
	[ "$(target_for "$city" brakeman)" = 8 ] || lower_leak="cycle $i -> $(target_for "$city" brakeman)"
	i=$((i + 1))
done
if [ -z "$lower_leak" ]; then
	report ok "a lower is HELD for five cycles (8 -> 1 suppressed each time)"
else
	report FAIL "a lower is HELD for five cycles" "$lower_leak"
fi

run_sweep "$city" >/dev/null
if [ "$(target_for "$city" brakeman)" = 1 ]; then
	report ok "a lower APPLIES on its sixth consecutive cycle (8 -> 1)"
else
	report FAIL "a lower applies on its sixth consecutive cycle" "brakeman=$(target_for "$city" brakeman)"
fi
if log_has "$city" '^.*rigA[[:space:]]+brakeman[[:space:]]+8[[:space:]]+->[[:space:]]+1'; then
	report ok "an applied lower appends its own old-to-new entry"
else
	report FAIL "an applied lower appends its own old-to-new entry" "$(cat "$city/$LOG" 2>&1)"
fi
rm -rf "$city"

# --- 15. A reversed signal RESETS the streak. -------------------------------
# Without a reset, a lane whose demand oscillates accumulates raise credit from
# non-consecutive cycles and eventually raises on noise — which is the exact
# flapping this criterion exists to prevent.
city="$(new_city 2 0)"
printf 'BALANCER_RIGS="rigA"\n' >"$city/state/roster.conf"
run_sweep "$city" >/dev/null   # publish 2
set_pool "$city" 6
run_sweep "$city" >/dev/null   # raise streak 1, held
set_pool "$city" 2
run_sweep "$city" >/dev/null   # signal returns to the published value: reset
set_pool "$city" 6
run_sweep "$city" >/dev/null   # raise streak 1 again, must still be held
if [ "$(target_for "$city" brakeman)" = 2 ]; then
	report ok "a reversed signal resets the streak (interrupted raise does not apply)"
else
	report FAIL "a reversed signal resets the streak" "brakeman=$(target_for "$city" brakeman), expected 2"
fi
rm -rf "$city"

# --- 16. An unreadable probe PRESERVES the streak. --------------------------
# An unreadable demand read is not a demand signal — the same stance the
# backpressure probe already takes. Dropping the streak on it would let a
# flaky forge silently reset the gate every few cycles.
#
# THE ASSERTION LANDS ON A HELD CYCLE, and it has to. Asserting that the lane
# eventually REACHES the raised value proves nothing: a run that forgot the lane
# entirely would treat the next cycle as a first publish and apply the same
# number immediately, by a different mechanism. Only a cycle the gate is
# supposed to SUPPRESS separates a preserved streak from a lost one — a lost
# history applies at once, a preserved one holds.
city="$(new_city 2 0)"
printf 'BALANCER_RIGS="rigA"\n' >"$city/state/roster.conf"
run_sweep "$city" >/dev/null   # publish 2
mv "$city/pool.json" "$city/pool.hidden"
run_sweep "$city" >/dev/null   # demand unreadable: lane skipped, memory must survive
mv "$city/pool.hidden" "$city/pool.json"
set_pool "$city" 9
run_sweep "$city" >/dev/null   # first raise cycle AFTER the gap: must be HELD at 2
held="$(target_for "$city" brakeman)"
if [ "$held" = 2 ]; then
	report ok "an unreadable probe preserves the streak rather than resetting it"
else
	report FAIL "an unreadable probe preserves the streak" "brakeman=${held:-<none>}, expected 2 (a lost history would publish 9 as a first publish)"
fi
# And the surviving streak still completes normally on the next cycle.
run_sweep "$city" >/dev/null
if [ "$(target_for "$city" brakeman)" = 9 ]; then
	report ok "the preserved streak still completes on its second cycle (2 -> 9)"
else
	report FAIL "the preserved streak still completes on its second cycle" "brakeman=$(target_for "$city" brakeman)"
fi
rm -rf "$city"

# --- 17. Backpressure is an override, not a demand signal. ------------------
# The merged pass states it in its own words: "A THROTTLED LANE IS NOT
# MEASURED." This criterion gates on a DEMAND signal persisting, and a
# throttled lane has none to persist — so the clamp to floor lands at once.
# Making it wait six cycles would leave the factory producing into a jammed
# merge stage for half an hour, defeating the backpressure criterion outright.
city="$(new_city 9 0)"
printf 'BALANCER_RIGS="rigA"\nBALANCER_BOUNDS="brakeman=1:9"\n' >"$city/state/roster.conf"
run_sweep "$city" >/dev/null   # publish 9
merge_queue "$city" 9          # merge stage jams
run_sweep "$city" >/dev/null
if [ "$(target_for "$city" brakeman)" = 1 ]; then
	report ok "backpressure clamps to the floor at once, bypassing the lower gate"
else
	report FAIL "backpressure clamps to the floor at once" "brakeman=$(target_for "$city" brakeman), expected 1"
fi
rm -rf "$city"

# 9. EVERY EXTERNAL READ IS BOUNDED.
#
#    The order runs under gc's 60-second exec deadline, so one forge or
#    controller read that never returns does not merely lose its own answer —
#    it takes the whole cycle down, and the failure surfaces as a silent
#    `order exec balance-sweep failed: context deadline exceeded` naming
#    neither the read nor the rig.
#
#    Asserted ON THE CLOCK rather than by grepping the source for sy_timeout: a
#    wrapper applied with an unusable timeout value matches the grep and still
#    hangs. Each case makes one read hang far longer than the cycle could
#    afford and asserts the sweep returns anyway — and that the OTHER lane's
#    target still lands, so "bounded" cannot be satisfied by giving up wholesale.
# ---------------------------------------------------------------------------
city="$(new_city 3 4)"
printf 'BALANCER_RIGS="rigA"\n' >"$city/state/roster.conf"
# Answers the backpressure probe instantly and HANGS on the reviewer queue, so
# the hang is attributable to exactly one read.
cat >"$city/bin/gh" <<'STUB'
#!/bin/sh
for a in "$@"; do
	case "$a" in
	*reviewDecision*) echo '[]'; exit 0 ;;
	esac
done
sleep 20
STUB
chmod +x "$city/bin/gh"
t0="$(date +%s)"
out="$(run_sweep "$city" env BALANCER_READ_TIMEOUT=3 BALANCE_SWEEP_BUDGET_SECONDS=30)"
elapsed=$(($(date +%s) - t0))
if [ "$elapsed" -lt 12 ]; then
	report ok "a hanging reviewer-queue read is cut off well inside the cycle (${elapsed}s)"
else
	report FAIL "a hanging reviewer-queue read is cut off well inside the cycle" "took ${elapsed}s; out: $out"
fi
# The bound must cost only the unreadable lane. A sweep that answered the hang
# by publishing nothing would pass the clock assertion above while making the
# timeout indistinguishable from an outage.
if [ "$(target_for "$city" brakeman)" = 3 ]; then
	report ok "a bounded-out reviewer read still leaves the brakeman target published"
else
	report FAIL "a bounded-out reviewer read still leaves the brakeman target published" "brakeman=$(target_for "$city" brakeman); out: $out"
fi
rm -rf "$city"

# The controller read is fetched once per cycle before the rig loop, so a hang
# there strands the sweep before any lane is even considered.
city="$(new_city 3 4)"
printf 'BALANCER_RIGS="rigA"\n' >"$city/state/roster.conf"
cat >"$city/bin/gc" <<'STUB'
#!/bin/sh
case "$1 $2" in
"agent list") sleep 20 ;;
"mail send") printf 'MAIL\n' >>"$GC_CITY/mailed.log" ;;
esac
exit 0
STUB
chmod +x "$city/bin/gc"
t0="$(date +%s)"
out="$(run_sweep "$city" env BALANCER_READ_TIMEOUT=3 BALANCE_SWEEP_BUDGET_SECONDS=30)"
elapsed=$(($(date +%s) - t0))
if [ "$elapsed" -lt 12 ]; then
	report ok "a hanging controller roster read is cut off well inside the cycle (${elapsed}s)"
else
	report FAIL "a hanging controller roster read is cut off well inside the cycle" "took ${elapsed}s; out: $out"
fi
# Capacity is the cap a target may never exceed, so an unreadable roster must
# publish no target at all rather than an unbounded one.
if [ -z "$(target_for "$city" brakeman)" ] && [ -z "$(target_for "$city" reviewer)" ]; then
	report ok "a bounded-out roster read publishes no target for either lane"
else
	report FAIL "a bounded-out roster read publishes no target for either lane" "$(cat "$city/$TARGETS" 2>&1)"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# 10. AN OVER-BUDGET CYCLE WRITES NO TARGETS AND SAYS WHAT IT SKIPPED.
#
#     Bounding each read individually is not enough: several bounded reads can
#     still sum past the runner's deadline. The pass therefore carries its own
#     budget, deliberately inside that deadline, and checks it can AFFORD a
#     read before starting one — the same shape as pool-spawn's
#     POOL_SPAWN_BUDGET_SECONDS and lane-ensure's LANE_SWEEP_BUDGET_SECONDS.
#
#     THE PUBLISH IS ABANDONED WHOLESALE, not truncated. Targets accumulate in
#     the temp file as each lane is measured, so a cycle that stopped early and
#     published anyway would ship a PARTIAL generation — and a missing lane
#     line means "fall back to city.toml", so a partial file silently un-scales
#     every lane it did not reach. Leaving the previous generation in place is
#     the strictly better answer, and it is what "writes no targets" means.
#
#     Pinned in BOTH directions: a script that simply never published would
#     pass the over-budget case on its own.
# ---------------------------------------------------------------------------

# THE CLOCK THESE CASES MEASURE IS THE FIXTURE'S, NOT THE BOX'S.
#
# sy_affords N reduces to `elapsed <= BUDGET - N`, so a budget tight enough to
# be exhausted mid-rig leaves only a second or two of margin — and every read
# the script makes BEFORE the rig loop (`gc agent list`, the token and projects
# fetches, three mktemps) is charged against that margin without being gated by
# it. On a loaded box those cross a `date +%s` boundary on their own, the RIG
# gate at the top of the loop fires before the LANE gate inside it, and the run
# reports `rigA(budget)` where the assertion below wants `rigA/reviewer(budget)`.
# The case then measures how busy the box is rather than what the script does.
#
# So the clock is frozen and handed to the stubs. Every affordability decision
# in the sweep funnels through ONE reader, sy_now, which is `date +%s` — so a
# `date` stub on PATH is enough to make elapsed advance only where a fixture
# says it does. That is also why slow_pool_read below no longer sleeps: the
# subject of these cases is the budget arithmetic, and a real sleep only puts
# the scheduler back inside the assertion it was removed from.

# fake_clock <city> — freeze `date +%s` at a fixed epoch plus whatever the
# stubs have charged to $GC_CITY/clock. Non-+%s calls fall through to the real
# date, so nothing else in the harness changes shape.
fake_clock() {
	printf '0\n' >"$1/clock"
	cat >"$1/bin/date" <<'STUB'
#!/bin/sh
case "$1" in
+%s)
	_e=0
	[ -r "$GC_CITY/clock" ] && _e="$(cat "$GC_CITY/clock")"
	printf '%s\n' "$(( 1787000000 + _e ))"
	;;
*) exec /bin/date "$@" ;;
esac
STUB
	chmod +x "$1/bin/date"
}

# slow_pool_read <city> <seconds> — make the brakeman demand read cost SECONDS
# of the cycle's budget, so a tight budget is exhausted partway through the rig
# rather than at its edge. Charges the frozen clock rather than sleeping, so the
# read costs exactly what it claims to. Requires fake_clock on the same city.
slow_pool_read() {
	printf '%s\n' "$2" >"$1/slow_cost"
	cat >"$1/bin/curl" <<'STUB'
#!/bin/sh
cat >/dev/null 2>&1
for a in "$@"; do url="$a"; done
case "$url" in
*/pool*)
	_e=0
	[ -r "$GC_CITY/clock" ] && _e="$(cat "$GC_CITY/clock")"
	_c=0
	[ -r "$GC_CITY/slow_cost" ] && _c="$(cat "$GC_CITY/slow_cost")"
	printf '%s\n' "$(( _e + _c ))" >"$GC_CITY/clock"
	cat "$GC_CITY/pool.json"
	;;
*/api/v1/projects) cat "$GC_CITY/projects.json" ;;
*) exit 1 ;;
esac
STUB
	chmod +x "$1/bin/curl"
}

city="$(new_city 3 4)"
printf 'BALANCER_RIGS="rigA"\n' >"$city/state/roster.conf"
fake_clock "$city"
slow_pool_read "$city" 2
# A previous generation the consumers are already reading. It must survive an
# over-budget cycle byte-for-byte.
printf 'version 1\ngenerated_at 1\ntarget rigA brakeman 42\n' >"$city/$TARGETS"
before="$(cat "$city/$TARGETS")"
out="$(run_sweep "$city" env BALANCER_READ_TIMEOUT=3 BALANCE_SWEEP_BUDGET_SECONDS=4)"
if [ "$(cat "$city/$TARGETS")" = "$before" ]; then
	report ok "an over-budget cycle leaves the previous targets generation untouched"
else
	report FAIL "an over-budget cycle leaves the previous targets generation untouched" "$(cat "$city/$TARGETS" 2>&1)"
fi
# "self-reports which stages it skipped" — the stage must be NAMED, because the
# whole point is to replace a deadline kill that named nothing.
case "$out" in
*rigA/reviewer*) report ok "an over-budget cycle names the stage it skipped" ;;
*) report FAIL "an over-budget cycle names the stage it skipped" "out: $out" ;;
esac
case "$out" in
*budget*) report ok "an over-budget cycle says the budget is why it stopped" ;;
*) report FAIL "an over-budget cycle says the budget is why it stopped" "out: $out" ;;
esac
strays="$(stray_temps "$city")"
if [ -z "$strays" ]; then
	report ok "an abandoned publish leaves no temp file behind"
else
	report FAIL "an abandoned publish leaves no temp file behind" "stray: $strays"
fi
rm -rf "$city"

# THE CONVERSE. The same slow read inside a budget that affords it publishes
# normally — otherwise a balancer that had simply stopped working would satisfy
# every assertion above.
city="$(new_city 3 4)"
printf 'BALANCER_RIGS="rigA"\n' >"$city/state/roster.conf"
fake_clock "$city"
slow_pool_read "$city" 2
printf 'version 1\ngenerated_at 1\ntarget rigA brakeman 42\n' >"$city/$TARGETS"
out="$(run_sweep "$city" env BALANCER_READ_TIMEOUT=3 BALANCE_SWEEP_BUDGET_SECONDS=30)"
if [ "$(target_for "$city" brakeman)" = 3 ] && [ "$(target_for "$city" reviewer)" = 4 ]; then
	report ok "a cycle that fits its budget publishes both lanes as usual"
else
	report FAIL "a cycle that fits its budget publishes both lanes as usual" "$(cat "$city/$TARGETS" 2>&1); out: $out"
fi
rm -rf "$city"

# 0 DISABLES THE CAP for hand-run debugging, matching POOL_SPAWN_BUDGET_SECONDS.
# Were 0 treated as a budget rather than as "off", affording any read at all
# would be impossible and the sweep would publish nothing for ever.
city="$(new_city 3 4)"
printf 'BALANCER_RIGS="rigA"\n' >"$city/state/roster.conf"
fake_clock "$city"
slow_pool_read "$city" 2
out="$(run_sweep "$city" env BALANCER_READ_TIMEOUT=3 BALANCE_SWEEP_BUDGET_SECONDS=0)"
if [ "$(target_for "$city" brakeman)" = 3 ] && [ "$(target_for "$city" reviewer)" = 4 ]; then
	report ok "a budget of 0 disables the cap and publishes normally"
else
	report FAIL "a budget of 0 disables the cap and publishes normally" "$(cat "$city/$TARGETS" 2>&1); out: $out"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# 11. A BUDGET THAT CANNOT AFFORD ONE READ IS A CONFIG FAULT, AND FAULTS FAIL.
#
#     A read timeout above the whole cycle budget means no read is ever
#     affordable, so the sweep would skip every stage and publish nothing on
#     every cycle — a balancer that is silently off while reading as healthy.
#     This runs under the order runner, where exit 0 with no publish is
#     indistinguishable from a quiet cycle, so the fault is made loud rather
#     than left to look like load. Same rule as pool-spawn's config faults.
# ---------------------------------------------------------------------------
city="$(new_city 3 4)"
printf 'BALANCER_RIGS="rigA"\n' >"$city/state/roster.conf"
printf 'version 1\ngenerated_at 1\ntarget rigA brakeman 42\n' >"$city/$TARGETS"
before="$(cat "$city/$TARGETS")"
out="$(run_sweep "$city" env BALANCER_READ_TIMEOUT=9 BALANCE_SWEEP_BUDGET_SECONDS=4)"
rc=$?
if [ "$rc" -ne 0 ]; then
	report ok "a read timeout above the cycle budget fails the cycle instead of idling"
else
	report FAIL "a read timeout above the cycle budget fails the cycle instead of idling" "rc=$rc; out: $out"
fi
case "$out" in
*"config fault"*) report ok "the config fault says what is wrong" ;;
*) report FAIL "the config fault says what is wrong" "out: $out" ;;
esac
if [ "$(cat "$city/$TARGETS")" = "$before" ]; then
	report ok "a refused cycle leaves the previous targets generation untouched"
else
	report FAIL "a refused cycle leaves the previous targets generation untouched" "$(cat "$city/$TARGETS" 2>&1)"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# 12. A MALFORMED CLOCK KNOB FALLS BACK; IT DOES NOT ABORT THE CYCLE.
#
#     The same rule the backpressure threshold already follows — a typo in a
#     tuning knob must not take a lane down — but it bites harder here, because
#     these two values are used in ARITHMETIC. A leading zero is the sharp case:
#     `test -gt` reads 08 as decimal 8 and happily passes it along, while
#     $(( )) reads it as octal and 08 is not valid octal. So a knob that looks
#     merely odd does not degrade the cycle, it aborts it mid-loop — the exact
#     silent death the budget exists to replace.
# ---------------------------------------------------------------------------
city="$(new_city 3 4)"
printf 'BALANCER_RIGS="rigA"\n' >"$city/state/roster.conf"
out="$(run_sweep "$city" env BALANCER_READ_TIMEOUT=08 BALANCE_SWEEP_BUDGET_SECONDS=045)"
if [ "$(target_for "$city" brakeman)" = 3 ] && [ "$(target_for "$city" reviewer)" = 4 ]; then
	report ok "leading-zero clock knobs fall back to defaults and still publish"
else
	report FAIL "leading-zero clock knobs fall back to defaults and still publish" "$(cat "$city/$TARGETS" 2>&1); out: $out"
fi
case "$out" in
*arithmetic* | *"not valid"* | *"value too great"*)
	report FAIL "a malformed clock knob raises no arithmetic error" "out: $out" ;;
*) report ok "a malformed clock knob raises no arithmetic error" ;;
esac
# And the fallback is reported, not silent — the operator must learn the knob
# they set is not the one in force.
case "$out" in
*read-timeout*malformed*) report ok "a malformed read timeout is named in the report" ;;
*) report FAIL "a malformed read timeout is named in the report" "out: $out" ;;
esac
rm -rf "$city"

# An out-of-range read timeout is the same class: sy_timeout refuses anything
# past 3600 and would fail EVERY read, so the knob falls back rather than
# silently blinding the pass.
city="$(new_city 3 4)"
printf 'BALANCER_RIGS="rigA"\n' >"$city/state/roster.conf"
out="$(run_sweep "$city" env BALANCER_READ_TIMEOUT=99999)"
if [ "$(target_for "$city" brakeman)" = 3 ] && [ "$(target_for "$city" reviewer)" = 4 ]; then
	report ok "an out-of-range read timeout falls back rather than failing every read"
else
	report FAIL "an out-of-range read timeout falls back rather than failing every read" "$(cat "$city/$TARGETS" 2>&1); out: $out"
fi
rm -rf "$city"

# --- the validated read timeout reaches a caller reading the roster knob's name
#
# THE MEASUREMENT PASS IS NOT ONE FUNCTION. The sibling six-stage snapshot pass
# (crit:29c92346d300, unmerged as this lands) bounds its own forge reads as
# `sy_timeout "$BALANCER_READ_TIMEOUT"` — the roster knob's own name — while
# this pass resolves that knob through sy_read_timeout into READ_TIMEOUT.
# sy_timeout treats an empty or non-numeric bound as unusable and returns 124
# WITHOUT running the command, so a knob left unset or mistyped would silently
# refuse every read in the other pass rather than bounding it. "Every external
# read carries a bounded timeout" is a property of the whole pass, so the
# validated value is published back under the name those callers already use.
#
# WHAT THIS CASE CAN SEE, AND WHAT IT CANNOT. Those sibling call sites are in
# the same SHELL as the assignment, so the plain assignment is what binds them
# and the export is belt-and-braces. But nothing in the tree reads the knob
# in-shell until that criterion merges, so the in-shell binding has no observer
# yet: a stub can only report the value it was handed as a CHILD, which is the
# export half. What that still proves is the half this case is named for — that
# the value published under the roster name is the NORMALIZED one (abc -> 15)
# and not the raw knob — because both halves publish the same value from the
# same line. When the sibling lands it brings the in-shell observer with it, and
# this case should be pointed at that instead of at the stub.
city="$(new_city 3 2)"
printf 'BALANCER_RIGS="rigA"\n' >"$city/state/roster.conf"
cat >"$city/bin/gh" <<'STUB'
#!/bin/sh
# Records the bound a co-resident caller would see, then answers as usual.
printf '%s\n' "${BALANCER_READ_TIMEOUT-<unset>}" >>"$GC_CITY/seen_bound"
for a in "$@"; do
	case "$a" in
	*reviewDecision*) cat "$GC_CITY/merge_queue.json"; exit 0 ;;
	esac
done
cat "$GC_CITY/queue.json"
STUB
chmod +x "$city/bin/gh"
out="$(run_sweep "$city" env BALANCER_READ_TIMEOUT=abc BALANCE_SWEEP_BUDGET_SECONDS=30)"
seen="$(head -n1 "$city/seen_bound" 2>/dev/null)"
if [ "$seen" = 15 ]; then
	report ok "a mistyped read timeout is normalized for co-resident callers (abc -> 15)"
else
	report FAIL "a mistyped read timeout is normalized for co-resident callers" "saw '${seen:-<none>}', wanted 15; out: $out"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
echo
echo "balance-sweep self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
