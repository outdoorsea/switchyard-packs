#!/usr/bin/env bash
#
# Self-test for packs/switchyard-ops/assets/scripts/refactor-scan.sh — the
# refactor-scout lane's PRE-SPAWN demand gate.
#
# THE VERIFICATION CONTRACT
# -------------------------
#   "refactor-scan gates its spawn on a deterministic demand signal evaluated
#    in the order script before any session exists — diff since the last
#    scanned sha — and a gated skip is a logged no-op costing zero tokens"
#
# WHY "BEFORE ANY SESSION EXISTS" IS THE WHOLE POINT, and not a restatement of
# the gate that already shipped. refactor-scan-gate.sh gates the same predicate
# AFTER the spawn, as the scout's own first action. That placement was
# deliberate — it covers the reconciler's revive loop, which never reads this
# order — but it means a scheduled pass with no demand still pays for a session
# to start up, read the gate and exit. The measured cost of the ungated lane was
# 45.4M tokens/24h (switchyard issue 163). A gate that runs before `gc session
# new` costs nothing at all.
#
# So every assertion below is about `gc session new` — not about the gate's
# printed verdict. A gate that prints SKIP and spawns anyway is the exact
# failure this criterion exists to refuse, and it is invisible to a test that
# only reads stdout. The stub records every spawn; the no-demand cases assert
# that log is EMPTY.
#
# Four clauses, each pinned in both directions:
#
#   NEVER SCANNED IS DEMAND. A first pass against a rig with no marker must
#   spawn. A gate that treated "no marker" as "no change" would retire the lane
#   on day one and never report that it had — the failure mode refactor-scan-
#   gate.sh's own header calls out as invisible.
#
#   UNCHANGED IS NO DEMAND. The second pass at the same HEAD must not spawn.
#   This is the case that actually saves the tokens.
#
#   A NEW COMMIT RE-ARMS. Demand returns when HEAD moves. A gate that stamped
#   once and skipped forever would be cheaper and useless.
#
#   PER-RIG, NOT ALL-OR-NOTHING. Two rigs, one moved: the lane must spawn for
#   the moved rig only. A gate collapsing the rig set to a single boolean either
#   re-spends on every quiet rig or starves a busy one, and both look correct
#   against a one-rig fixture.
#
#   FAIL OPEN. An unreadable repo answers DEMAND. A broken gate that failed
#   closed would silently retire the lane, and a lane that never runs can never
#   report that it isn't running.
#
# It runs hermetically: a throwaway city plus a stub `gc` on PATH, and real git
# repos (the predicate reads a real HEAD, so a faked one would test the fixture).
# No real city, session or switchyard instance is involved. Needs jq and git.
#
# The order is POSIX sh and ships to cities that are not Ubuntu, so CI runs this
# suite a second time under dash via REFACTOR_TEST_SH — the same knob as the
# sibling suites (BALANCE_TEST_SH, REVIEW_TEST_SH, CONDUCTOR_TEST_SH).
#
# Run:  bash packs/switchyard-ops/assets/scripts/refactor-scan.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCAN="$HERE/refactor-scan.sh"

for need in jq git; do
	if ! command -v "$need" >/dev/null 2>&1; then
		echo "SKIP — refactor-scan self-test needs $need (not on PATH)"
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

# Substring assertions with NO pipeline — `printf | grep -q` under pipefail
# SIGPIPEs its producer on the success path; herestrings cannot.
has() { grep -q -- "$2" <<<"$1"; }

REFACTOR_TEST_SH="${REFACTOR_TEST_SH:-sh}"

# ---------------------------------------------------------------------------
# Fixtures. Every case builds a FRESH city: the gate's whole subject is
# cross-cycle state, so a fixture reused across cases would let a later case
# pass on an earlier case's marker rather than its own.
# ---------------------------------------------------------------------------

# new_repo DIR — a real git repo with one commit. The gate reads HEAD for real.
new_repo() {
	mkdir -p "$1"
	git -C "$1" init -q 2>/dev/null
	git -C "$1" config user.email t@t.test
	git -C "$1" config user.name t
	echo seed >"$1/f"
	git -C "$1" add f
	git -C "$1" commit -qm seed
}

# commit_to DIR — move HEAD, which is the demand signal itself.
commit_to() {
	echo "$RANDOM$RANDOM" >>"$1/f"
	git -C "$1" add f
	git -C "$1" commit -qm move
}

