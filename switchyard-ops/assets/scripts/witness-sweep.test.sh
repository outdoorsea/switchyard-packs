#!/usr/bin/env bash
#
# Self-test for packs/switchyard-ops/assets/scripts/witness-sweep.sh
# (switchyard PRD #357 P1).
#
# THE VERIFICATION CONTRACT
# -------------------------
#   "The witness sweeps each configured rig's stuck-work surface on a cadence
#    and dual-writes lane mail plus the server decision, once per episode; it
#    reports only states the reclaim sweep cannot fix; it nudges a wedged
#    session once and escalates instead of nudging again; and it files a
#    stalled dispatch loop only on the full three-leg signature."
#
# Separable claims, each with the case that kills its cheap wrong version:
#
#   ONCE PER EPISODE, KEYED ON THE SERVER'S (type, id). The same surface read
#   twice mails once; a NEW id (the server's own episode hash moving) mails
#   again. Without the second half, a sweep that never mailed anything would
#   pass the first. The mark-after-delivery ordering is asserted too: a failed
#   send leaves the episode unmarked so the next cycle retries — marking first
#   is publish-gate's named anti-pattern and drops the one alert this order
#   exists to deliver.
#
#   RECLAIM-FIXED FILES NOTHING. The surface is the predicate: a lapsed lease
#   already returned to the pool is absent from the server's projection, so an
#   empty surface must produce zero mail even while the rig has claimable
#   beads sitting in its pool. A sweep that re-derived stall predicates from
#   the pool read would fail exactly here.
#
#   NUDGE ONCE, THEN ESCALATE. Both rungs are asserted in sequence on one
#   session, plus both boundaries: a busy pane and a fresh last_active are
#   each NOT the wedge (a sweep keyed on either half alone would nudge working
#   sessions), and a session that RECOVERS and wedges again is a NEW episode
#   that starts back at the nudge rung — without that, the ladder is a
#   one-shot forever and a recurring wedge goes unreported.
#
#   THE DISPATCH STALL NEEDS ALL THREE LEGS. The full signature files once;
#   each leg is then removed on its own — empty pool, a live worker, no recent
#   failure ("between cycles") — and each removal must file NOTHING. A
#   circuit-breaker `skipped` line satisfies the outcome leg like a `failed:`
#   line does. The episode marker clears on a confidently-healthy read so a
#   later stall re-fires.
#
#   THE SCRIPT SHIPS EXECUTABLE. One case invokes the order script AS A FILE
#   (not `sh script`), exactly as gc's order exec does — a lost exec bit fails
#   that invocation with 126, which no `bash script.sh` case would ever see.
#   This bit the pack twice; the case is the regression pin.
#
# It runs hermetically: a throwaway city plus stub `gc`, `tmux` and `curl` on
# PATH answering from per-case fixtures. No real city, session, mayor or
# switchyard instance is involved. Needs jq (skips without it).
#
# Run:  bash packs/switchyard-ops/assets/scripts/witness-sweep.test.sh
#       WITNESS_TEST_SH=dash bash .../witness-sweep.test.sh   # POSIX check

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SWEEP="$HERE/witness-sweep.sh"

if ! command -v jq >/dev/null 2>&1; then
	echo "SKIP — witness-sweep self-test needs jq (not on PATH)"
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

# Substring assertions with NO pipeline — `printf | grep -q` under pipefail
# SIGPIPEs its producer on the success path (see integration-lane.test.sh for
# the measured flake); herestrings cannot.
has() { grep -q -- "$2" <<<"$1"; }

# iso_ago SECS — an RFC3339 UTC stamp SECS in the past, for session
# last_active fixtures. BSD `date -r` first (macOS), GNU `date -d @` fallback.
iso_ago() {
	local e=$(($(date +%s) - $1))
	date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ
}

# log_ts_ago SECS — a supervisor-log-format LOCAL stamp SECS in the past
# ("YYYY/MM/DD HH:MM:SS"), matching what gc's supervisor writes.
log_ts_ago() {
	local e=$(($(date +%s) - $1))
	date -r "$e" +'%Y/%m/%d %H:%M:%S' 2>/dev/null || date -d "@$e" +'%Y/%m/%d %H:%M:%S'
}

# ---------------------------------------------------------------------------
# Fixtures. Every case builds a FRESH city: the sweep's whole subject is
# cross-cycle state, so a fixture reused across cases would let a later case
# pass on an earlier case's ledger rather than its own.
# ---------------------------------------------------------------------------

RIG=rigA

