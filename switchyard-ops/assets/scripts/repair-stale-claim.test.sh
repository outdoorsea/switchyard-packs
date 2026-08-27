#!/usr/bin/env bash
#
# Self-test for repair-sweep.sh's LAPSED-STAKE handling
# (switchyard PRD #330, crit:f6de67fd022f).
#
# THE VERIFICATION CONTRACT
# -------------------------
#   "A repair claim whose lease expired returns to the repair queue exactly
#    once, so a dead worker's stake neither strands the repair nor multiplies
#    it."
#
# Its siblings pin that a rejection is routed ONCE (repair-sweep.test.sh) and
# that an assignment nobody claimed is re-routed AND alarmed
# (repair-consumption.test.sh). This suite pins the case between them: the
# assignment WAS claimed, and then the worker died. The lease expired, the
# server's reclaim sweep freed the stake, and to the sweep the criterion now
# reads exactly as it did before anyone was routed — no live claim, still
# `outstanding`, marker on disk. Three separable claims live in the sentence:
#
#   RETURNS TO THE QUEUE. Not stranded. A sweep that keeps a consumed marker as
#   a tombstone, or that waits out the assignment window before it looks again,
#   leaves a criterion a judge refused with nobody on it — for a window, or for
#   ever. The positive control below, and the window-bypass case, are what stop
#   "never route a second worker" from rotting into "never route again".
#
#   EXACTLY ONCE. Not multiplied. Two ways to multiply, and each has a case:
#   re-routing the SAME lapse on every subsequent cycle (the fresh marker must
#   suppress it), and re-routing a repair whose worker DELIVERED — a closed bead
#   with no live claim looks identical to a lapse on the criteria read, and the
#   old code put one fresh worker per TTL onto work already waiting for a judge.
#
#   A DEAD WORKER'S STAKE. Distinguished from an IGNORED assignment, which is
#   the consumption suite's fault: that one alarms and tells the retry "no claim
#   was ever taken". A lease that expired is neither — the claim WAS taken — so
#   it is returned quietly with a note saying a prior holder existed. The
#   discriminator has two sources, and both are exercised: the `consumed` stamp
#   a cycle writes while it can see the lease, and the project event feed's
#   `criterion.reclaimed` / `bead.reclaimed` for a lease that began and ended
#   between two cycles, which no stamp can record.
#
# It runs hermetically: a throwaway city plus stub `gc`, `switchyard-mcp` and
# `curl` on PATH, answering from per-case fixtures. No real city, rig, session,
# mayor or switchyard instance is involved. Needs jq (skips without it).
#
# The scaffold is self-contained rather than shared, for the reason the
# consumption suite gives: several criteria of PRD #330 land on this one script
# from separate PRs, and an additive file collides with none of them.
#
# Run:  bash packs/switchyard-ops/assets/scripts/repair-stale-claim.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SWEEP="$HERE/repair-sweep.sh"

if ! command -v jq >/dev/null 2>&1; then
	echo "SKIP — repair-stale-claim self-test needs jq (not on PATH)"
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
# Fixtures. Every case builds a FRESH city: markers, stamps and nudge logs are
# exactly the state this suite reasons about.
# ---------------------------------------------------------------------------

