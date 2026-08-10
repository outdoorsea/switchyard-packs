#!/usr/bin/env bash
#
# Self-test for packs/switchyard-ops/assets/scripts/repair-sweep.sh
# (switchyard PRD #330, crit:b6ea44d544e6).
#
# THE VERIFICATION CONTRACT
# -------------------------
#   "A pack sweep notices a real rejection and routes exactly one repair
#    assignment per rejected criterion to one focused worker, and never a second
#    while the first is live."
#
# Four separable claims live in that sentence, and a suite that asserts only the
# happy path proves none of them:
#
#   NOTICES A REAL REJECTION. Not any outstanding criterion — one a judge
#   actually refused. A rejected criterion is `outstanding` with a closed bead,
#   which is byte-identical to a criterion nobody has judged yet, so a sweep
#   keyed on status would route repair work for un-reviewed deliveries. Only the
#   verdict ledger's `verdict == "fail"` separates them, and the negative cases
#   below are what stop that discrimination from rotting into "route everything".
#
#   EXACTLY ONE ... PER REJECTED CRITERION. Both halves are asserted, because
#   each alone is satisfiable by a broken sweep: "exactly one" alone is satisfied
#   by a sweep that routes one assignment per CYCLE and starves the second
#   rejection, and "per criterion" alone by a sweep that routes every criterion
#   every cycle.
#
#   NEVER A SECOND WHILE THE FIRST IS LIVE. Two independent suppressors, and the
#   suite reaches each on its own: a live CLAIM (a worker already holds the
#   repair) and a live ASSIGNMENT (we routed someone who has not claimed yet, a
#   state no read of the criterion can show).
#
#   WHILE THE FIRST IS LIVE — and not one second longer. The liveness window is
#   asserted from BOTH sides: an assignment inside its window suppresses, and an
#   assignment past it routes again. Without the second, a permanent tombstone
#   would pass every other case in this file while quietly making each criterion
#   repairable exactly once, forever.
#
# The failed-dispatch case is the one that decides whether this sweep can drop
# work silently. A nudge that fails must leave NOTHING live: if the marker were
# written before the nudge (or regardless of it), the criterion would read as
# assigned with no worker on it and the next cycle would skip it — the stall
# this order was written to remove, reintroduced by its own bookkeeping.
#
# It runs hermetically: a throwaway city plus stub `gc`, `switchyard-mcp` and
# `curl` on PATH, answering from per-case fixtures. No real city, rig, session,
# mayor or switchyard instance is involved. Needs jq (skips without it).
#
# Run:  bash packs/switchyard-ops/assets/scripts/repair-sweep.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SWEEP="$HERE/repair-sweep.sh"

if ! command -v jq >/dev/null 2>&1; then
	echo "SKIP — repair-sweep self-test needs jq (not on PATH)"
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
# Fixtures. Every case builds a FRESH city: a fixture reused across cases
# accumulates markers and nudge logs, so a later case could pass because of an
# earlier case's state rather than its own — which is the exact confusion this
# sweep's dedup logic is about, and would make the suite unable to see it.
# ---------------------------------------------------------------------------

# new_city — scaffold a throwaway city plus stubs, and echo its path.
#
# The stub `curl` serves the three reads the sweep makes, keyed on URL:
# the project list, the daily-report rollup (today, and any ?date= day), and the
# criteria read. Each is a file a case can rewrite, so a fixture reads as a
# statement about the project rather than as stub configuration.
#
# It drains stdin FIRST and unconditionally. sy_api_get pipes the Authorization
# header into `curl --config -`; a stub that never reads it leaves the producing
# `printf` holding a broken pipe, which fails the read on its SUCCESS path and
# only on hosts where the write outruns the exit.
new_city() {
	local city
	city="$(mktemp -d)"
	mkdir -p "$city/bin" "$city/state"

	# One rig, `rigA`, with a staffed brakeman pool and a live session to route to.
	cat >"$city/agents.json" <<'JSON'
{"agents":[{"qualified_name":"rigA/switchyard-ops.brakeman","pool":{"min":1},"suspended":false}]}
JSON
	cat >"$city/sessions.json" <<'JSON'
{"sessions":[{"template":"rigA/switchyard-ops.brakeman","alias":"rigA-brakeman-adhoc-stub","state":"active"}]}
JSON
	echo '[]' >"$city/rigs.json"
	echo '[{"slug":"rigA","tenant_slug":"stub"}]' >"$city/projects.json"

	# No rejections and no claims, unless a case says otherwise.
	echo '{"date":"2026-08-09","retro":{"validations":[]}}' >"$city/rollup.json"
	echo '{"date":"2026-08-08","retro":{"validations":[]}}' >"$city/rollup-prev.json"
	echo '{"criteria":[]}' >"$city/criteria.json"

	cat >"$city/bin/gc" <<'STUB'
#!/bin/sh
case "$1 $2" in
"agent list") cat "$GC_CITY/agents.json" ;;
"rig list") cat "$GC_CITY/rigs.json" ;;
"session list")
	[ -f "$GC_CITY/sessions-broken" ] && exit 1
	cat "$GC_CITY/sessions.json"
	;;