new_city() {
	local city
	city="$(mktemp -d)"
	mkdir -p "$city/bin" "$city/state"

	echo '[{"slug":"rigA","tenant_slug":"stub"}]' >"$city/projects.json"
	echo '{"decisions":[],"count":0}' >"$city/decisions.json"
	echo '{"beads":[],"total":0}' >"$city/pool.json"
	echo '{"sessions":[]}' >"$city/sessions.json"
	: >"$city/supervisor.log"

	# The opt-in as a city would actually spell it. The opt-out case overwrites
	# this with an empty file.
	printf 'WITNESS_RIGS="%s"\n' "$RIG" >"$city/state/roster.conf"

	# --- stub gc: session list/nudge from fixtures, mail to a log -----------
	# mail-broken exits BEFORE logging, so a failed send leaves no trace — the
	# fixture for the mark-after-delivery assertion.
	cat >"$city/bin/gc" <<'STUB'
#!/bin/sh
case "$1 $2" in
"session list") cat "$GC_CITY/sessions.json" ;;
"session nudge")
	[ -f "$GC_CITY/nudge-broken" ] && exit 1
	# Record the WHOLE invocation, not just the ref. The counters below match
	# on '^NUDGE ' and read the ref as field 2, so both still work; what this
	# adds is the delivery mode, which the rung's correctness depends on and
	# which a name-only mock silently accepts either way.
	printf 'NUDGE %s ARGV %s\n' "$3" "$*" >>"$GC_CITY/nudged.log"
	;;
"mail send")
	[ -f "$GC_CITY/mail-broken" ] && exit 1
	subj=""; body=""
	shift 2
	while [ $# -gt 0 ]; do
		case "$1" in
		-s) subj="$2"; shift 2 ;;
		-m) body="$2"; shift 2 ;;
		*) shift ;;
		esac
	done
	printf 'SUBJ %s\n' "$subj" >>"$GC_CITY/mailed.log"
	printf 'BODY %s\n' "$body" >>"$GC_CITY/mailed.log"
	;;
*) : ;;
esac
exit 0
STUB

	# --- stub tmux: capture-pane answers from pane.<target> ------------------
	cat >"$city/bin/tmux" <<'STUB'
#!/bin/sh
target=""
prev=""
for a in "$@"; do
	[ "$prev" = "-t" ] && target="$a"
	prev="$a"
done
[ -n "$target" ] || exit 1
cat "$GC_CITY/pane.$target" 2>/dev/null || exit 1
STUB

	# --- stub curl: the three reads, keyed on URL ----------------------------
	# Drains stdin FIRST: sy_api_get pipes the Authorization header into
	# `curl --config -`, and a stub that never reads it SIGPIPEs the producer.
	cat >"$city/bin/curl" <<'STUB'
#!/bin/sh
cat >/dev/null
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
*/api/v1/projects) cat "$GC_CITY/projects.json" ;;
*/pending-decisions) cat "$GC_CITY/decisions.json" ;;
*"/pool?limit=1") cat "$GC_CITY/pool.json" ;;
*) exit 22 ;;
esac
exit 0
STUB

	chmod +x "$city/bin/gc" "$city/bin/tmux" "$city/bin/curl"
	printf '%s' "$city"
}

# decision CITY TYPE ID TITLE — put one witness entry on the server surface.
decision() {
	local t
	t="$(mktemp)"
	jq --arg ty "$2" --argjson id "$3" --arg ti "$4" \
		'.decisions += [{"type":$ty,"id":$id,"title":$ti}] | .count = (.decisions|length)' \
		"$1/decisions.json" >"$t" && mv "$t" "$1/decisions.json" || rm -f "$t"
}

# wedged_session CITY REF PANE AGO — one ACTIVE session for the rig whose
# last_active is AGO seconds old, panes keyed by PANE.
wedged_session() {
	local t
	t="$(mktemp)"
	jq --arg r "$2" --arg p "$3" --arg la "$(iso_ago "$4")" --arg rig "$RIG" \
		'.sessions += [{"rig":$rig,"state":"active","closed":false,
			"alias":$r,"name":$r,"agent_name":$r,"session_name":$p,
			"template":($rig+"/switchyard-ops.brakeman"),"last_active":$la}]' \
		"$1/sessions.json" >"$t" && mv "$t" "$1/sessions.json" || rm -f "$t"
}

# queued_pane CITY PANE TEXT — a pane whose input line holds unsubmitted text.
queued_pane() {
	printf 'some earlier output\n\n%s %s\n' '❯' "$3" >"$1/pane.$2"
}

# busy_pane CITY PANE — a pane mid-turn (the busy footer marker present).
busy_pane() {
	printf 'thinking...\n%s %s\nesc to interrupt\n' '❯' '' >"$1/pane.$2"
}

