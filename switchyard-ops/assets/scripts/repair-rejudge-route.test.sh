#!/usr/bin/env bash
#
# Self-test for repair-sweep.sh's RE-JUDGE ROUTING
# (switchyard PRD #330, crit:3e5f212643ce).
#
# THE VERIFICATION CONTRACT
# -------------------------
#   "Once a repaired delivery lands, the sweep routes it to an independent judge
#    within a cycle rather than waiting for the 30m judge sweep to rediscover it"
#
# Three claims live in that sentence, and each has cases below:
#
#   ONCE A REPAIRED DELIVERY LANDS. The trigger is the delivery, not the
#   rejection and not the repair claim. A criterion rejected and still being
#   repaired must route no judge: the judge would read the rejected delivery
#   again. So every positive case first asserts there was no re-judge while the
#   repair was in flight.
#
#   ROUTES IT TO AN INDEPENDENT JUDGE. The rejecting validator is never the
#   target, however it is named (agent ref, alias, any case). When it is the only
#   live judge, a fresh session is started instead. When its ref is the lane's
#   bare agent name, which every judge session registers, no judge on the rig can
#   be independent, so the sweep mails and does not nudge a judge the server
#   will refuse. The second-rejection case checks the rule across attempts: the
#   judge that re-judged attempt N+1 and rejected it is not handed attempt N+2.
#
#   WITHIN A CYCLE, NOT THE 30m JUDGE SWEEP. No judge-sweep runs anywhere in
#   this suite. Each positive case asserts the REJUDGE assignment went out on
#   the one repair-sweep cycle that first saw the delivery, addressed to that
#   criterion by PRD and label. It also asserts the route happens once per
#   delivery, so "within a cycle" cannot become "every cycle".
#
# It runs hermetically: a throwaway city plus stub `gc`, `switchyard-mcp` and
# `curl` on PATH, answering from per-case fixtures. No real city, rig, session,
# mayor or switchyard instance is involved. Needs jq (skips without it).
#
# The scaffold is self-contained rather than shared, for the reason the
# consumption suite gives: several criteria of PRD #330 land on this one script
# from separate PRs, and an additive file collides with none of them.
#
# Run:  bash packs/switchyard-ops/assets/scripts/repair-rejudge-route.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SWEEP="$HERE/repair-sweep.sh"
ORDER="$HERE/../../orders/repair-sweep.toml"

if ! command -v jq >/dev/null 2>&1; then
	echo "SKIP — repair-rejudge-route self-test needs jq (not on PATH)"
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

# The validator that rejected the first attempt in every case unless a case says
# otherwise: an adhoc judge session's own ref, as the judge prompt registers it.
REJECTOR="rigA/switchyard-ops.judge-adhoc-old"

# ---------------------------------------------------------------------------
# Fixtures. Every case builds a FRESH city.
# ---------------------------------------------------------------------------

# new_city — scaffold a throwaway city plus stubs, and echo its path.
#
# The stub `gc` models the three session verbs this path uses:
#   session list   the roster (fails when the city holds `roster-broken`);
#   session new    records the spawn, REGISTERS the new session on the roster
#                  the way gc does (state `creating`: not yet live), and answers
#                  with gc's human sentence. It fails when `spawn-fails` exists;
#   session nudge  records target, delivery mode and message. It fails for the
#                  target named in `nudge-fails-for`.
# The stub `curl` serves the sweep's reads keyed on URL, and the event feed
# honours since_id the way the real cursor endpoint does.
new_city() {
	local city
	city="$(mktemp -d)"
	mkdir -p "$city/bin" "$city/state"

	cat >"$city/agents.json" <<'JSON'
{"agents":[{"qualified_name":"rigA/switchyard-ops.brakeman","pool":{"min":1},"suspended":false}]}
JSON
	cat >"$city/sessions.json" <<'JSON'
{"sessions":[{"template":"rigA/switchyard-ops.brakeman","agent_name":"rigA/switchyard-ops.brakeman-adhoc-stub","alias":"rigA-brakeman-adhoc-stub","state":"active","last_active":"2026-08-09T09:00:00Z"}]}
JSON
	echo '[]' >"$city/rigs.json"
	echo '[{"slug":"rigA","tenant_slug":"stub"}]' >"$city/projects.json"

	echo '{"date":"2026-08-09","retro":{"validations":[]}}' >"$city/rollup.json"
	echo '{"date":"2026-08-08","retro":{"validations":[]}}' >"$city/rollup-prev.json"
	echo '{"criteria":[]}' >"$city/criteria.json"
	echo '{"events":[]}' >"$city/events.json"

	cat >"$city/bin/gc" <<'STUB'
#!/bin/sh
case "$1 $2" in
"agent list") cat "$GC_CITY/agents.json" ;;
"rig list") cat "$GC_CITY/rigs.json" ;;
"session list")
	[ -f "$GC_CITY/roster-broken" ] && exit 1
	cat "$GC_CITY/sessions.json"
	;;