# new_city — scaffold a throwaway city plus stubs, and echo its path.
#
# The stub `curl` serves the sweep's reads keyed on URL, and the EVENT FEED read
# honours `since_id` the way the real cursor endpoint does — events with an id
# above the cursor only, ascending, plus the feed head. That is not stub
# fidelity for its own sake: the "exactly once" cases depend on the re-route's
# fresh marker anchoring PAST the reclaim event, and a stub that replayed the
# whole feed on every read would let a sweep that re-routes every cycle pass
# them. A city with no events.json answers the feed read with a failure (curl
# exit 22), which is the "feed unreadable" fallback several cases lean on.
#
# It drains stdin first: sy_api_get pipes the Authorization header into
# `curl --config -`, and a stub that never reads it breaks the producing printf.
new_city() {
	local city
	city="$(mktemp -d)"
	mkdir -p "$city/bin" "$city/state"

	cat >"$city/agents.json" <<'JSON'
{"agents":[{"qualified_name":"rigA/switchyard-ops.brakeman","pool":{"min":1},"suspended":false}]}
JSON
	cat >"$city/sessions.json" <<'JSON'
{"sessions":[{"template":"rigA/switchyard-ops.brakeman","alias":"rigA-brakeman-adhoc-stub","state":"active"}]}
JSON
	echo '[]' >"$city/rigs.json"
	echo '[{"slug":"rigA","tenant_slug":"stub"}]' >"$city/projects.json"

	echo '{"date":"2026-08-09","retro":{"validations":[]}}' >"$city/rollup.json"
	echo '{"date":"2026-08-08","retro":{"validations":[]}}' >"$city/rollup-prev.json"
	echo '{"criteria":[]}' >"$city/criteria.json"

	cat >"$city/bin/gc" <<'STUB'
#!/bin/sh
case "$1 $2" in
"agent list") cat "$GC_CITY/agents.json" ;;
"rig list") cat "$GC_CITY/rigs.json" ;;
"session list") cat "$GC_CITY/sessions.json" ;;
"session nudge")
	printf 'NUDGE %s\n' "$3" >>"$GC_CITY/nudged.log"
	printf '%s\n' "$4" >>"$GC_CITY/nudged.log"
	printf '%s\n----\n' "$4" >>"$GC_CITY/nudge-bodies.log"
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
	printf 'EVENTS since=%s\n' "$since" >>"$GC_CITY/feed-reads.log"
	jq --argjson s "$since" '{events: ([.events[] | select(.id > $s)] | sort_by(.id)),
	                          head_id: (([.events[].id] | max) // 0)}' "$GC_CITY/events.json"
	;;
*) exit 22 ;;
esac
exit 0
STUBCURL

	chmod +x "$city/bin/gc" "$city/bin/switchyard-mcp" "$city/bin/curl"
	echo '{"events":[]}' >"$city/events.json"
	printf '%s' "$city"
}

# reject CITY PRD LABEL [VALIDATED_AT] — record a judgment `fail` in today's
# rollup. VALIDATED_AT is the verdict's timestamp, which the real rollup always
# carries; the re-rejection case bumps it to model a SECOND fail on the same
# criterion, which the sweep tells from a replayed one by that field alone.
reject() {
	local t
	t="$(mktemp)"
	jq --argjson p "$2" --arg l "$3" --arg at "${4:-2026-08-09T10:00:00Z}" \
		'.retro.validations += [{"prd_id":$p,"crit_label":$l,"verdict":"fail","validator":"judge/stub","validated_at":$at}]' \
		"$1/rollup.json" >"$t" && mv "$t" "$1/rollup.json" || rm -f "$t"
}

# set_criteria CITY PRD LABEL [CLAIMED_BY] [STATUS] [BEAD_CLOSED] — REPLACE the
# criteria read. Replaces rather than appends, because these cases are about
# one criterion changing state across cycles. Carries prd_id because the real
# read always does and the sweep keys on the (prd_id, crit_label) pair.
set_criteria() {
	local city="$1" prd="$2" label="$3" claimed="${4:-}" status="${5:-outstanding}" closed="${6:-false}"
	if [ -n "$claimed" ]; then
		jq -n --argjson p "$prd" --arg l "$label" --arg c "$claimed" --arg s "$status" --argjson bc "$closed" \
			'{criteria:[{prd_id:$p,crit_label:$l,status:$s,claimed_by:$c,lane:"pool",bead_closed:$bc}]}' \
			>"$city/criteria.json"
	else
		jq -n --argjson p "$prd" --arg l "$label" --arg s "$status" --argjson bc "$closed" \
			'{criteria:[{prd_id:$p,crit_label:$l,status:$s,bead_closed:$bc}]}' \
			>"$city/criteria.json"
	fi
}