# new_city [RIG...] — a city defining a refactor-scout for each named rig.
new_city() {
	local city rig
	city="$(mktemp -d)"
	mkdir -p "$city/bin" "$city/state"
	: >"$city/spawned.log"

	# The agent roster lane_rigs reads, and the rig list sy_rig_root reads. Both
	# are derived from the SAME rig set, exactly as a real city's are.
	local agents='[]' rigs='[]'
	for rig in "$@"; do
		new_repo "$city/$rig"
		agents="$(jq -c --arg r "$rig" \
			'. + [{"qualified_name":($r + "/switchyard-ops.refactor-scout"),"suspended":false}]' <<<"$agents")"
		rigs="$(jq -c --arg r "$rig" --arg p "$city/$rig" \
			'. + [{"name":$r,"path":$p}]' <<<"$rigs")"
	done
	printf '%s' "$agents" >"$city/agents.json"
	printf '%s' "$rigs" >"$city/rigs.json"
	echo '{"sessions":[]}' >"$city/sessions.json"

	# --- stub gc ------------------------------------------------------------
	# `session new` is the ONLY thing that costs tokens, so it is the only thing
	# these assertions read. It is recorded rather than counted so a failure can
	# name which rig was spawned for.
	cat >"$city/bin/gc" <<'STUB'
#!/bin/sh
case "$1 $2" in
"agent list") cat "$GC_CITY/agents.json" ;;
"rig list") cat "$GC_CITY/rigs.json" ;;
"session list") cat "$GC_CITY/sessions.json" ;;
"session new")
	printf '%s\n' "$3" >>"$GC_CITY/spawned.log"
	printf 'Session gf-wisp-stub created from template "%s"\n' "$3"
	;;
"mail send") : ;;
"config show") : ;;
*) : ;;
esac
exit 0
STUB
	chmod +x "$city/bin/gc"
	printf '%s' "$city"
}

# run_scan CITY — one order cycle, via the named shell.
run_scan() {
	GC_CITY="$1" \
		GC_PACK_STATE_DIR="$1/state" \
		GC_PACK_DIR="$HERE/../.." \
		PATH="$1/bin:$PATH" \
		"$REFACTOR_TEST_SH" "$SCAN" 2>&1
}

# spawns CITY — how many sessions the last run started. `grep -c` prints a
# count and exits 1 on zero matches, so an `|| echo 0` fallback would print the
# count AND the fallback ("0\n0") and every numeric comparison would error out.
spawns() {
	local n
	n="$(grep -c . <"$1/spawned.log" 2>/dev/null)"
	printf '%s' "${n:-0}"
}

# spawn_log CITY — which templates, for failure detail.
spawn_log() { cat "$1/spawned.log" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 1. NEVER SCANNED IS DEMAND — the positive control. Without it every "did not
#    spawn" assertion below could be a gate that never spawns at all.
# ---------------------------------------------------------------------------
city="$(new_city rigA)"
run_scan "$city" >/dev/null
if [ "$(spawns "$city")" -eq 1 ]; then
	report ok "first pass against an unscanned rig spawns"
else
	report FAIL "first pass against an unscanned rig spawns" "spawned=$(spawns "$city")"
fi

# ---------------------------------------------------------------------------
# 2. THE CORE CASE: unchanged HEAD is no demand, and the skip is a LOGGED no-op.
#    Asserted on the spawn log, not the verdict text — a gate that says SKIP and
#    spawns anyway passes a stdout-only assertion.
# ---------------------------------------------------------------------------
: >"$city/spawned.log"
out="$(run_scan "$city")"
if [ "$(spawns "$city")" -eq 0 ]; then
	report ok "second pass at the same HEAD starts no session"
else
	report FAIL "second pass at the same HEAD starts no session" "spawned=$(spawn_log "$city")"
fi
# NAMES THE RIG AND THE REASON. A bare "refactor-scan" substring is matched by
# the shell's own "No such file or directory" when the script is absent, so that
# assertion passed against a script that did not exist. The skip line has to say
# WHICH rig was skipped and that it was unchanged — neither of which any error
# message produces.
if has "$out" "rigA" && has "$out" "unchanged"; then
	report ok "the gated skip names the rig and the reason on stdout"
else
	report FAIL "the gated skip names the rig and the reason on stdout" "$out"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# 3. A NEW COMMIT RE-ARMS. Same city, HEAD moved.
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
# 4. PER-RIG, NOT ALL-OR-NOTHING. Two rigs, one moves.
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
# 5. FAIL OPEN. The rig's repo is not a git repo at all, so HEAD is unreadable.
#    A gate that failed closed here would retire the lane silently.
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
# 6. A CORRUPT MARKER IS ABSENT, NOT AUTHORITATIVE. The one direction the gate
#    must never fail in: a marker we cannot trust must not be read as "already
#    scanned at this sha".
# ---------------------------------------------------------------------------
city="$(new_city rigA)"
run_scan "$city" >/dev/null
: >"$city/spawned.log"
printf 'garbage not a sha\n' >"$city/state/refactor-scan.rigA.demand"
run_scan "$city" >/dev/null
if [ "$(spawns "$city")" -eq 1 ]; then
	report ok "a corrupt marker is treated as absent and spawns"
else
	report FAIL "a corrupt marker is treated as absent and spawns" "spawned=$(spawns "$city")"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
echo
echo "refactor-scan self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