"session new")
	printf 'NEW %s\n' "$3" >>"$GC_CITY/spawned.log"
	[ -f "$GC_CITY/spawn-fails" ] && exit 1
	id="gc-judge-new$(grep -c '^NEW ' "$GC_CITY/spawned.log")"
	jq --arg id "$id" --arg t "$3" \
		'.sessions += [{template: $t, agent_name: ($t + "-adhoc-" + $id), alias: $id, state: "creating"}]' \
		"$GC_CITY/sessions.json" >"$GC_CITY/sessions.tmp" && mv "$GC_CITY/sessions.tmp" "$GC_CITY/sessions.json"
	printf 'Session %s created from template "%s" (reconciler will start it)\n' "$id" "$3"
	;;
"session nudge")
	target="$3"
	shift 3
	delivery=default
	msg=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--delivery) delivery="$2"; shift 2 ;;
		*) msg="$1"; shift ;;
		esac
	done
	[ -f "$GC_CITY/nudge-fails-for" ] && [ "$(cat "$GC_CITY/nudge-fails-for")" = "$target" ] && exit 1
	printf 'NUDGE %s %s\n' "$target" "$delivery" >>"$GC_CITY/nudged.log"
	printf '%s\n' "$msg" >>"$GC_CITY/nudged.log"
	;;
"mail send")
	subj=""; body=""
	while [ $# -gt 0 ]; do
		case "$1" in
		-s) subj="$2"; shift 2 ;;
		-m) body="$2"; shift 2 ;;
		*) shift ;;
		esac
	done
	printf 'SUBJ %s\n' "$subj" >>"$GC_CITY/mailed.log"
	printf '%s\n' "$body" >>"$GC_CITY/mail-body.log"
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
*/events?since_id=*)
	[ -f "$GC_CITY/events.json" ] || exit 22
	since="${url##*since_id=}"; since="${since%%&*}"
	jq --argjson s "$since" '{events: ([.events[] | select(.id > $s)] | sort_by(.id)),
	                          head_id: (([.events[].id] | max) // 0)}' "$GC_CITY/events.json"
	;;
*) exit 22 ;;
esac
exit 0
STUBCURL

	chmod +x "$city/bin/gc" "$city/bin/switchyard-mcp" "$city/bin/curl"
	printf '%s' "$city"
}

# add_judge CITY ALIAS AGENT_NAME [STATE] [LAST_ACTIVE] — put a judge session
# for rigA on the roster.
add_judge() {
	local t
	t="$(mktemp)"
	jq --arg a "$2" --arg n "$3" --arg s "${4:-active}" --arg la "${5:-2026-08-09T08:00:00Z}" \
		'.sessions += [{template: "rigA/switchyard-ops.judge", agent_name: $n, alias: $a, state: $s, last_active: $la}]' \
		"$1/sessions.json" >"$t" && mv "$t" "$1/sessions.json" || rm -f "$t"
}