# dispatch_failure CITY AGO [VERB REASON] — one supervisor-log outcome line.
dispatch_failure() {
	printf '%s gc: order exec pool-spawn %s\n' \
		"$(log_ts_ago "$2")" "${3:-failed: context deadline exceeded}" >>"$1/supervisor.log"
}

# The shell the sweep runs under: `sh` is dash on Debian/Ubuntu (where CI runs)
# and bash-in-posix-mode on macOS; WITNESS_TEST_SH lets CI name dash explicitly,
# the same knob the sibling suites take.
WITNESS_TEST_SH="${WITNESS_TEST_SH:-sh}"

# run_sweep CITY — one sweep cycle against CITY, via the named shell.
run_sweep() {
	GC_CITY="$1" \
		GC_PACK_STATE_DIR="$1/state" \
		GC_TMUX_SOCKET="stubsock" \
		SWITCHYARD_API_TOKEN="sy_stub_token" \
		WITNESS_SUPERVISOR_LOG="$1/supervisor.log" \
		PATH="$1/bin:$PATH" \
		"$WITNESS_TEST_SH" "$SWEEP" >/dev/null 2>&1
}

# run_sweep_as_file CITY — the SAME cycle, but invoking the script the way
# gc's order exec does: as a file, through its shebang. This is the exec-bit
# assertion — a 644 script fails HERE with 126 and nowhere else in this suite.
run_sweep_as_file() {
	GC_CITY="$1" \
		GC_PACK_STATE_DIR="$1/state" \
		GC_TMUX_SOCKET="stubsock" \
		SWITCHYARD_API_TOKEN="sy_stub_token" \
		WITNESS_SUPERVISOR_LOG="$1/supervisor.log" \
		PATH="$1/bin:$PATH" \
		"$SWEEP" >/dev/null 2>&1
}