# feed_event CITY TYPE PRD DETAIL [BEAD_ID] — append one event to the project
# feed, with the next id. Models the two families the server writes: the
# criterion-claim API's `criterion.*` (scoped to the PRD, label in the detail)
# and the pool's `bead.*` (keyed on the bead id).
feed_event() {
	local t
	t="$(mktemp)"
	jq --arg ty "$2" --argjson p "$3" --arg d "$4" --arg b "${5:-}" \
		'.events += [{id: ((([.events[].id] | max) // 0) + 1), type: $ty, prd_id: $p, detail: $d, bead_id: $b, actor: "system"}]' \
		"$1/events.json" >"$t" && mv "$t" "$1/events.json" || rm -f "$t"
}

# The shell the sweep runs under; CI runs the suite a second time under dash.
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

# routed_for CITY LABEL — how many routed assignments name LABEL.
routed_for() {
	local n
	[ -f "$1/nudged.log" ] || { echo 0; return 0; }
	n="$(grep -c "^REPAIR $2 " "$1/nudged.log" 2>/dev/null)"
	echo "${n:-0}"
}

# unconsumed_mails CITY — how many "never consumed" alarms were sent.
unconsumed_mails() {
	local n
	[ -f "$1/mailed.log" ] || { echo 0; return 0; }
	n="$(grep -c 'never consumed' "$1/mailed.log" 2>/dev/null)"
	echo "${n:-0}"
}

# lapse_notes CITY — how many assignments told their worker a prior stake ended.
lapse_notes() {
	local n
	[ -f "$1/nudged.log" ] || { echo 0; return 0; }
	n="$(grep -c 'A worker already held this repair' "$1/nudged.log" 2>/dev/null)"
	echo "${n:-0}"
}

# marker CITY — the one marker file for crit:aaa on PRD 330, or nothing.
marker() { ls "$1/state/repair-assignments"/prd330-crit-aaa 2>/dev/null; }

# ---------------------------------------------------------------------------
# 1. POSITIVE CONTROL — an OBSERVED lapse. Routed; a cycle sees the lease live;
#    the worker dies; the lease is reclaimed. The next cycle must return the
#    repair to the queue: routed a second time, and told it is the second
#    holder. This city has NO readable feed (events.json removed), so the
#    decision rests on the `consumed` stamp alone — the fallback that must fail
#    toward the queue.
#
#    Load-bearing: if a lapse did not re-route, every "not multiplied" case
#    below would pass vacuously by routing nothing at all.
# ---------------------------------------------------------------------------
c="$(new_city)"
rm -f "$c/events.json"
reject "$c" 330 "crit:aaa"
set_criteria "$c" 330 "crit:aaa"
run_sweep "$c" 3600                            # routed
set_criteria "$c" 330 "crit:aaa" "worker/rigA" # the worker takes the claim
run_sweep "$c" 3600                            # this cycle observes the lease
set_criteria "$c" 330 "crit:aaa"               # worker died; lease reclaimed
run_sweep "$c" 3600                            # lapse observed
if [ "$(routed_for "$c" "crit:aaa")" = 2 ]; then
	report ok "a lapsed stake returns the repair to the queue"
else
	report FAIL "a lapsed stake returns the repair to the queue" \
		"routed $(routed_for "$c" "crit:aaa") time(s), want 2"
fi
if [ "$(lapse_notes "$c")" = 1 ]; then
	report ok "the returned assignment tells its worker a prior holder existed"
else
	report FAIL "the returned assignment tells its worker a prior holder existed" \
		"$(tail -c 400 "$c/nudged.log" 2>/dev/null)"
fi
# A lapse is not an ignored assignment: the claim WAS taken.
if [ "$(unconsumed_mails "$c")" = 0 ] && ! grep -q 'no claim was ever taken' "$c/nudged.log" 2>/dev/null; then
	report ok "a lapsed stake is not reported as an ignored assignment"