"session nudge")
	# gc session nudge <alias> <message>
	[ -f "$GC_CITY/nudge-broken" ] && exit 1
	printf 'NUDGE %s\n' "$3" >>"$GC_CITY/nudged.log"
	printf '%s\n' "$4" >>"$GC_CITY/nudged.log"
	;;
"mail send")
	subj=""
	while [ $# -gt 0 ]; do
		case "$1" in
		-s) subj="$2"; shift 2 ;;
		-m) shift 2 ;;
		*) shift ;;
		esac
	done
	printf 'SUBJ %s\n' "$subj" >>"$GC_CITY/mailed.log"
	;;
esac
exit 0
STUB

	cat >"$city/bin/switchyard-mcp" <<'STUBMCP'
#!/bin/sh
[ "$1" = token-path ] || exit 1
printf '%s\n' "$GC_CITY/tokens.json"
STUBMCP
	echo '{"switchyard.work":{"token":"sy_stub_token"}}' >"$city/tokens.json"

	cat >"$city/bin/curl" <<'STUBCURL'
#!/bin/sh
cat >/dev/null   # drain the --config payload carrying the Authorization header
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
*/api/v1/projects) cat "$GC_CITY/projects.json" ;;
*daily-report-draft?date=*) cat "$GC_CITY/rollup-prev.json" ;;
*daily-report-draft*) cat "$GC_CITY/rollup.json" ;;
*/criteria*) cat "$GC_CITY/criteria.json" ;;
*) exit 22 ;;
esac
exit 0
STUBCURL

	chmod +x "$city/bin/gc" "$city/bin/switchyard-mcp" "$city/bin/curl"
	printf '%s' "$city"
}

# reject CITY PRD LABEL [VALIDATOR] — record a judgment `fail` in today's rollup.
reject() {
	local t
	t="$(mktemp)"
	jq --argjson p "$2" --arg l "$3" --arg v "${4:-judge/stub}" \
		'.retro.validations += [{"prd_id":$p,"crit_label":$l,"verdict":"fail","validator":$v}]' \
		"$1/rollup.json" >"$t" && mv "$t" "$1/rollup.json" || rm -f "$t"
}

# validate CITY PRD LABEL — record a PASSING verdict. Must never route repair.
validate() {
	local t
	t="$(mktemp)"
	jq --argjson p "$2" --arg l "$3" \
		'.retro.validations += [{"prd_id":$p,"crit_label":$l,"verdict":"done","validator":"judge/stub"}]' \
		"$1/rollup.json" >"$t" && mv "$t" "$1/rollup.json" || rm -f "$t"
}

# criterion CITY PRD LABEL [CLAIMED_BY] — put a criterion in the criteria read,
# optionally with a LIVE claim on it.
#
# Takes the PRD for the same reason `validate` does, and emitting prd_id is not
# cosmetic: criterionTriageRow carries `json:"prd_id"` with no omitempty, so the
# real /criteria read ALWAYS sends it. A stub that omitted it modelled a payload
# the server never returns, and that is precisely what let the live-claim guard
# key on the label alone — a criterion identity the API documents as (prd_id,
# crit_label) — without any test noticing.
criterion() {
	local t
	t="$(mktemp)"
	if [ -n "${4:-}" ]; then
		jq --argjson p "$2" --arg l "$3" --arg c "$4" \
			'.criteria += [{"prd_id":$p,"crit_label":$l,"status":"outstanding","claimed_by":$c,"lane":"pool"}]' \
			"$1/criteria.json" >"$t" && mv "$t" "$1/criteria.json" || rm -f "$t"
	else
		jq --argjson p "$2" --arg l "$3" \
			'.criteria += [{"prd_id":$p,"crit_label":$l,"status":"outstanding"}]' \
			"$1/criteria.json" >"$t" && mv "$t" "$1/criteria.json" || rm -f "$t"
	fi
}