mails() { grep -c '^SUBJ ' "$1/mailed.log" 2>/dev/null || echo 0; }
nudges() { grep -c '^NUDGE ' "$1/nudged.log" 2>/dev/null || echo 0; }
mail_log() { cat "$1/mailed.log" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Case: opt-in — no WITNESS_RIGS means the order does nothing, and the script
# runs AS A FILE (the exec-bit invocation).
# ---------------------------------------------------------------------------
city="$(new_city)"
: >"$city/state/roster.conf"
if run_sweep_as_file "$city"; then
	report ok "exec-bit: the order script runs as a file (as gc order exec invokes it)"
else
	rc=$?
	report FAIL "exec-bit: the order script runs as a file (as gc order exec invokes it)" "rc=$rc (126 = exec bit lost)"
fi
if [ "$(mails "$city")" = 0 ] && [ "$(nudges "$city")" = 0 ]; then
	report ok "opt-in: an unset WITNESS_RIGS mails and nudges nothing"
else
	report FAIL "opt-in: an unset WITNESS_RIGS mails and nudges nothing" "$(mail_log "$city")"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# Case: the dual-write's mail half is once per (type, id) episode.
# ---------------------------------------------------------------------------
city="$(new_city)"
decision "$city" stuck_work 123 "Stuck work: sw-abc (no-heartbeat) held by w1 — clears via claim_action release"
decision "$city" ready_to_merge 9 "Ready to merge: 2 green approved PRs"
decision "$city" prd_approval 77 "PRD 5 awaits approval"
run_sweep "$city"
out="$(mail_log "$city")"
if [ "$(mails "$city")" = 1 ] && has "$out" "stuck_work/123" && has "$out" "ready_to_merge/9"; then
	report ok "dual-write: new stuck_work + ready_to_merge episodes are mailed, batched per rig"
else
	report FAIL "dual-write: new stuck_work + ready_to_merge episodes are mailed, batched per rig" "$out"
fi
if ! has "$out" "prd_approval"; then
	report ok "dual-write: non-witness decision types are not the pack's to mail"
else
	report FAIL "dual-write: non-witness decision types are not the pack's to mail" "$out"
fi
run_sweep "$city"
if [ "$(mails "$city")" = 1 ]; then
	report ok "dual-write: the same episode (same type/id) is never mailed twice"
else
	report FAIL "dual-write: the same episode (same type/id) is never mailed twice" "$(mails "$city") mails"
fi
# The server minting a NEW id for the same bead (fresh lease that lapsed again)
# is a NEW episode and re-fires.
decision "$city" stuck_work 456 "Stuck work: sw-abc (no-heartbeat) held by w1 — clears via claim_action release"
run_sweep "$city"
if [ "$(mails "$city")" = 2 ] && has "$(mail_log "$city")" "stuck_work/456"; then
	report ok "dual-write: a new episode id re-fires the mail"
else
	report FAIL "dual-write: a new episode id re-fires the mail" "$(mail_log "$city")"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# Case: mark-after-delivery — a failed send retries next cycle, once mail is
# back it goes out exactly once.
# ---------------------------------------------------------------------------
city="$(new_city)"
decision "$city" stuck_work 123 "Stuck work: sw-abc"
: >"$city/mail-broken"
run_sweep "$city"
rm -f "$city/mail-broken"
run_sweep "$city"
if [ "$(mails "$city")" = 1 ] && has "$(mail_log "$city")" "stuck_work/123"; then
	report ok "dual-write: a failed send marks nothing, so the next cycle delivers it"
else
	report FAIL "dual-write: a failed send marks nothing, so the next cycle delivers it" "$(mails "$city") mails"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# Case: reclaim-fixed files nothing. The pool holds beads (so a sweep that
# re-derived stalls from the pool would fire), but the server surface — which
# already excludes a lapsed lease the reclaim sweep returned to the pool — is
# empty, so the witness mails nothing.
# ---------------------------------------------------------------------------
city="$(new_city)"
echo '{"beads":[{"id":"sw-x"}],"total":3}' >"$city/pool.json"
run_sweep "$city"
if [ "$(mails "$city")" = 0 ]; then
	report ok "reclaim filter: an empty server surface files nothing, whatever the pool holds"
else
	report FAIL "reclaim filter: an empty server surface files nothing, whatever the pool holds" "$(mail_log "$city")"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# Case: the wedge ladder — nudge once, escalate on the next cycle, silence
# after; recovery resets the episode.
# ---------------------------------------------------------------------------
city="$(new_city)"
REF="$RIG/switchyard-ops.ps-wedge-1"
wedged_session "$city" "$REF" s-wedge 3600
queued_pane "$city" s-wedge "why didn't the"
run_sweep "$city"
if [ "$(nudges "$city")" = 1 ] && [ "$(mails "$city")" = 0 ]; then
	report ok "wedge: first sighting is ONE nudge and no mail"
else
	report FAIL "wedge: first sighting is ONE nudge and no mail" "nudges=$(nudges "$city") mails=$(mails "$city")"
fi
# The rung's whole value is SUBMITTING the queued text. gc session nudge
# defaults to --delivery wait-idle, which appends and waits for an idle
# boundary a wedged pane never reaches — delivering nothing and dirtying the
# line for the next nudge. Dropping this flag turns rung 1 back into a no-op
# that still counts as "nudged", so the count assertion above cannot catch it.
if grep -q '^NUDGE .* ARGV .*--delivery immediate' "$city/nudged.log" 2>/dev/null; then
	report ok "wedge: the nudge is sent --delivery immediate so it SUBMITS the queued text"
else
	report FAIL "wedge: the nudge is sent --delivery immediate so it SUBMITS the queued text" "$(cat "$city/nudged.log" 2>/dev/null)"
fi
run_sweep "$city"
out="$(mail_log "$city")"
if [ "$(nudges "$city")" = 1 ] && [ "$(mails "$city")" = 1 ] && has "$out" "$REF"; then
	report ok "wedge: still wedged next cycle escalates by mail instead of nudging again"
else
	report FAIL "wedge: still wedged next cycle escalates by mail instead of nudging again" "nudges=$(nudges "$city") mails=$(mails "$city")"
fi
run_sweep "$city"
if [ "$(mails "$city")" = 1 ]; then
	report ok "wedge: an escalated episode is silent until it clears"
else
	report FAIL "wedge: an escalated episode is silent until it clears" "$(mails "$city") mails"
fi
# Recovery (busy pane = confirmed working) clears the episode; a LATER wedge is
# a new episode starting back at the nudge rung.
busy_pane "$city" s-wedge
run_sweep "$city"
queued_pane "$city" s-wedge "stuck again"
run_sweep "$city"
if [ "$(nudges "$city")" = 2 ] && [ "$(mails "$city")" = 1 ]; then
	report ok "wedge: recovery ends the episode; a later wedge starts a NEW one at the nudge rung"
else
	report FAIL "wedge: recovery ends the episode; a later wedge starts a NEW one at the nudge rung" "nudges=$(nudges "$city") mails=$(mails "$city")"
fi
rm -rf "$city"

# The two halves of the signature, each insufficient alone: a busy pane is not
# wedged however stale the roster row, and a fresh session is not wedged
# however queued its pane.
city="$(new_city)"
wedged_session "$city" "$RIG/switchyard-ops.ps-busy" s-busy 3600
busy_pane "$city" s-busy
run_sweep "$city"
if [ "$(nudges "$city")" = 0 ]; then
	report ok "wedge: a busy pane (mid-turn) is never nudged, however stale last_active reads"
else
	report FAIL "wedge: a busy pane (mid-turn) is never nudged, however stale last_active reads"
fi
rm -rf "$city"

city="$(new_city)"
wedged_session "$city" "$RIG/switchyard-ops.ps-fresh" s-fresh 10
queued_pane "$city" s-fresh "half a thought"
run_sweep "$city"
if [ "$(nudges "$city")" = 0 ]; then
	report ok "wedge: a recently-active session is never nudged, whatever its pane holds"
else
	report FAIL "wedge: a recently-active session is never nudged, whatever its pane holds"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# Case: the dispatch stall needs ALL THREE legs — and files once per episode.
# ---------------------------------------------------------------------------
city="$(new_city)"
echo '{"beads":[],"total":5}' >"$city/pool.json"
dispatch_failure "$city" 60
run_sweep "$city"
out="$(mail_log "$city")"
if [ "$(mails "$city")" = 1 ] && has "$out" "gc order run pool-spawn"; then
	report ok "dispatch: pool + no workers + failed last cycle files ONE decision naming the unstick"
else
	report FAIL "dispatch: pool + no workers + failed last cycle files ONE decision naming the unstick" "$out"
fi
run_sweep "$city"
if [ "$(mails "$city")" = 1 ]; then
	report ok "dispatch: the same continuing episode is not re-mailed"
else
	report FAIL "dispatch: the same continuing episode is not re-mailed" "$(mails "$city") mails"
fi
# Episode clears on a confidently-healthy leg; a later stall re-fires.
echo '{"beads":[],"total":0}' >"$city/pool.json"
run_sweep "$city"
echo '{"beads":[],"total":5}' >"$city/pool.json"
dispatch_failure "$city" 30
run_sweep "$city"
if [ "$(mails "$city")" = 2 ]; then
	report ok "dispatch: a cleared episode re-fires when the stall recurs"
else
	report FAIL "dispatch: a cleared episode re-fires when the stall recurs" "$(mails "$city") mails"
fi
rm -rf "$city"

# Leg removals, one at a time — each must file NOTHING.
city="$(new_city)"
dispatch_failure "$city" 60
run_sweep "$city"
if [ "$(mails "$city")" = 0 ]; then
	report ok "dispatch: an empty pool files nothing, whatever the log says"
else
	report FAIL "dispatch: an empty pool files nothing, whatever the log says" "$(mail_log "$city")"
fi
rm -rf "$city"

city="$(new_city)"
echo '{"beads":[],"total":5}' >"$city/pool.json"
dispatch_failure "$city" 60
wedged_session "$city" "$RIG/switchyard-ops.ps-live" s-live 10
run_sweep "$city"
if [ "$(mails "$city")" = 0 ]; then
	report ok "dispatch: a live worker session files nothing — the loop is dispatching"
else
	report FAIL "dispatch: a live worker session files nothing — the loop is dispatching" "$(mail_log "$city")"
fi
rm -rf "$city"

city="$(new_city)"
echo '{"beads":[],"total":5}' >"$city/pool.json"
dispatch_failure "$city" 7200
run_sweep "$city"
if [ "$(mails "$city")" = 0 ]; then
	report ok "dispatch: a stale failure is 'between cycles' and files nothing"
else
	report FAIL "dispatch: a stale failure is 'between cycles' and files nothing" "$(mail_log "$city")"
fi
rm -rf "$city"

city="$(new_city)"
echo '{"beads":[],"total":5}' >"$city/pool.json"
run_sweep "$city"
if [ "$(mails "$city")" = 0 ]; then
	report ok "dispatch: no failure on record files nothing — a full pool alone is not a stall"
else
	report FAIL "dispatch: no failure on record files nothing — a full pool alone is not a stall" "$(mail_log "$city")"
fi
rm -rf "$city"

# A circuit-breaker dispatch SKIP is the third named cause and satisfies the
# outcome leg exactly as a failed exec does.
city="$(new_city)"
echo '{"beads":[],"total":5}' >"$city/pool.json"
dispatch_failure "$city" 60 "skipped: circuit breaker open"
run_sweep "$city"
if [ "$(mails "$city")" = 1 ] && has "$(mail_log "$city")" "gc order run pool-spawn"; then
	report ok "dispatch: a circuit-breaker skip counts as an incomplete last cycle"
else
	report FAIL "dispatch: a circuit-breaker skip counts as an incomplete last cycle" "$(mail_log "$city")"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
echo
echo "witness-sweep self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
