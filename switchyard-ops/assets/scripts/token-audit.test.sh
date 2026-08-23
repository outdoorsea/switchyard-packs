#!/usr/bin/env bash
#
# Self-test for packs/switchyard-ops/assets/scripts/token-audit.sh — the city
# token-auditor lane's PRE-SPAWN demand gate.
#
# THE VERIFICATION CONTRACT
# -------------------------
#   "token-audit gates its spawn on a deterministic demand signal evaluated in
#    the order script before any session exists — new usage-ledger lines since
#    the last audit marker — and a gated skip is a logged no-op costing zero
#    tokens"
#
# WHY THE AUDITOR IS THE SHARPEST CASE OF THIS. The token auditor's whole job is
# to attribute token spend, and on a quiet city its own session is a measurable
# share of the spend it reports. Re-auditing a ledger that has not grown does not
# merely waste a session — it manufactures the very cost it exists to find. The
# order's own header already argues the point for its 168h cadence ("a daily
# audit would re-derive the same findings against a city nobody has touched");
# the cadence just cannot enforce it, because the reconciler's revive loop
# spawns lanes without consulting an interval.
#
# Every assertion is about `gc session new`, never the printed verdict. A gate
# that prints SKIP and spawns anyway is exactly the failure being refused here,
# and a stdout-only assertion cannot see it.
#
# Clauses, each pinned in both directions:
#
#   NEVER AUDITED IS DEMAND. The positive control. Without it every "did not
#   spawn" case below could be a gate that never spawns at all.
#
#   AN UNCHANGED LEDGER IS NO DEMAND. The case that saves the tokens.
#
#   NEW LINES RE-ARM. A gate that stamped once and skipped forever is cheap and
#   useless.
#
#   A MISSING LEDGER IS NO DEMAND, NOT A FAILURE — and this is the one place the
#   auditor's predicate deliberately differs from the scanners'. An absent sink
#   is a READABLE fact (nothing has been recorded), not a state we failed to
#   read, and token-report.sh already treats it as a clean exit. Spawning a
#   session to attribute an empty file is the pure re-spend this gate exists to
#   stop. Asserted explicitly so a later "fail open everywhere" tidy-up cannot
#   quietly reintroduce it.
#
#   ROTATION FAILS OPEN. events-rotate.sh truncates the sink, so a line count
#   BELOW the marker means the lines since the last audit are unknowable rather
#   than zero. A gate comparing with >= would wedge the lane shut until the
#   ledger grew past its pre-rotation length — a silent outage on a city that is
#   busier, not quieter.
#
#   A CORRUPT MARKER IS ABSENT, NOT AUTHORITATIVE. The one direction this gate
#   must never fail in.
#
# Hermetic: a throwaway city plus a stub `gc` on PATH. No real city, session or
# switchyard instance is involved. Needs jq.
#
# CI runs this a second time under dash via TOKEN_AUDIT_TEST_SH — the same knob
# as the sibling suites (BALANCE_TEST_SH, REVIEW_TEST_SH, REFACTOR_TEST_SH).
#
# Run:  bash packs/switchyard-ops/assets/scripts/token-audit.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AUDIT="$HERE/token-audit.sh"

if ! command -v jq >/dev/null 2>&1; then
	echo "SKIP — token-audit self-test needs jq (not on PATH)"
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

has() { grep -q -- "$2" <<<"$1"; }

TOKEN_AUDIT_TEST_SH="${TOKEN_AUDIT_TEST_SH:-sh}"

# ---------------------------------------------------------------------------
# Fixtures. A FRESH city per case: the gate's subject is cross-cycle state, so a
# reused fixture would let a later case pass on an earlier case's marker.
# ---------------------------------------------------------------------------

# new_city — a city defining the city-scoped token-auditor, with an empty
# usage sink present unless a case removes it.
new_city() {
	local city
	city="$(mktemp -d)"
	mkdir -p "$city/bin" "$city/state" "$city/.gc"
	: >"$city/spawned.log"

	echo '[{"qualified_name":"switchyard-ops.token-auditor","suspended":false}]' >"$city/agents.json"
	echo '{"sessions":[]}' >"$city/sessions.json"
	: >"$city/.gc/usage.jsonl"

	cat >"$city/bin/gc" <<'STUB'
#!/bin/sh
case "$1 $2" in
"agent list") cat "$GC_CITY/agents.json" ;;
"session list") cat "$GC_CITY/sessions.json" ;;
"session new")
	printf '%s\n' "$3" >>"$GC_CITY/spawned.log"
	printf 'Session gf-wisp-stub created from template "%s"\n' "$3"
	;;