# reject CITY PRD LABEL [VALIDATED_AT] [VALIDATOR] [PROVENANCE] — record a `fail`
# in today's rollup, by VALIDATOR, with that verdict provenance.
reject() {
	local t
	t="$(mktemp)"
	jq --argjson p "$2" --arg l "$3" --arg at "${4:-2026-08-09T10:00:00Z}" \
		--arg v "${5:-$REJECTOR}" --arg pv "${6:-judgment}" \
		'.retro.validations += [{"prd_id":$p,"crit_label":$l,"verdict":"fail","validator":$v,
		                          "validated_at":$at,"evidence_ref":"https://example.test/pull/7",
		                          "verdict_provenance":$pv}]' \
		"$1/rollup.json" >"$t" && mv "$t" "$1/rollup.json" || rm -f "$t"
}

# set_criteria CITY ROWS_JSON — REPLACE the criteria read with ROWS_JSON.
set_criteria() { jq -n --argjson rows "$2" '{criteria: $rows}' >"$1/criteria.json"; }

# crit PRD LABEL [CLAIMED_BY] [BEAD_CLOSED] — one criteria row, outstanding.
crit() {
	jq -nc --argjson p "$1" --arg l "$2" --arg c "${3:-}" --argjson bc "${4:-false}" \
		'{prd_id: $p, crit_label: $l, status: "outstanding", bead_closed: $bc}
		 + (if $c == "" then {} else {claimed_by: $c, lane: "pool"} end)'
}

# feed_event CITY TYPE PRD DETAIL — append one event to the project feed.
feed_event() {
	local t
	t="$(mktemp)"
	jq --arg ty "$2" --argjson p "$3" --arg d "$4" \
		'.events += [{id: ((([.events[].id] | max) // 0) + 1), type: $ty, prd_id: $p, detail: $d, bead_id: "", actor: "system"}]' \
		"$1/events.json" >"$t" && mv "$t" "$1/events.json" || rm -f "$t"
}

# The shell the sweep runs under; CI runs the suite a second time under dash.
REPAIR_TEST_SH="${REPAIR_TEST_SH:-sh}"

# run_sweep CITY — one repair-sweep cycle against CITY. The order script itself
# is what runs: the production entry point, not a helper sourced out of it.
run_sweep() {
	GC_CITY="$1" \
		GC_PACK_STATE_DIR="$1/state" \
		SWITCHYARD_API_TOKEN="sy_stub_token" \
		REPAIR_ASSIGNMENT_TTL=3600 \
		PATH="$1/bin:$PATH" \
		"$REPAIR_TEST_SH" "$SWEEP" >>"$1/sweep.out" 2>&1
}

# count CITY FILE PATTERN — lines of CITY/FILE matching the ERE PATTERN.
count() {
	local n
	[ -f "$1/$2" ] || { echo 0; return 0; }
	n="$(grep -Ec "$3" "$1/$2" 2>/dev/null)"
	echo "${n:-0}"
}

# rejudges CITY LABEL — how many REJUDGE assignments name LABEL.
rejudges() { count "$1" nudged.log "^REJUDGE $2 "; }
# repairs CITY LABEL — how many REPAIR assignments name LABEL.
repairs() { count "$1" nudged.log "^REPAIR $2 "; }
# spawns CITY — how many judge sessions the sweep started.
spawns() { count "$1" spawned.log '^NEW rigA/switchyard-ops.judge$'; }
# rejudge_routes CITY — `<target> <delivery> <label>` per REJUDGE assignment.
rejudge_routes() {
	[ -f "$1/nudged.log" ] || return 0
	awk '/^NUDGE /{t=$2; d=$3} /^REJUDGE /{print t, d, $2}' "$1/nudged.log"
}
# rejudge_mails CITY — how many "no independent judge" alarms were sent.
rejudge_mails() { count "$1" mailed.log 'to an independent judge'; }