# The shell the sweep itself runs under. `sh` is dash on Debian/Ubuntu (where CI
# runs) and bash-in-posix-mode on macOS (where it is usually developed), and the
# two disagree about enough — `local`, `echo` flags, arithmetic edge cases — that
# a POSIX order can pass on one and fail on the other. REPAIR_TEST_SH lets CI run
# the suite a second time under dash explicitly, the same knob the lane suites
# take as LANE_TEST_SH.
REPAIR_TEST_SH="${REPAIR_TEST_SH:-sh}"

# run_sweep CITY [TTL] — one sweep cycle against CITY.
run_sweep() {
	GC_CITY="$1" \
		GC_PACK_STATE_DIR="$1/state" \
		SWITCHYARD_API_TOKEN="sy_stub_token" \
		REPAIR_ASSIGNMENT_TTL="${2:-3600}" \
		PATH="$1/bin:$PATH" \
		"$REPAIR_TEST_SH" "$SWEEP" >/dev/null 2>&1
}

# nudges CITY — how many assignments were routed in total.
#
# Counts the stub's NUDGE header lines, not message bodies: an assignment body
# names the criterion too, so counting matches would double every route.
#
# `grep -c` prints its count AND exits 1 when that count is zero, so the usual
# `|| echo 0` fallback would print "0" TWICE and turn every zero-assignment
# assertion into an unparseable "0 0". The count is captured and defaulted
# instead, and grep's exit status ignored.
nudges() {
	local n
	[ -f "$1/nudged.log" ] || { echo 0; return 0; }
	n="$(grep -c '^NUDGE ' "$1/nudged.log" 2>/dev/null)"
	echo "${n:-0}"
}

# routed_for CITY LABEL — how many routed assignments name LABEL. Anchored on
# the message's REPAIR header so a body mentioning a sibling criterion cannot
# count as a route to it.
routed_for() {
	local n
	[ -f "$1/nudged.log" ] || { echo 0; return 0; }
	n="$(grep -c "^REPAIR $2 " "$1/nudged.log" 2>/dev/null)"
	echo "${n:-0}"
}

# ---------------------------------------------------------------------------
# 1. POSITIVE CONTROL — load-bearing. If a real rejection did NOT route, every
#    negative case below would pass vacuously by routing nothing at all.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
criterion "$c" 330 "crit:aaa"
run_sweep "$c"
n="$(nudges "$c")"
if [ "$n" = 1 ] && [ "$(routed_for "$c" "crit:aaa")" = 1 ]; then
	report ok "a recorded judgment fail routes exactly one repair assignment"
else
	report FAIL "a recorded judgment fail routes exactly one repair assignment" \
		"routed $n assignment(s), $(routed_for "$c" "crit:aaa") naming crit:aaa"
fi

# The assignment must name the criterion AND its PRD: a worker told only "go
# repair something" has not been routed to anything.
if grep -q "REPAIR crit:aaa (PRD #330" "$c/nudged.log" 2>/dev/null; then
	report ok "the assignment names the criterion and its PRD"
else
	report FAIL "the assignment names the criterion and its PRD" \
		"$(head -c 200 "$c/nudged.log" 2>/dev/null)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 2. NEVER A SECOND WHILE THE FIRST IS LIVE — the assignment marker. A second
#    cycle over the same unchanged rejection must route nobody.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
criterion "$c" 330 "crit:aaa"
run_sweep "$c"
run_sweep "$c"
run_sweep "$c"
n="$(nudges "$c")"
if [ "$n" = 1 ]; then
	report ok "three cycles over one live assignment route it exactly once"
else
	report FAIL "three cycles over one live assignment route it exactly once" "routed $n"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 3. NEVER A SECOND WHILE THE FIRST IS LIVE — a live CLAIM. A worker already
#    holding the criterion is a repair in progress, whoever routed them.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
criterion "$c" 330 "crit:aaa" "someone/else"
run_sweep "$c"
n="$(nudges "$c")"
if [ "$n" = 0 ]; then
	report ok "a criterion under a live claim is not routed a second worker"
else
	report FAIL "a criterion under a live claim is not routed a second worker" "routed $n"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 3b. THE CLAIM GUARD IS PER-PRD, NOT PER-LABEL. crit_label hashes the criterion
#     TEXT and this read is project-wide, so two PRDs sharing a boilerplate
#     acceptance line share a label. A live claim on ONE of them must not make
#     the OTHER's rejected criterion read as held — that suppressed a real repair
#     and reported nothing, because the criterion is skipped before `failed`
#     accumulates. The pair (prd_id, crit_label) is the identity the API
#     documents; this pins the guard to it.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 331 "crit:shared"
criterion "$c" 330 "crit:shared" "someone/else" # a DIFFERENT PRD's criterion, held
criterion "$c" 331 "crit:shared"                # the rejected one, free
run_sweep "$c"
n="$(nudges "$c")"
if [ "$n" = 1 ]; then
	report ok "a live claim on one PRD does not suppress another PRD's repair"