"mail send") : ;;
*) : ;;
esac
exit 0
STUB
	chmod +x "$city/bin/gc"
	printf '%s' "$city"
}

# spend CITY N — append N usage facts, the growth the auditor keys on.
spend() {
	local i
	for i in $(seq 1 "$2"); do
		printf '{"tokens":%s}\n' "$i" >>"$1/.gc/usage.jsonl"
	done
}

run_audit() {
	GC_CITY="$1" \
		GC_PACK_STATE_DIR="$1/state" \
		GC_PACK_DIR="$HERE/../.." \
		PATH="$1/bin:$PATH" \
		"$TOKEN_AUDIT_TEST_SH" "$AUDIT" 2>&1
}

# `grep -c` prints a count AND exits 1 on zero matches, so an `|| echo 0`
# fallback would print "0\n0" and break every numeric comparison.
spawns() {
	local n
	n="$(grep -c . <"$1/spawned.log" 2>/dev/null)"
	printf '%s' "${n:-0}"
}

# ---------------------------------------------------------------------------
# 1. NEVER AUDITED, WITH SPEND ON RECORD, IS DEMAND — the positive control.
# ---------------------------------------------------------------------------
city="$(new_city)"
spend "$city" 5
run_audit "$city" >/dev/null
if [ "$(spawns "$city")" -eq 1 ]; then
	report ok "first pass over an unaudited ledger spawns"
else
	report FAIL "first pass over an unaudited ledger spawns" "spawned=$(spawns "$city")"
fi

# ---------------------------------------------------------------------------
# 2. THE CORE CASE: an unchanged ledger starts nothing, and says so.
# ---------------------------------------------------------------------------
: >"$city/spawned.log"
out="$(run_audit "$city")"
if [ "$(spawns "$city")" -eq 0 ]; then
	report ok "a ledger that has not grown starts no session"
else
	report FAIL "a ledger that has not grown starts no session" "spawned=$(spawns "$city")"
fi
# The line must name the lane AND the reason. A bare script-name substring is
# also produced by the shell's own "No such file or directory", which would pass
# against a script that does not exist.
if has "$out" "token-audit" && has "$out" "no new"; then
	report ok "the gated skip states the reason on stdout"
else
	report FAIL "the gated skip states the reason on stdout" "$out"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# 3. NEW LINES RE-ARM.
# ---------------------------------------------------------------------------
city="$(new_city)"
spend "$city" 3
run_audit "$city" >/dev/null
: >"$city/spawned.log"
spend "$city" 2
run_audit "$city" >/dev/null
if [ "$(spawns "$city")" -eq 1 ]; then
	report ok "new usage lines re-arm the gate"
else
	report FAIL "new usage lines re-arm the gate" "spawned=$(spawns "$city")"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# 4. A MISSING LEDGER IS NO DEMAND — nothing recorded is nothing to attribute.
# ---------------------------------------------------------------------------
city="$(new_city)"
rm -f "$city/.gc/usage.jsonl"
out="$(run_audit "$city")"
if [ "$(spawns "$city")" -eq 0 ]; then
	report ok "an absent usage sink starts no session"
else
	report FAIL "an absent usage sink starts no session" "spawned=$(spawns "$city")"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# 5. ROTATION FAILS OPEN. The sink is truncated below the marker; the lines
#    since the last audit are unknowable, not zero.
# ---------------------------------------------------------------------------
city="$(new_city)"
spend "$city" 10
run_audit "$city" >/dev/null
: >"$city/spawned.log"
: >"$city/.gc/usage.jsonl" # events-rotate.sh
spend "$city" 2
run_audit "$city" >/dev/null
if [ "$(spawns "$city")" -eq 1 ]; then
	report ok "a rotated (shorter) ledger fails OPEN and spawns"
else
	report FAIL "a rotated (shorter) ledger fails OPEN and spawns" "spawned=$(spawns "$city")"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# 6. A CORRUPT MARKER IS ABSENT, NOT AUTHORITATIVE.
# ---------------------------------------------------------------------------
city="$(new_city)"
spend "$city" 4
run_audit "$city" >/dev/null
: >"$city/spawned.log"
printf 'not a count at all\n' >"$city/state/token-audit.demand"
run_audit "$city" >/dev/null
if [ "$(spawns "$city")" -eq 1 ]; then
	report ok "a corrupt marker is treated as absent and spawns"
else
	report FAIL "a corrupt marker is treated as absent and spawns" "spawned=$(spawns "$city")"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
echo
echo "token-audit self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