# repair_in_flight CITY PRD LABEL — the lifecycle up to the delivery: rejected,
# routed to a repair worker, claimed and held (observed by a cycle). Asserts on
# the way that nothing was routed to a judge while the repair was in flight.
repair_in_flight() {
	reject "$1" "$2" "$3"
	set_criteria "$1" "[$(crit "$2" "$3")]"
	run_sweep "$1"
	set_criteria "$1" "[$(crit "$2" "$3" worker/rigA)]"
	run_sweep "$1"
}

# deliver CITY PRD LABEL — the repair worker completed: bead closed, no claim.
deliver() { set_criteria "$1" "[$(crit "$2" "$3" "" true)]"; }

# ---------------------------------------------------------------------------
# 1. POSITIVE CONTROL: a live independent judge is handed the repaired delivery
#    on the SAME cycle that first sees it land, and never before.
# ---------------------------------------------------------------------------
c="$(new_city)"
add_judge "$c" rigA-judge-live "rigA/switchyard-ops.judge-adhoc-live"
repair_in_flight "$c" 330 "crit:aaa"
if [ "$(repairs "$c" "crit:aaa")" = 1 ] && [ "$(rejudges "$c" "crit:aaa")" = 0 ]; then
	report ok "a repair in flight is routed to a worker and to no judge"
else
	report FAIL "a repair in flight is routed to a worker and to no judge" \
		"repairs $(repairs "$c" "crit:aaa") (want 1), rejudges $(rejudges "$c" "crit:aaa") (want 0)"
fi
deliver "$c" 330 "crit:aaa"
run_sweep "$c" # the ONE cycle that sees the delivery
if [ "$(rejudge_routes "$c")" = "rigA-judge-live default crit:aaa" ]; then
	report ok "the cycle that sees a repaired delivery routes it to the live independent judge"
else
	report FAIL "the cycle that sees a repaired delivery routes it to the live independent judge" \
		"routes: $(rejudge_routes "$c" | tr '\n' ';') sweep: $(tail -n 5 "$c/sweep.out")"
fi
body="$(cat "$c/nudged.log" 2>/dev/null)"
if printf '%s' "$body" | grep -q 'REJUDGE crit:aaa (PRD #330, project stub/rigA)' &&
	printf '%s' "$body" | grep -q 'claim { kind: "validation", lane: "judgment", prd_id: 330' &&
	printf '%s' "$body" | grep -qF "$REJECTOR"; then
	report ok "the re-judge assignment names the criterion, the judgment claim and the rejector"
else
	report FAIL "the re-judge assignment names the criterion, the judgment claim and the rejector" \
		"$(tail -c 900 "$c/nudged.log" 2>/dev/null)"
fi
if [ "$(spawns "$c")" = 0 ] && [ ! -s "$c/mailed.log" ]; then
	report ok "a live independent judge costs no spawn and no alarm"
else
	report FAIL "a live independent judge costs no spawn and no alarm" \
		"spawns $(spawns "$c"); $(cat "$c/mailed.log" 2>/dev/null)"
fi
# ONCE PER DELIVERY: later cycles of the same delivery route nothing more, to a
# judge or to a worker.
run_sweep "$c"
run_sweep "$c"
run_sweep "$c"
if [ "$(rejudges "$c" "crit:aaa")" = 1 ] && [ "$(repairs "$c" "crit:aaa")" = 1 ]; then
	report ok "a delivered repair is routed to a judge once, not once per cycle"
else
	report FAIL "a delivered repair is routed to a judge once, not once per cycle" \
		"rejudges $(rejudges "$c" "crit:aaa") (want 1), repairs $(repairs "$c" "crit:aaa") (want 1)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 2. INDEPENDENCE: the rejecting judge is never the target. It is the only live