else
	report FAIL "a lapsed stake is not reported as an ignored assignment" \
		"mails=$(unconsumed_mails "$c"); $(cat "$c/mailed.log" 2>/dev/null)"
fi
# EXACTLY ONCE. The same lapse must not be returned again on the next cycle:
# the fresh marker is inside its window and nothing has ended since.
run_sweep "$c" 3600
run_sweep "$c" 3600
if [ "$(routed_for "$c" "crit:aaa")" = 2 ]; then
	report ok "the same lapse is not returned to the queue a second time"
else
	report FAIL "the same lapse is not returned to the queue a second time" \
		"routed $(routed_for "$c" "crit:aaa") time(s), want 2"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 2. THE RETURN DOES NOT WAIT OUT THE WINDOW. The assignment window measures a
#    worker who has not claimed YET; a stake that ended is not that. With a
#    window far longer than the cycle, a lapse must still route on the cycle
#    that observes it — otherwise a long TTL strands every dead worker's repair
#    for the rest of it.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
set_criteria "$c" 330 "crit:aaa"
run_sweep "$c" 999999
set_criteria "$c" 330 "crit:aaa" "worker/rigA"
run_sweep "$c" 999999
set_criteria "$c" 330 "crit:aaa"
run_sweep "$c" 999999
if [ "$(routed_for "$c" "crit:aaa")" = 2 ]; then
	report ok "a lapse is returned inside the assignment window, not after it"
else
	report FAIL "a lapse is returned inside the assignment window, not after it" \
		"routed $(routed_for "$c" "crit:aaa") time(s), want 2"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 3. AN UNOBSERVED LAPSE — the lease began and ended between two cycles, so no
#    stamp exists. Before this shipped that was misreported as an IGNORED
#    assignment (alarm + "no claim was ever taken"). The feed's reclaim event
#    is the record that a claim existed and died; it must produce a quiet
#    return with the lapse note, and exactly one of it.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
set_criteria "$c" 330 "crit:aaa"
run_sweep "$c" 3600 # routed; marker anchored at feed head 0
feed_event "$c" "criterion.claimed" 330 "criterion crit:aaa (lane pool)"
feed_event "$c" "criterion.reclaimed" 330 "criterion crit:aaa lease expired; reclaimed from worker/rigA (lane pool)"
run_sweep "$c" 0 # window closed, no stamp — only the feed knows
if [ "$(routed_for "$c" "crit:aaa")" = 2 ] && [ "$(lapse_notes "$c")" = 1 ]; then
	report ok "a lapse the sweep never observed is read from the feed and returned once"
else
	report FAIL "a lapse the sweep never observed is read from the feed and returned once" \
		"routed $(routed_for "$c" "crit:aaa"), notes $(lapse_notes "$c")"
fi
if [ "$(unconsumed_mails "$c")" = 0 ]; then
	report ok "a feed-recorded lapse raises no ignored-assignment alarm"
else
	report FAIL "a feed-recorded lapse raises no ignored-assignment alarm" \
		"$(cat "$c/mailed.log" 2>/dev/null)"
fi
# The fresh marker anchors PAST the reclaim event, so the next cycle — even
# with the window closed and still no claim — sees nothing ended and falls to
# the consumption path, which is the ignored-assignment alarm this time (the
# retry itself was not taken). What it must NOT do is read the old reclaim
# again and return the repair a third time as a lapse.
run_sweep "$c" 0
if [ "$(lapse_notes "$c")" = 1 ]; then
	report ok "a reclaim already acted on is not re-read as a fresh lapse"
else
	report FAIL "a reclaim already acted on is not re-read as a fresh lapse" \
		"lapse notes $(lapse_notes "$c"), want 1"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 3b. THE FEED MATCH IS KEYED. A reclaim of a DIFFERENT criterion — or of this
