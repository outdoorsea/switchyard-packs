#!/usr/bin/env bash
#
# Self-test for repair-sweep.sh's ASSIGNMENT CONSUMPTION check
# (switchyard PRD #330, crit:77cdace10626).
#
# THE VERIFICATION CONTRACT
# -------------------------
#   "The sweep verifies the worker actually consumed the assignment: an
#    assignment that has not become a held lease within one cycle is re-routed
#    and mailed, never silently dropped."
#
# Its sibling suite (repair-sweep.test.sh) pins that a rejection is routed ONCE.
# This one pins what happens when that route lands on nobody — a separate
# failure, because every read involved reports success: the nudge exits 0, the
# marker is written, and the cycle ends having "routed" an assignment that no
# worker ever picked up.
#
# Four separable claims live in that sentence:
#
#   VERIFIES ... ACTUALLY CONSUMED. A verification asserted in one direction is
#   not a verification. A check that reports every expired assignment passes the
#   positive case while being unable to tell an ignored assignment from a repair
#   that ran and finished, so the consumed cases below are load-bearing rather
#   than defensive: they are the only thing standing between this alarm and a
#   mail on every completed repair in the project.
#
#   HAS NOT BECOME A HELD LEASE. The evidence is a LEASE, not a nudge exit code
#   and not a criterion status. `gc session nudge` returning 0 says a session
#   accepted a message; it says nothing about a wedged, compacting or inattentive
#   worker on the other end.
#
#   WITHIN ONE CYCLE. Asserted from both sides. An assignment inside its window
#   is not yet a drop — reporting it there would alarm on every healthy repair in
#   the minutes between the nudge and the claim, which is the normal case.
#
#   RE-ROUTED AND MAILED, NEVER SILENTLY DROPPED. Both halves, and mail that is
#   actionable. Re-routing alone is silent by construction: the same dead worker
#   absorbs one assignment per cycle forever and every cycle exits 0. Mail alone
#   leaves the criterion sitting refused with nobody on it. And the alarm must be
#   DISTINCT from the "could not route" mail, or the fault where a worker was
#   reached and ignored it hides behind the fault where none could be reached.
#
# It runs hermetically: a throwaway city plus stub `gc`, `switchyard-mcp` and
# `curl` on PATH, answering from per-case fixtures. No real city, rig, session,
# mayor or switchyard instance is involved. Needs jq (skips without it).
#
# The city scaffold is deliberately self-contained rather than shared with
# repair-sweep.test.sh: four criteria of PRD #330 land on this one script from
# separate PRs, and an additive file collides with none of them.
#
# Run:  bash packs/switchyard-ops/assets/scripts/repair-consumption.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SWEEP="$HERE/repair-sweep.sh"

if ! command -v jq >/dev/null 2>&1; then
	echo "SKIP — repair-consumption self-test needs jq (not on PATH)"
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
# Fixtures. Every case builds a FRESH city: markers and nudge logs are exactly
# the state this suite reasons about, so a reused fixture would let a later case
# pass on an earlier case's stamp rather than its own.
# ---------------------------------------------------------------------------

# new_city — scaffold a throwaway city plus stubs, and echo its path.
#
# The `gc` stub records mail BODIES as well as subjects, which the sibling suite
# does not need: "mailed" is only half this contract — an alarm that does not
# name the criterion or the session that ignored it cannot be acted on, and a
# subject-only assertion could not tell the difference.
#
# The stub `curl` drains stdin FIRST and unconditionally: sy_api_get pipes the
# Authorization header into `curl --config -`, and a stub that never reads it
# leaves the producing `printf` on a broken pipe — failing the read on its
# SUCCESS path, and only on hosts where the write outruns the exit.
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
"session list")
	[ -f "$GC_CITY/sessions-broken" ] && exit 1
	cat "$GC_CITY/sessions.json"
	;;