#    judge here, so a fresh judge session is started and the assignment is QUEUED
#    to it (a nudge typed into a booting pane is lost), on the same cycle.
# ---------------------------------------------------------------------------
c="$(new_city)"
add_judge "$c" rigA-judge-old "$REJECTOR"
repair_in_flight "$c" 330 "crit:aaa"
deliver "$c" 330 "crit:aaa"
run_sweep "$c"
if [ "$(rejudge_routes "$c")" = "gc-judge-new1 queue crit:aaa" ] && [ "$(spawns "$c")" = 1 ]; then
	report ok "when the only live judge is the rejector, a fresh judge is started and handed it"
else
	report FAIL "when the only live judge is the rejector, a fresh judge is started and handed it" \
		"routes: $(rejudge_routes "$c" | tr '\n' ';') spawns $(spawns "$c")"
fi
if ! grep -q '^NUDGE rigA-judge-old ' "$c/nudged.log" 2>/dev/null; then
	report ok "the judge that rejected the attempt is never nudged to re-judge it"
else
	report FAIL "the judge that rejected the attempt is never nudged to re-judge it" \
		"$(grep '^NUDGE' "$c/nudged.log")"
fi
rm -rf "$c"

# 2b. The rejector is matched on EVERY identity a session carries, in any case:
#     here it recorded its gc alias, upper-cased. Two live judges; the rejector
#     is the most recently active, so a naive "warmest pane" pick would choose it.
c="$(new_city)"
add_judge "$c" rigA-judge-other "rigA/switchyard-ops.judge-adhoc-other" active "2026-08-09T07:00:00Z"
add_judge "$c" rigA-judge-warm "rigA/switchyard-ops.judge-adhoc-warm" active "2026-08-09T09:30:00Z"
reject "$c" 330 "crit:aaa" "2026-08-09T10:00:00Z" "RIGA-JUDGE-WARM"
set_criteria "$c" "[$(crit 330 "crit:aaa")]"
run_sweep "$c"
set_criteria "$c" "[$(crit 330 "crit:aaa" worker/rigA)]"
run_sweep "$c"
deliver "$c" 330 "crit:aaa"
run_sweep "$c"
if [ "$(rejudge_routes "$c")" = "rigA-judge-other default crit:aaa" ] && [ "$(spawns "$c")" = 0 ]; then
	report ok "a rejector named by alias in another case is skipped for the other live judge"
else
	report FAIL "a rejector named by alias in another case is skipped for the other live judge" \
		"routes: $(rejudge_routes "$c" | tr '\n' ';') spawns $(spawns "$c")"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 3. NO LIVE JUDGE AT ALL. The 30m judge sweep would start one eventually and
#    hand it the top of the ranked inbox. The repair sweep starts one NOW and
#    queues this criterion to it. An asleep judge is not live and is not nudged.
# ---------------------------------------------------------------------------
c="$(new_city)"
add_judge "$c" rigA-judge-asleep "rigA/switchyard-ops.judge-adhoc-asleep" asleep
repair_in_flight "$c" 330 "crit:aaa"
deliver "$c" 330 "crit:aaa"
run_sweep "$c"
if [ "$(rejudge_routes "$c")" = "gc-judge-new1 queue crit:aaa" ] && [ "$(spawns "$c")" = 1 ] &&
	[ ! -s "$c/mailed.log" ]; then
	report ok "with no live judge, one is started and handed the repair on the same cycle"
else
	report FAIL "with no live judge, one is started and handed the repair on the same cycle" \
		"routes: $(rejudge_routes "$c" | tr '\n' ';') spawns $(spawns "$c"); $(cat "$c/mailed.log" 2>/dev/null)"
fi
run_sweep "$c"
if [ "$(spawns "$c")" = 1 ] && [ "$(rejudges "$c" "crit:aaa")" = 1 ]; then
	report ok "a judge started for a repair is not started again next cycle"
else
	report FAIL "a judge started for a repair is not started again next cycle" \
		"spawns $(spawns "$c"), rejudges $(rejudges "$c" "crit:aaa")"
fi
rm -rf "$c"