else
	report FAIL "a live claim on one PRD does not suppress another PRD's repair" "routed $n, want 1"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 4. ONLY A REAL REJECTION. A passing verdict and an un-judged delivery are both
#    `outstanding` on the criteria read; neither is repair work.
# ---------------------------------------------------------------------------
c="$(new_city)"
validate "$c" 330 "crit:pass"
criterion "$c" 330 "crit:pass"
criterion "$c" 330 "crit:never-judged" # delivered, outstanding, no verdict at all
run_sweep "$c"
n="$(nudges "$c")"
if [ "$n" = 0 ]; then
	report ok "a passing verdict and an unjudged criterion route no repair"
else
	report FAIL "a passing verdict and an unjudged criterion route no repair" "routed $n"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 5. PER REJECTED CRITERION — two rejections get one assignment EACH, not one
#    assignment between them and not two each.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
reject "$c" 331 "crit:bbb"
criterion "$c" 330 "crit:aaa"
criterion "$c" 330 "crit:bbb"
run_sweep "$c"
a="$(routed_for "$c" "crit:aaa")"
b="$(routed_for "$c" "crit:bbb")"
if [ "$a" = 1 ] && [ "$b" = 1 ] && [ "$(nudges "$c")" = 2 ]; then
	report ok "two rejected criteria are routed one assignment each"
else
	report FAIL "two rejected criteria are routed one assignment each" \
		"crit:aaa=$a crit:bbb=$b total=$(nudges "$c")"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 6. THE WINDOW ENDS. An assignment past its liveness window is routed again —
#    otherwise the marker is a tombstone and each criterion is repairable once,
#    ever.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
criterion "$c" 330 "crit:aaa"
run_sweep "$c" 3600
run_sweep "$c" 0 # every assignment is now older than its window
n="$(nudges "$c")"
if [ "$n" = 2 ]; then
	report ok "an assignment past its liveness window is routed again"
else
	report FAIL "an assignment past its liveness window is routed again" "routed $n"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 7. A FAILED DISPATCH LEAVES NOTHING LIVE. It must mail, and the next cycle
#    must retry it — a dropped assignment that suppresses its own retry is the
#    silent stall this order exists to remove.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
criterion "$c" 330 "crit:aaa"
touch "$c/nudge-broken"
run_sweep "$c"
if grep -q '^SUBJ repair-sweep: could not route' "$c/mailed.log" 2>/dev/null; then
	report ok "a failed dispatch is mailed, not swallowed"
else
	report FAIL "a failed dispatch is mailed, not swallowed" \
		"$(cat "$c/mailed.log" 2>/dev/null)"
fi
rm -f "$c/nudge-broken"
run_sweep "$c"
n="$(nudges "$c")"
if [ "$n" = 1 ]; then
	report ok "the cycle after a failed dispatch retries the assignment"
else
	report FAIL "the cycle after a failed dispatch retries the assignment" "routed $n"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 8. NO WORKER TO ROUTE TO IS AN ALARM, NOT SILENCE. A rejection with nobody to
#    hand it to is exactly the stall this sweep reports on.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
criterion "$c" 330 "crit:aaa"
echo '{"sessions":[]}' >"$c/sessions.json"
run_sweep "$c"
if grep -q 'no-live-worker\|could not route' "$c/mailed.log" 2>/dev/null; then
	report ok "a rejection with no live worker is mailed"
else
	report FAIL "a rejection with no live worker is mailed" \
		"$(cat "$c/mailed.log" 2>/dev/null)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 9. A CLEAN CITY IS SILENT. No rejections anywhere means no assignments and no
#    mail — a sweep that alarms on a healthy city has only moved the noise.
# ---------------------------------------------------------------------------
c="$(new_city)"
criterion "$c" 330 "crit:aaa"
run_sweep "$c"
if [ "$(nudges "$c")" = 0 ] && [ ! -s "$c/mailed.log" ]; then
	report ok "a city with no rejections routes nothing and mails nothing"
else
	report FAIL "a city with no rejections routes nothing and mails nothing" \
		"routed $(nudges "$c"), mail: $(cat "$c/mailed.log" 2>/dev/null)"
fi
rm -rf "$c"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
