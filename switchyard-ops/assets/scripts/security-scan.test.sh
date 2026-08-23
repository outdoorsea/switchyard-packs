#!/usr/bin/env bash
#
# Self-test for packs/switchyard-ops/assets/scripts/security-scan.sh — the
# security-scout lane's PRE-SPAWN demand gate, and the provider-readiness gate
# it sits behind.
#
# THE VERIFICATION CONTRACT
# -------------------------
#   "security-scan gates its spawn on a deterministic demand signal evaluated in
#    the order script before any session exists — diff since the last scanned
#    sha — and a gated skip is a logged no-op costing zero tokens"
#
# The scout scopes its review to the diff since its last pass, so a rig whose
# HEAD has not moved offers it nothing to review. Before this gate that still
# cost a session: it started twice a day per opted-in rig, read an empty diff
# and exited IDLE. The order's own header calls that "one cheap read before the
# session exits IDLE" — cheap next to a real review, but not free, and paid on
# every quiet rig on every cycle forever.
#
# Every assertion is about `gc session new`, never the printed verdict. A gate
# that prints SKIP and spawns anyway is precisely the failure being refused, and
# it is invisible to a test that only reads stdout.
#
# TWO GATES IN A DELIBERATE ORDER, and the order is asserted rather than assumed:
#
#   PROVIDER READINESS FIRST — "can this lane run at all?" An unconfigured
#   provider mails the mayor once a week and stays quiet.
#   DEMAND SECOND — "need it run this cycle?"
#
# Reversing them would be invisible in the happy path and wrong in the field: a
# quiet cycle would return before the readiness check, so a city that had not
# configured deepseek would never receive the notice telling it so, and the lane
# would read as idle-by-choice rather than idle-because-broken. Case 6 pins the
# order by asserting the notice still goes out on a cycle that has no demand.
#
# Clauses, each pinned in both directions:
#
#   OPT-OUT IS SILENT. SECURITY_SCAN_RIGS unset spawns nothing and says nothing —
#   the pre-existing invariant, asserted so the new gate cannot disturb it.
#
#   NEVER SCANNED IS DEMAND. The positive control.
#
#   UNCHANGED IS NO DEMAND. The case that saves the tokens.
#
#   A NEW COMMIT RE-ARMS.
#
#   PER-RIG, NOT ALL-OR-NOTHING. Two opted-in rigs, one moved.
#
#   FAIL OPEN. An unreadable repo is scanned rather than skipped.
#
# Hermetic: a throwaway city, a stub `gc` on PATH, and real git repos. Needs jq
# and git. CI runs it a second time under dash via SECURITY_TEST_SH.
#
# Run:  bash packs/switchyard-ops/assets/scripts/security-scan.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCAN="$HERE/security-scan.sh"

for need in jq git; do
	if ! command -v "$need" >/dev/null 2>&1; then
		echo "SKIP — security-scan self-test needs $need (not on PATH)"
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

has() { grep -q -- "$2" <<<"$1"; }

SECURITY_TEST_SH="${SECURITY_TEST_SH:-sh}"

new_repo() {
	mkdir -p "$1"
	git -C "$1" init -q 2>/dev/null
	git -C "$1" config user.email t@t.test
	git -C "$1" config user.name t
	echo seed >"$1/f"
	git -C "$1" add f
	git -C "$1" commit -qm seed
}

commit_to() {
	echo "$RANDOM$RANDOM" >>"$1/f"
	git -C "$1" add f
	git -C "$1" commit -qm move
}

# new_city [RIG...] — a city that has opted the named rigs into the lane.
#
# SECURITY_SCOUT_PROVIDER=claude on purpose: the default provider short-circuits
# the readiness gate, which isolates the demand gate as this suite's subject.
# Case 6 overrides it to exercise the readiness path deliberately.
new_city() {
	local city rig list=""
	city="$(mktemp -d)"
	mkdir -p "$city/bin" "$city/state"
	: >"$city/spawned.log"
	: >"$city/mailed.log"

	local agents='[]' rigs='[]'
	for rig in "$@"; do
		new_repo "$city/$rig"
		list="$list $rig"
		agents="$(jq -c --arg r "$rig" \
			'. + [{"qualified_name":($r + "/switchyard-ops.security-scout"),"suspended":false}]' <<<"$agents")"
		rigs="$(jq -c --arg r "$rig" --arg p "$city/$rig" \
			'. + [{"name":$r,"path":$p}]' <<<"$rigs")"
	done
	printf '%s' "$agents" >"$city/agents.json"
	printf '%s' "$rigs" >"$city/rigs.json"
	echo '{"sessions":[]}' >"$city/sessions.json"

	{
		printf 'SECURITY_SCAN_RIGS="%s"\n' "${list# }"
		printf 'SECURITY_SCOUT_PROVIDER="claude"\n'
	} >"$city/state/roster.conf"

	cat >"$city/bin/gc" <<'STUB'
#!/bin/sh
case "$1 $2" in
"agent list") cat "$GC_CITY/agents.json" ;;
"rig list") cat "$GC_CITY/rigs.json" ;;
"session list") cat "$GC_CITY/sessions.json" ;;
"config show") cat "$GC_CITY/config.txt" 2>/dev/null ;;
"session new")
	printf '%s\n' "$3" >>"$GC_CITY/spawned.log"
	printf 'Session gf-wisp-stub created from template "%s"\n' "$3"
	;;
"mail send")
	shift 2
	while [ $# -gt 0 ]; do
		case "$1" in
		-s) printf 'SUBJ %s\n' "$2" >>"$GC_CITY/mailed.log"; shift 2 ;;
		*) shift ;;
		esac
	done
	;;