# 3b. Two repairs land on one rig in one cycle: ONE judge is started and both
#     are queued to it, not one session per repair.
c="$(new_city)"
reject "$c" 330 "crit:aaa"
reject "$c" 330 "crit:bbb"
set_criteria "$c" "[$(crit 330 "crit:aaa"), $(crit 330 "crit:bbb")]"
run_sweep "$c"
set_criteria "$c" "[$(crit 330 "crit:aaa" w1), $(crit 330 "crit:bbb" w2)]"
run_sweep "$c"
set_criteria "$c" "[$(crit 330 "crit:aaa" "" true), $(crit 330 "crit:bbb" "" true)]"
run_sweep "$c"
if [ "$(spawns "$c")" = 1 ] &&
	[ "$(rejudge_routes "$c" | sort | tr '\n' ';')" = "gc-judge-new1 queue crit:aaa;gc-judge-new1 queue crit:bbb;" ]; then
	report ok "two repairs delivered in one cycle share one fresh judge"
else
	report FAIL "two repairs delivered in one cycle share one fresh judge" \
		"spawns $(spawns "$c"), routes: $(rejudge_routes "$c" | tr '\n' ';')"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 4. NO SESSION ON THE RIG CAN BE INDEPENDENT. The rejector registered as the
#    lane's bare agent name, the ref every judge session on the rig shares. The
#    server would refuse all of them, so the sweep nudges none and starts none,
#    and says so. It also routes no second repair worker.
# ---------------------------------------------------------------------------
c="$(new_city)"
add_judge "$c" rigA-judge-live "rigA/switchyard-ops.judge-adhoc-live"
reject "$c" 330 "crit:aaa" "2026-08-09T10:00:00Z" "rigA/switchyard-ops.judge"
set_criteria "$c" "[$(crit 330 "crit:aaa")]"
run_sweep "$c"
set_criteria "$c" "[$(crit 330 "crit:aaa" worker/rigA)]"
run_sweep "$c"
deliver "$c" 330 "crit:aaa"
run_sweep "$c"
if [ "$(rejudges "$c" "crit:aaa")" = 0 ] && [ "$(spawns "$c")" = 0 ] && [ "$(rejudge_mails "$c")" = 1 ] &&
	grep -q 'no-independent-judge:rigA/switchyard-ops.judge' "$c/mail-body.log" 2>/dev/null &&
	[ "$(repairs "$c" "crit:aaa")" = 1 ]; then
	report ok "a rejector holding the lane's shared ref leaves no independent judge, and mails"
else
	report FAIL "a rejector holding the lane's shared ref leaves no independent judge, and mails" \
		"rejudges $(rejudges "$c" "crit:aaa"), spawns $(spawns "$c"), mails $(rejudge_mails "$c"), repairs $(repairs "$c" "crit:aaa")"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 5. A FAILED ROUTE IS NOT SILENT AND NOT FINAL. The spawn fails: mail, nothing
#    stamped. The next cycle's spawn succeeds and routes the repair exactly once.
# ---------------------------------------------------------------------------
c="$(new_city)"
repair_in_flight "$c" 330 "crit:aaa"
deliver "$c" 330 "crit:aaa"
touch "$c/spawn-fails"
run_sweep "$c"
if [ "$(rejudges "$c" "crit:aaa")" = 0 ] && [ "$(rejudge_mails "$c")" = 1 ] &&
	grep -q 'judge-spawn-failed' "$c/mail-body.log" 2>/dev/null; then
	report ok "a judge that could not be started is mailed, not dropped"
else
	report FAIL "a judge that could not be started is mailed, not dropped" \
		"rejudges $(rejudges "$c" "crit:aaa"), mails $(rejudge_mails "$c")"
fi
rm -f "$c/spawn-fails"
run_sweep "$c"
run_sweep "$c"
if [ "$(rejudges "$c" "crit:aaa")" = 1 ] && [ "$(rejudge_mails "$c")" = 1 ]; then
	report ok "the failed route is retried next cycle and lands once"
else
	report FAIL "the failed route is retried next cycle and lands once" \
		"rejudges $(rejudges "$c" "crit:aaa") (want 1), mails $(rejudge_mails "$c") (want 1)"