#     label on a different PRD, since crit_label hashes the criterion TEXT and
#     boilerplate lines collide — is not this assignment's lapse. Without the
#     key, any reclaim anywhere in the project would quietly convert every
#     ignored assignment into a "lapse" and silence the consumption alarm.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
set_criteria "$c" 330 "crit:aaa"
run_sweep "$c" 3600
feed_event "$c" "criterion.reclaimed" 330 "criterion crit:aaab lease expired; reclaimed from x (lane pool)"
feed_event "$c" "criterion.reclaimed" 331 "criterion crit:aaa lease expired; reclaimed from x (lane pool)"
feed_event "$c" "bead.reclaimed" 331 "lease expired; reclaimed from x" "prd-331-aaa"
run_sweep "$c" 0
if [ "$(lapse_notes "$c")" = 0 ] && [ "$(unconsumed_mails "$c")" = 1 ]; then
	report ok "another criterion's reclaim is not this assignment's lapse"
else
	report FAIL "another criterion's reclaim is not this assignment's lapse" \
		"lapse notes $(lapse_notes "$c"), mails $(unconsumed_mails "$c")"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 3c. THE POOL LANE'S RECLAIM COUNTS TOO. A conductor holds the criterion by
#     claiming its pool BEAD, and a dead conductor's lease is reclaimed as
#     `bead.reclaimed` keyed on the deterministic bead id — no `criterion.*`
#     event, no label in the detail.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
set_criteria "$c" 330 "crit:aaa"
run_sweep "$c" 3600
feed_event "$c" "bead.reclaimed" 330 "lease expired mid-progress; reclaimed from conductor/x" "prd-330-aaa"
run_sweep "$c" 0
if [ "$(routed_for "$c" "crit:aaa")" = 2 ] && [ "$(lapse_notes "$c")" = 1 ] && [ "$(unconsumed_mails "$c")" = 0 ]; then
	report ok "a pool bead reclaim is read as this criterion's lapse"
else
	report FAIL "a pool bead reclaim is read as this criterion's lapse" \
		"routed $(routed_for "$c" "crit:aaa"), notes $(lapse_notes "$c"), mails $(unconsumed_mails "$c")"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 4. NOT MULTIPLIED — A DELIVERED REPAIR. The worker claimed, repaired, and
#    completed: the bead is closed and the criterion waits on a judge. On the
#    criteria read that is byte-identical to a lapse (no live claim, still
#    `outstanding`). It must route NOBODY, on this cycle or any later one, and
#    alarm on nothing — the old code put one fresh worker per TTL on it.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
set_criteria "$c" 330 "crit:aaa"
run_sweep "$c" 3600
set_criteria "$c" 330 "crit:aaa" "worker/rigA"
run_sweep "$c" 3600
set_criteria "$c" 330 "crit:aaa" "" outstanding true # delivered; awaiting the judge
run_sweep "$c" 0
run_sweep "$c" 0
run_sweep "$c" 0
if [ "$(routed_for "$c" "crit:aaa")" = 1 ] && [ ! -s "$c/mailed.log" ]; then
	report ok "a delivered repair awaiting its judge is never re-routed"
else
	report FAIL "a delivered repair awaiting its judge is never re-routed" \
		"routed $(routed_for "$c" "crit:aaa"), mail: $(cat "$c/mailed.log" 2>/dev/null)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 4b. DELIVERED, PROVEN BY THE FEED. A worker that staked the criterion
#     directly (no pool bead) completes through the criterion-claim API, which
#     closes no bead — only `criterion.completed` on the feed records it. The
#     same lapse-shaped read, the same answer: route nobody.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
set_criteria "$c" 330 "crit:aaa"
run_sweep "$c" 3600
feed_event "$c" "criterion.claimed" 330 "criterion crit:aaa (lane pool)"
feed_event "$c" "criterion.completed" 330 "criterion crit:aaa (lane pool)"
run_sweep "$c" 0
run_sweep "$c" 0
if [ "$(routed_for "$c" "crit:aaa")" = 1 ] && [ ! -s "$c/mailed.log" ]; then
	report ok "a completion on the feed is a delivery, not a lapse"