"session nudge")
	[ -f "$GC_CITY/nudge-broken" ] && exit 1
	printf 'NUDGE %s\n' "$3" >>"$GC_CITY/nudged.log"
	printf '%s\n' "$4" >>"$GC_CITY/nudged.log"
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
*) exit 22 ;;
esac
exit 0
STUBCURL

	chmod +x "$city/bin/gc" "$city/bin/switchyard-mcp" "$city/bin/curl"
	printf '%s' "$city"
}

# reject CITY PRD LABEL — record a judgment `fail` in today's rollup.
reject() {
	local t
	t="$(mktemp)"
	jq --argjson p "$2" --arg l "$3" \
		'.retro.validations += [{"prd_id":$p,"crit_label":$l,"verdict":"fail","validator":"judge/stub"}]' \
		"$1/rollup.json" >"$t" && mv "$t" "$1/rollup.json" || rm -f "$t"
}

# set_criteria CITY PRD LABEL [CLAIMED_BY] [STATUS] — REPLACE the criteria read.
#
# Replaces rather than appends, because these cases are about one criterion
# changing state across cycles — a claim appearing and then ending — and an
# appending helper would leave the stale row in front of the new one for
# jq's `.[0]` to find.
#
# TAKES THE PRD, AND EMITTING prd_id IS NOT COSMETIC — the same reason the
# routing suite's `criterion` helper does. criterionTriageRow carries
# `json:"prd_id"` with no omitempty, so the real /criteria read ALWAYS sends it;
# a stub that omitted it modelled a payload the server never returns. The sweep
# narrows both its live-claim read and its status read on the (prd_id,
# crit_label) PAIR the API documents as the criterion's identity, so against a
# prd_id-less fixture BOTH reads match nothing: a held lease reads as unheld and
# a `done` criterion reads as statusless. That is not a sweep bug — it is the
# fixture asserting against a payload that cannot occur.
set_criteria() {
	local city="$1" prd="$2" label="$3" claimed="${4:-}" status="${5:-outstanding}"
	if [ -n "$claimed" ]; then
		jq -n --argjson p "$prd" --arg l "$label" --arg c "$claimed" --arg s "$status" \
			'{criteria:[{prd_id:$p,crit_label:$l,status:$s,claimed_by:$c,lane:"pool"}]}' \
			>"$city/criteria.json"
	else
		jq -n --argjson p "$prd" --arg l "$label" --arg s "$status" \
			'{criteria:[{prd_id:$p,crit_label:$l,status:$s}]}' \
			>"$city/criteria.json"
	fi
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
#
# `grep -c` prints its count AND exits 1 when that count is zero, so the usual
# `|| echo 0` fallback would print "0" twice and make every zero-assertion
# unparseable. Capture and default instead.
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

# ---------------------------------------------------------------------------
# 1. POSITIVE CONTROL — load-bearing twice over. If an ignored assignment did
#    not re-route AND mail, every "is not reported" case below would pass
#    vacuously by never reporting anything at all.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
set_criteria "$c" 330 "crit:aaa"
run_sweep "$c" 3600 # routes; the worker never claims
run_sweep "$c" 0    # its window has closed
if [ "$(routed_for "$c" "crit:aaa")" = 2 ]; then
	report ok "an assignment that never became a lease is routed again"
else
	report FAIL "an assignment that never became a lease is routed again" \
		"routed $(routed_for "$c" "crit:aaa") time(s)"
fi
if [ "$(unconsumed_mails "$c")" -ge 1 ]; then
	report ok "an assignment that never became a lease is mailed"
else
	report FAIL "an assignment that never became a lease is mailed" \
		"$(cat "$c/mailed.log" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# 2. THE ALARM IS ACTIONABLE. A mail saying "an assignment was dropped" without
#    naming which criterion, or which session ate it, cannot be acted on — the
#    reader would have to re-derive both from the ledger by hand.
# ---------------------------------------------------------------------------
if grep -q 'crit:aaa' "$c/mail-body.log" 2>/dev/null &&
	grep -q 'rigA-brakeman-adhoc-stub' "$c/mail-body.log" 2>/dev/null; then
	report ok "the alarm names the criterion and the session that ignored it"
else
	report FAIL "the alarm names the criterion and the session that ignored it" \
		"$(head -c 300 "$c/mail-body.log" 2>/dev/null)"
fi

# The retry must say it IS a retry. A worker that cannot tell it is the second
# attempt has no reason to report back rather than go quiet the same way.
if grep -q 'already routed once' "$c/nudged.log" 2>/dev/null; then
	report ok "the re-routed assignment tells its worker it is a retry"
else
	report FAIL "the re-routed assignment tells its worker it is a retry"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 3. WITHIN ONE CYCLE — not before. An assignment still inside its window is a
#    worker who has not claimed YET, which is every healthy repair between the
#    nudge and the claim. Alarming there would fire on the normal case.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
set_criteria "$c" 330 "crit:aaa"
run_sweep "$c" 3600
run_sweep "$c" 3600
if [ "$(unconsumed_mails "$c")" = 0 ] && [ "$(routed_for "$c" "crit:aaa")" = 1 ]; then
	report ok "an assignment inside its window is neither re-routed nor alarmed"
else
	report FAIL "an assignment inside its window is neither re-routed nor alarmed" \
		"routed $(routed_for "$c" "crit:aaa"), mails $(unconsumed_mails "$c")"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 4. THE DISCRIMINATOR. A worker that took the claim, repaired it and released
#    reads — once the lease ends — exactly like a worker that ignored the
#    assignment: no live claim, marker expired. Only the stamp recorded WHILE
#    the lease was live separates them. Without this case, a check that mails on
#    every expired assignment passes cases 1 and 2 and alarms on every
#    successful repair in the project.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
set_criteria "$c" 330 "crit:aaa"
run_sweep "$c" 3600                            # routed
set_criteria "$c" 330 "crit:aaa" "worker/rigA"     # the worker takes the claim
run_sweep "$c" 3600                            # this cycle observes the lease
set_criteria "$c" 330 "crit:aaa"                   # repair done, lease ended
run_sweep "$c" 0                               # window long closed
if [ "$(unconsumed_mails "$c")" = 0 ]; then
	report ok "an assignment that DID become a lease is never reported as dropped"
else
	report FAIL "an assignment that DID become a lease is never reported as dropped" \
		"$(cat "$c/mailed.log" 2>/dev/null)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 5. CONSUMPTION IS ALSO PROVEN BY THE OUTCOME. A repair can be claimed and
#    finished entirely between two cycles, so no cycle ever sees its lease. The
#    criterion having moved off `outstanding` is proof the assignment was acted
#    on, and treating it as dropped would alarm precisely on the fastest repairs.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
set_criteria "$c" 330 "crit:aaa"
run_sweep "$c" 3600
set_criteria "$c" 330 "crit:aaa" "" "done" # repaired and re-judged between cycles
run_sweep "$c" 0
# BOTH HALVES, because silence is only half of "settled". Asserting the absence
# of an alarm passes just as well against a sweep that stays quiet and routes a
# SECOND assignment anyway — which is what the old code did: `done` suppressed
# the alarm while the flow fell straight through to the nudge. The rollup buckets
# a calendar day and is read for two, so that stale `fail` re-routes a completed
# repair on every cycle for up to 48 hours, each one exiting 0. Pinning the
# routed COUNT at exactly one is what makes that direction visible.
if [ "$(unconsumed_mails "$c")" = 0 ] &&
	[ "$(routed_for "$c" "crit:aaa")" = 1 ]; then
	report ok "a criterion that reached done is never reported as dropped"
else
	report FAIL "a criterion that reached done is never reported as dropped" \
		"routed=$(routed_for "$c" "crit:aaa") (want 1); $(cat "$c/mailed.log" 2>/dev/null)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 6. THE TWO ALARMS ARE DISTINCT. "Could not route" is a dispatch that never
#    reached anyone; "never consumed" is a dispatch that landed and was ignored.
#    Different faults, different fixes — find a worker, versus find out why the
#    one we have is not working. One subject for both hides the second every
#    time they fire together.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
set_criteria "$c" 330 "crit:aaa"
touch "$c/nudge-broken"
run_sweep "$c" 3600
if grep -q 'could not route' "$c/mailed.log" 2>/dev/null &&
	[ "$(unconsumed_mails "$c")" = 0 ]; then
	report ok "a dispatch that never landed is not reported as an ignored one"
else
	report FAIL "a dispatch that never landed is not reported as an ignored one" \
		"$(cat "$c/mailed.log" 2>/dev/null)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 7. A CLEAN CITY IS SILENT. Nothing was routed, so nothing can have been
#    dropped — a consumption check that alarms on an idle city has only moved
#    the noise it was written to remove.
# ---------------------------------------------------------------------------
c="$(new_city)"
set_criteria "$c" 330 "crit:aaa"
run_sweep "$c" 0
run_sweep "$c" 0
if [ "$(unconsumed_mails "$c")" = 0 ] && [ ! -s "$c/mailed.log" ]; then
	report ok "a city with no rejections raises no consumption alarm"
else
	report FAIL "a city with no rejections raises no consumption alarm" \
		"$(cat "$c/mailed.log" 2>/dev/null)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 8. EVERY DROP IS COUNTED. Two ignored assignments must both be reported: an
#    alarm that fires once and stops leaves the second criterion dropped exactly
#    as silently as no alarm at all.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
reject "$c" 331 "crit:bbb"
jq -n '{criteria:[{crit_label:"crit:aaa",status:"outstanding"},
                  {crit_label:"crit:bbb",status:"outstanding"}]}' >"$c/criteria.json"