fi
rm -rf "$c"

# 5b. The judge's nudge fails: same contract, keyed on the judge session.
c="$(new_city)"
add_judge "$c" rigA-judge-live "rigA/switchyard-ops.judge-adhoc-live"
repair_in_flight "$c" 330 "crit:aaa"
deliver "$c" 330 "crit:aaa"
printf 'rigA-judge-live' >"$c/nudge-fails-for"
run_sweep "$c"
rm -f "$c/nudge-fails-for"
run_sweep "$c"
run_sweep "$c"
if [ "$(rejudges "$c" "crit:aaa")" = 1 ] && [ "$(rejudge_mails "$c")" = 1 ] &&
	grep -q 'judge-nudge-failed:rigA-judge-live' "$c/mail-body.log" 2>/dev/null; then
	report ok "a judge nudge that fails is mailed and retried once"
else
	report FAIL "a judge nudge that fails is mailed and retried once" \
		"rejudges $(rejudges "$c" "crit:aaa"), mails $(rejudge_mails "$c")"
fi
rm -rf "$c"

# 5c. An unreadable roster is UNKNOWN, not "no judge": no spawn on a guess.
c="$(new_city)"
repair_in_flight "$c" 330 "crit:aaa"
deliver "$c" 330 "crit:aaa"
touch "$c/roster-broken"
run_sweep "$c"
if [ "$(spawns "$c")" = 0 ] && grep -q 'judge-lookup-failed' "$c/mail-body.log" 2>/dev/null; then
	report ok "an unreadable roster starts no judge and is mailed as unknown"
else
	report FAIL "an unreadable roster starts no judge and is mailed as unknown" \
		"spawns $(spawns "$c"); $(cat "$c/mail-body.log" 2>/dev/null | head -n 3)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 6. THE BALANCER'S JUDGE TARGET CAPS THE SPAWN. A lane throttled to 0 gets no
#    fresh session and no alarm (a decision, not a fault); the repair is routed
#    once the lane has capacity again.
# ---------------------------------------------------------------------------
c="$(new_city)"
repair_in_flight "$c" 330 "crit:aaa"
deliver "$c" 330 "crit:aaa"
printf 'version 1\ngenerated_at %s\ntarget rigA judge 0\n' "$(date +%s)" >"$c/state/balancer.targets"
run_sweep "$c"
if [ "$(spawns "$c")" = 0 ] && [ "$(rejudges "$c" "crit:aaa")" = 0 ] && [ ! -s "$c/mailed.log" ]; then
	report ok "a judge lane throttled to 0 by the balancer is not spawned into"
else
	report FAIL "a judge lane throttled to 0 by the balancer is not spawned into" \
		"spawns $(spawns "$c"), rejudges $(rejudges "$c" "crit:aaa"); $(cat "$c/mailed.log" 2>/dev/null)"
fi
rm -f "$c/state/balancer.targets"
run_sweep "$c"
if [ "$(rejudges "$c" "crit:aaa")" = 1 ]; then
	report ok "the throttled re-judge routes once the lane has capacity"
else
	report FAIL "the throttled re-judge routes once the lane has capacity" \
		"rejudges $(rejudges "$c" "crit:aaa")"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 7. A DELIVERY PROVEN ONLY BY THE FEED. A worker that staked the criterion
#    directly closes no bead. `criterion.completed` is the only record, and it
#    triggers the same same-cycle route.
# ---------------------------------------------------------------------------
c="$(new_city)"
add_judge "$c" rigA-judge-live "rigA/switchyard-ops.judge-adhoc-live"
reject "$c" 330 "crit:aaa"
set_criteria "$c" "[$(crit 330 "crit:aaa")]"
run_sweep "$c"
feed_event "$c" "criterion.claimed" 330 "criterion crit:aaa (lane pool)"
feed_event "$c" "criterion.completed" 330 "criterion crit:aaa (lane pool)"
run_sweep "$c"
if [ "$(rejudge_routes "$c")" = "rigA-judge-live default crit:aaa" ]; then
	report ok "a repair delivered through the criterion stake is routed to a judge"