else
	report FAIL "a completion on the feed is a delivery, not a lapse" \
		"routed $(routed_for "$c" "crit:aaa"), mail: $(cat "$c/mailed.log" 2>/dev/null)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 4c. THE NEWEST EVENT DECIDES. A stake that lapsed, was re-taken, and was then
#     completed is a delivery — the reclaim in its history is not a licence to
#     route a worker onto finished work.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
set_criteria "$c" 330 "crit:aaa"
run_sweep "$c" 3600
feed_event "$c" "criterion.reclaimed" 330 "criterion crit:aaa lease expired; reclaimed from a (lane pool)"
feed_event "$c" "criterion.claimed" 330 "criterion crit:aaa (lane pool)"
feed_event "$c" "criterion.completed" 330 "criterion crit:aaa (lane pool)"
run_sweep "$c" 0
if [ "$(routed_for "$c" "crit:aaa")" = 1 ]; then
	report ok "a lapse followed by a completion reads as delivered"
else
	report FAIL "a lapse followed by a completion reads as delivered" \
		"routed $(routed_for "$c" "crit:aaa"), want 1"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 5. NOT STRANDED AFTER A DELIVERY — A SECOND REJECTION. The delivered marker
#    must not hold forever: when the judge fails the repair again, the rollup
#    carries a NEWER verdict, and that is a new repair which routes afresh —
#    once, and as a first assignment (no "prior holder" note: the prior holder
#    delivered).
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa" "2026-08-09T10:00:00Z"
set_criteria "$c" 330 "crit:aaa"
run_sweep "$c" 3600
set_criteria "$c" 330 "crit:aaa" "worker/rigA"
run_sweep "$c" 3600
set_criteria "$c" 330 "crit:aaa" "" outstanding true # delivered
run_sweep "$c" 0                                    # judge's turn; marker stamped delivered
# The judge rules against it again: a newer fail, and the bead re-opened.
reject "$c" 330 "crit:aaa" "2026-08-09T14:00:00Z"
set_criteria "$c" 330 "crit:aaa"
run_sweep "$c" 0
run_sweep "$c" 3600
if [ "$(routed_for "$c" "crit:aaa")" = 2 ] && [ "$(lapse_notes "$c")" = 0 ]; then
	report ok "a second rejection after a delivered repair routes afresh, once"
else
	report FAIL "a second rejection after a delivered repair routes afresh, once" \
		"routed $(routed_for "$c" "crit:aaa") (want 2), lapse notes $(lapse_notes "$c") (want 0)"
fi
rm -rf "$c"

# The replayed SAME verdict is not a second rejection. The rollup buckets a
# calendar day and is read for two, so the fail that routed the assignment
# reappears on every cycle for up to 48h; a delivered marker must hold through
# all of them.
c="$(new_city)"
reject "$c" 330 "crit:aaa" "2026-08-09T10:00:00Z"
set_criteria "$c" 330 "crit:aaa"
run_sweep "$c" 3600
set_criteria "$c" 330 "crit:aaa" "worker/rigA"
run_sweep "$c" 3600
set_criteria "$c" 330 "crit:aaa" "" outstanding true
run_sweep "$c" 0
run_sweep "$c" 0
if [ "$(routed_for "$c" "crit:aaa")" = 1 ]; then
	report ok "a replayed verdict does not retire a delivered marker"
else
	report FAIL "a replayed verdict does not retire a delivered marker" \
		"routed $(routed_for "$c" "crit:aaa"), want 1"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 6. THE WHOLE LIFECYCLE, ONCE. Lapse → returned → the second holder claims →