*) : ;;
esac
exit 0
STUB
	chmod +x "$city/bin/gc"
	printf '%s' "$city"
}

run_scan() {
	GC_CITY="$1" \
		GC_PACK_STATE_DIR="$1/state" \
		GC_PACK_DIR="$HERE/../.." \
		PATH="$1/bin:$PATH" \
		"$SECURITY_TEST_SH" "$SCAN" 2>&1
}

# `grep -c` prints a count AND exits 1 on zero matches, so an `|| echo 0`
# fallback would print "0\n0" and break every numeric comparison.
spawns() {
	local n
	n="$(grep -c . <"$1/spawned.log" 2>/dev/null)"
	printf '%s' "${n:-0}"
}
mails() {
	local n
	n="$(grep -c . <"$1/mailed.log" 2>/dev/null)"
	printf '%s' "${n:-0}"
}
spawn_log() { cat "$1/spawned.log" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 1. OPT-OUT IS SILENT — the pre-existing invariant. Listed first so a later
#    regression in the new gate cannot be mistaken for this one.
# ---------------------------------------------------------------------------
city="$(new_city rigA)"
: >"$city/state/roster.conf" # no SECURITY_SCAN_RIGS at all
run_scan "$city" >/dev/null
if [ "$(spawns "$city")" -eq 0 ] && [ "$(mails "$city")" -eq 0 ]; then
	report ok "an un-opted city spawns nothing and mails nothing"
else
	report FAIL "an un-opted city spawns nothing and mails nothing" \
		"spawned=$(spawns "$city") mailed=$(mails "$city")"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# 2. NEVER SCANNED IS DEMAND — the positive control.
# ---------------------------------------------------------------------------
city="$(new_city rigA)"
run_scan "$city" >/dev/null
if [ "$(spawns "$city")" -eq 1 ]; then
	report ok "first pass against an unscanned rig spawns"
else
	report FAIL "first pass against an unscanned rig spawns" "spawned=$(spawns "$city")"
fi

# ---------------------------------------------------------------------------
# 3. THE CORE CASE: unchanged HEAD is no demand, and the skip is logged.
# ---------------------------------------------------------------------------
: >"$city/spawned.log"
out="$(run_scan "$city")"
if [ "$(spawns "$city")" -eq 0 ]; then
	report ok "second pass at the same HEAD starts no session"
else
	report FAIL "second pass at the same HEAD starts no session" "spawned=$(spawn_log "$city")"
fi
# Names the rig and the reason. A bare script-name substring is also produced by
# the shell's own "No such file or directory".
if has "$out" "rigA" && has "$out" "unchanged"; then
	report ok "the gated skip names the rig and the reason on stdout"
else
	report FAIL "the gated skip names the rig and the reason on stdout" "$out"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# 4. A NEW COMMIT RE-ARMS.
# ---------------------------------------------------------------------------
city="$(new_city rigA)"
run_scan "$city" >/dev/null
: >"$city/spawned.log"
commit_to "$city/rigA"
run_scan "$city" >/dev/null
if [ "$(spawns "$city")" -eq 1 ]; then
	report ok "a new commit re-arms the gate"
else
	report FAIL "a new commit re-arms the gate" "spawned=$(spawns "$city")"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# 5. PER-RIG, NOT ALL-OR-NOTHING.
# ---------------------------------------------------------------------------
city="$(new_city rigA rigB)"
run_scan "$city" >/dev/null
: >"$city/spawned.log"
commit_to "$city/rigB"
run_scan "$city" >/dev/null
log="$(spawn_log "$city")"
if [ "$(spawns "$city")" -eq 1 ] && has "$log" "rigB"; then
	report ok "only the rig whose HEAD moved is spawned for"
else
	report FAIL "only the rig whose HEAD moved is spawned for" "spawned=[$log]"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# 6. THE GATE ORDER. Provider readiness runs BEFORE demand, so a city that has
#    not configured its provider still gets told — even on a cycle where the
#    demand gate would have skipped anyway. Reversing the two would silence that
#    notice forever on a quiet rig, and the lane would read as idle-by-choice
#    rather than idle-because-broken.
#
#    The rig is scanned once to stamp its marker, so the second cycle genuinely
#    has no demand; the provider is then switched to an unconfigured one.
# ---------------------------------------------------------------------------
city="$(new_city rigA)"
run_scan "$city" >/dev/null # stamp the marker at the current HEAD
: >"$city/spawned.log"
: >"$city/mailed.log"
{
	printf 'SECURITY_SCAN_RIGS="rigA"\n'
	printf 'SECURITY_SCOUT_PROVIDER="deepseek"\n'
} >"$city/state/roster.conf"
: >"$city/config.txt" # no [providers.deepseek] => unconfigured
run_scan "$city" >/dev/null
if [ "$(spawns "$city")" -eq 0 ] && [ "$(mails "$city")" -eq 1 ]; then
	report ok "readiness is checked before demand: an unconfigured provider still notifies"
else
	report FAIL "readiness is checked before demand: an unconfigured provider still notifies" \
		"spawned=$(spawns "$city") mailed=$(mails "$city")"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# 7. FAIL OPEN.
# ---------------------------------------------------------------------------
city="$(new_city rigA)"
rm -rf "$city/rigA/.git"
run_scan "$city" >/dev/null
if [ "$(spawns "$city")" -eq 1 ]; then
	report ok "an unreadable repo fails OPEN and still spawns"
else
	report FAIL "an unreadable repo fails OPEN and still spawns" "spawned=$(spawns "$city")"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
echo
echo "security-scan self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