else
	report FAIL "a repair delivered through the criterion stake is routed to a judge" \
		"routes: $(rejudge_routes "$c" | tr '\n' ';')"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 8. INDEPENDENCE ACROSS ATTEMPTS. The live judge re-judges attempt 2 and
#    rejects it too. The third attempt's delivery must not go back to that judge.
#    It now holds a rejection of this criterion, so a fresh judge is started.
# ---------------------------------------------------------------------------
c="$(new_city)"
add_judge "$c" rigA-judge-live "rigA/switchyard-ops.judge-adhoc-live"
repair_in_flight "$c" 330 "crit:aaa"
deliver "$c" 330 "crit:aaa"
run_sweep "$c" # rejudge 1 -> rigA-judge-live
reject "$c" 330 "crit:aaa" "2026-08-09T14:00:00Z" "rigA/switchyard-ops.judge-adhoc-live"
set_criteria "$c" "[$(crit 330 "crit:aaa")]" # the fail re-opened the bead
run_sweep "$c"                               # a new repair is routed
set_criteria "$c" "[$(crit 330 "crit:aaa" worker/two)]"
run_sweep "$c"
deliver "$c" 330 "crit:aaa"
run_sweep "$c" # rejudge 2 -> NOT rigA-judge-live
if [ "$(rejudge_routes "$c" | tr '\n' ';')" = "rigA-judge-live default crit:aaa;gc-judge-new1 queue crit:aaa;" ] &&
	[ "$(repairs "$c" "crit:aaa")" = 2 ]; then
	report ok "the judge that rejected attempt 2 is not handed attempt 3"
else
	report FAIL "the judge that rejected attempt 2 is not handed attempt 3" \
		"routes: $(rejudge_routes "$c" | tr '\n' ';') repairs $(repairs "$c" "crit:aaa")"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 9. A CONTRACT-LANE REJECTION IS NOT THE JUDGE'S. The contract validator re-runs
#    the command. The judge takes only criteria that declare none, so nudging or
#    starting one would buy a decline. No route, no spawn, no alarm.
# ---------------------------------------------------------------------------
c="$(new_city)"
add_judge "$c" rigA-judge-live "rigA/switchyard-ops.judge-adhoc-live"
reject "$c" 330 "crit:aaa" "2026-08-09T10:00:00Z" "validate-sweep/rigA" contract
set_criteria "$c" "[$(crit 330 "crit:aaa")]"
run_sweep "$c"
set_criteria "$c" "[$(crit 330 "crit:aaa" worker/rigA)]"
run_sweep "$c"
deliver "$c" 330 "crit:aaa"
run_sweep "$c"
run_sweep "$c"
if [ "$(rejudges "$c" "crit:aaa")" = 0 ] && [ "$(spawns "$c")" = 0 ] && [ ! -s "$c/mailed.log" ] &&
	[ "$(count "$c" sweep.out 'contract validator re-runs it')" = 1 ]; then
	report ok "a contract-lane repair is left to the contract validator, logged once"
else
	report FAIL "a contract-lane repair is left to the contract validator, logged once" \
		"rejudges $(rejudges "$c" "crit:aaa"), spawns $(spawns "$c"), logs $(count "$c" sweep.out 'contract validator re-runs it')"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 10. THE ORDER RUNS THIS SCRIPT. Every case above drives repair-sweep.sh
#     directly; this pins that the scheduled order is what execs it.
# ---------------------------------------------------------------------------
if grep -Eq '^exec = "\$PACK_DIR/assets/scripts/repair-sweep\.sh"$' "$ORDER" 2>/dev/null; then
	report ok "the repair-sweep order execs the script under test"
else
	report FAIL "the repair-sweep order execs the script under test" "$(grep '^exec' "$ORDER" 2>/dev/null)"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