#    delivers. Three states that each look like "no claim, outstanding" at
#    some point, and exactly two routes across all of them.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
set_criteria "$c" 330 "crit:aaa"
run_sweep "$c" 3600                              # 1st route
set_criteria "$c" 330 "crit:aaa" "worker/one"    # first holder
run_sweep "$c" 3600
set_criteria "$c" 330 "crit:aaa"                 # died; reclaimed
run_sweep "$c" 3600                              # 2nd route (the lapse)
set_criteria "$c" 330 "crit:aaa" "worker/two"    # second holder
run_sweep "$c" 3600
set_criteria "$c" 330 "crit:aaa" "" outstanding true # delivered
run_sweep "$c" 0
run_sweep "$c" 0
if [ "$(routed_for "$c" "crit:aaa")" = 2 ] && [ "$(unconsumed_mails "$c")" = 0 ]; then
	report ok "lapse, return, re-claim and delivery cost exactly two routes"
else
	report FAIL "lapse, return, re-claim and delivery cost exactly two routes" \
		"routed $(routed_for "$c" "crit:aaa"), mails $(unconsumed_mails "$c")"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 7. A RELEASED STAKE IS RETURNED TOO. A worker that gave the repair back with
#    a handoff is not dead, but the repair is just as unheld. Same return, its
#    own wording, and the note points at the handoff.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
set_criteria "$c" 330 "crit:aaa"
run_sweep "$c" 3600
feed_event "$c" "criterion.claimed" 330 "criterion crit:aaa (lane pool)"
feed_event "$c" "criterion.released" 330 "criterion crit:aaa (lane pool)"
run_sweep "$c" 0
if [ "$(routed_for "$c" "crit:aaa")" = 2 ] && grep -q 'released it without a delivery' "$c/nudged.log" 2>/dev/null &&
	[ "$(unconsumed_mails "$c")" = 0 ]; then
	report ok "a released stake is returned once and the note names the handoff"
else
	report FAIL "a released stake is returned once and the note names the handoff" \
		"routed $(routed_for "$c" "crit:aaa"), mails $(unconsumed_mails "$c")"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 8. A MARKER FROM BEFORE THIS SHIPPED. Two fields on line 1 and a `consumed`
#    stamp — no feed anchor, no verdict anchor. It must still return the lapse
#    once rather than error or strand: the stamp fallback carries it.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
set_criteria "$c" 330 "crit:aaa"
mkdir -p "$c/state/repair-assignments"
printf '%s rigA-brakeman-adhoc-stub\nconsumed %s\n' "$(($(date +%s) - 7200))" "$(($(date +%s) - 3600))" \
	>"$c/state/repair-assignments/prd330-crit-aaa"
run_sweep "$c" 3600
run_sweep "$c" 3600
if [ "$(routed_for "$c" "crit:aaa")" = 1 ] && [ "$(lapse_notes "$c")" = 1 ]; then
	report ok "a pre-existing two-field marker still returns a lapse exactly once"
else
	report FAIL "a pre-existing two-field marker still returns a lapse exactly once" \
		"routed $(routed_for "$c" "crit:aaa"), notes $(lapse_notes "$c")"
fi
# ...and the marker it rewrote carries the new anchors for the next lapse.
if [ "$(awk 'NR==1{print NF}' "$(marker "$c")" 2>/dev/null)" = 4 ]; then
	report ok "the rewritten marker carries the feed and verdict anchors"
else
	report FAIL "the rewritten marker carries the feed and verdict anchors" \
		"$(cat "$(marker "$c")" 2>/dev/null)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 9. A CLEAN CITY IS SILENT AND STILL. No rejection: no routes, no mail, no
#    feed read — the lapse check runs only for an assignment that exists.
# ---------------------------------------------------------------------------
c="$(new_city)"
set_criteria "$c" 330 "crit:aaa"
feed_event "$c" "criterion.reclaimed" 330 "criterion crit:aaa lease expired; reclaimed from x (lane pool)"
run_sweep "$c" 0
if [ "$(routed_for "$c" "crit:aaa")" = 0 ] && [ ! -s "$c/mailed.log" ]; then
	report ok "a reclaim on a criterion nobody rejected routes nothing"
else
	report FAIL "a reclaim on a criterion nobody rejected routes nothing" \
		"routed $(routed_for "$c" "crit:aaa"), mail: $(cat "$c/mailed.log" 2>/dev/null)"
fi
rm -rf "$c"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