run_sweep "$c" 3600
run_sweep "$c" 0
if grep -q 'crit:aaa' "$c/mail-body.log" 2>/dev/null &&
	grep -q 'crit:bbb' "$c/mail-body.log" 2>/dev/null &&
	grep -q '2 repair assignment(s) were never consumed' "$c/mailed.log" 2>/dev/null; then
	report ok "two ignored assignments are both counted and both named"
else
	report FAIL "two ignored assignments are both counted and both named" \
		"$(cat "$c/mailed.log" 2>/dev/null)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 9. THE ALARM MUST NOT OVERSTATE ITS OWN RETRY. A criterion joins the dropped
#    list when its window closes unconsumed — which happens BEFORE the re-route
#    is attempted, and that retry can still fail (session lookup, no live worker,
#    or the nudge itself). The worst state in this whole check is therefore
#    "never consumed, and the retry did not go out either": the criterion is
#    rejected with nobody on it and no assignment outstanding.
#
#    An alarm that flatly asserts "each has been routed again" reports precisely
#    that state as handled. That is the same false all-clear this criterion
#    exists to remove, moved one cycle later — so the claim has to be conditional
#    and has to point at the companion mail that names the unreachable ones.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
set_criteria "$c" 330 "crit:aaa"
run_sweep "$c" 3600            # cycle 1: routed, marker written, never claimed
touch "$c/nudge-broken"        # the worker goes unreachable before the retry
run_sweep "$c" 0               # cycle 2: window closed, re-route fails
if [ "$(unconsumed_mails "$c")" = 1 ] &&
	grep -q 'could not route' "$c/mailed.log" 2>/dev/null &&
	! grep -q 'Each has been routed again this cycle' "$c/mail-body.log" 2>/dev/null &&
	grep -q "EXCEPT any also named in a 'repair-sweep: could not route' mail" \
		"$c/mail-body.log" 2>/dev/null; then
	report ok "a drop whose re-route also failed is not reported as re-routed"
else
	report FAIL "a drop whose re-route also failed is not reported as re-routed" \
		"$(cat "$c/mail-body.log" 2>/dev/null)"
fi
rm -rf "$c"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
