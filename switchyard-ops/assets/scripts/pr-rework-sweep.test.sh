#!/usr/bin/env bash
#
# Self-test for packs/switchyard-ops/assets/scripts/pr-rework-sweep.sh — the
# order that turns a standing review rejection on an open PR into exactly one
# rework assignment.
#
# THE VERIFICATION CONTRACT
# -------------------------
#   "The sweep notices a reject verdict STANDING on an open PR's current head
#    and routes exactly one rework assignment per PR head, never a second
#    while the first is live, and never onto work that is merely unreviewed,
#    already approved, or already fixed."
#
# The discrimination cases are the load-bearing ones, because each failure is
# invisible in a diff read and silent in operation:
#
#   STANDING, NOT MERELY PRESENT. A reject comment that predates the head's
#   last commit is a verdict about content that may have changed — dispatching
#   on it puts a rework session onto a fix that is merely awaiting re-review.
#   The ONE exception is a head review-sweep's settled ledger records as
#   rejected: that is how a content-identical rebase keeps its verdict, and
#   the exact case (observed 2026-08-21) where "the author's ball" orphaned
#   rejected PRs for 6–8h while every lane reported healthy.
#
#   NEVER A SECOND WHILE THE FIRST IS LIVE. The assignment marker is keyed on
#   the exact PR head; losing the guard puts a fresh worker on the same PR
#   every cycle, making the marker permanent makes each head reworkable once,
#   ever. Both directions are asserted.
#
#   A FAILED DISPATCH LEAVES NOTHING LIVE and is mailed — a dropped
#   assignment that suppresses its own retry is the silent orphaning this
#   order exists to remove, reintroduced by its own bookkeeping.
#
# It runs hermetically: a throwaway city plus stub `gc`, `gh` and `git` on
# PATH, answering from per-case fixtures. No real city, repo or session is
# involved. Needs jq (skips without it).
#
# Run:  bash packs/switchyard-ops/assets/scripts/pr-rework-sweep.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SWEEP="$HERE/pr-rework-sweep.sh"

if ! command -v jq >/dev/null 2>&1; then
	echo "SKIP — pr-rework-sweep self-test needs jq (not on PATH)"
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
# Fixtures. Every case builds a FRESH city (repair-sweep.test.sh's rule): a
# fixture reused across cases accumulates markers and nudge logs, so a later
# case could pass on an earlier case's state — the exact confusion the sweep's
# dedup logic is about.
# ---------------------------------------------------------------------------

# new_city — scaffold a throwaway city plus stubs, and echo its path.
#
# The stub `gh` serves the two reads the sweep makes: the PR list and the
# per-PR view, each from a file a case can rewrite. The stub `git` answers
# only `remote get-url` (the slug derivation); the sweep does no other git.
# The rig root is a bare .git-holding directory registered in the stub rig
# list, so sy_rig_root resolves it without a real repository.
new_city() {
	local city
	city="$(mktemp -d)"
	mkdir -p "$city/bin" "$city/state" "$city/rigA/.git"

	cat >"$city/sessions.json" <<'JSON'
{"sessions":[{"template":"rigA/switchyard-ops.rework","alias":"rigA-rework-adhoc-stub","state":"active"}]}
JSON
	jq -n --arg p "$city/rigA" '[{"name":"rigA","path":$p}]' >"$city/rigs.json"
	echo '[]' >"$city/prlist.json"

	cat >"$city/bin/gc" <<'STUB'
#!/bin/sh
case "$1 $2" in
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
"session new")
	[ -f "$GC_CITY/spawn-broken" ] && exit 1
	printf 'SPAWN %s\n' "$3" >>"$GC_CITY/spawned.log"
	;;
"session wake")
	printf 'WAKE %s\n' "$3" >>"$GC_CITY/woken.log"
	;;
"mail send")
	subj=""
	while [ $# -gt 0 ]; do
		case "$1" in
		-s | --subject) subj="$2"; shift 2 ;;
		-m | --body) shift 2 ;;
		*) shift ;;
		esac
	done
	printf 'SUBJ %s\n' "$subj" >>"$GC_CITY/mailed.log"
	;;
esac
exit 0
STUB

	cat >"$city/bin/gh" <<'STUBGH'
#!/bin/sh
case "$1 $2" in
"pr list")
	[ -f "$GC_CITY/prlist-broken" ] && exit 1
	cat "$GC_CITY/prlist.json"
	;;
"pr view") cat "$GC_CITY/prview-$3.json" 2>/dev/null ;;
esac
exit 0
STUBGH

	cat >"$city/bin/git" <<'STUBGIT'
#!/bin/sh
for a in "$@"; do
	case "$a" in get-url) echo "https://github.com/stub/rigA.git"; exit 0 ;; esac
done
exit 0
STUBGIT

	chmod +x "$city/bin/gc" "$city/bin/gh" "$city/bin/git"
	printf '%s' "$city"
}

# pr CITY NUM HEAD [MERGEABLE] [DECISION] — add an open PR to the list read.
pr() {
	local t
	t="$(mktemp)"
	jq --argjson n "$2" --arg h "$3" --arg m "${4:-MERGEABLE}" --arg d "${5:-}" \
		'. += [{"number":$n,"isDraft":false,"labels":[],"createdAt":"2026-08-01T00:00:00Z",
		        "headRefOid":$h,"headRefName":("feat-" + ($n|tostring)),
		        "reviewDecision":$d,"mergeable":$m}]' \
		"$1/prlist.json" >"$t" && mv "$t" "$1/prlist.json" || rm -f "$t"
}

# view CITY NUM LAST_COMMIT_AT — the PR's view read: one non-merge commit,
# no comments, no reviews. Cases layer verdicts on with the helpers below.
view() {
	jq -n --arg t "$3" \
		'{"comments":[],"commits":[{"messageHeadline":"work","committedDate":$t}],"reviews":[]}' \
		>"$1/prview-$2.json"
}

# reject_comment CITY NUM AT [FINDINGS] — a marker-comment rejection.
reject_comment() {
	local t
	t="$(mktemp)"
	jq --arg at "$3" --arg b "Verdict: REQUEST CHANGES

${4:-finding: the frobnicator is unguarded}" \
		'.comments += [{"createdAt":$at,"body":$b,"author":{"login":"stub-reviewer"}}]' \
		"$1/prview-$2.json" >"$t" && mv "$t" "$1/prview-$2.json" || rm -f "$t"
}

# approve_comment CITY NUM AT — a marker-comment approval.
approve_comment() {
	local t
	t="$(mktemp)"
	jq --arg at "$3" \
		'.comments += [{"createdAt":$at,"body":"Verdict: APPROVE\n\nlooks right","author":{"login":"stub-reviewer"}}]' \
		"$1/prview-$2.json" >"$t" && mv "$t" "$1/prview-$2.json" || rm -f "$t"
}

# formal_cr CITY NUM AT — a formal CHANGES_REQUESTED review.
formal_cr() {
	local t
	t="$(mktemp)"
	jq --arg at "$3" \
		'.reviews += [{"state":"CHANGES_REQUESTED","submittedAt":$at,"body":"formal: needs a guard","author":{"login":"coderabbitai"}}]' \
		"$1/prview-$2.json" >"$t" && mv "$t" "$1/prview-$2.json" || rm -f "$t"
}

# settle CITY NUM HEAD VERDICT — write review-sweep's settled-ledger record
# for one exact head, using the same key transform as both sweeps.
settle() {
	mkdir -p "$1/state/review-assignments"
	printf '1755000000 %s abcdef0123456789\n' "$4" \
		>"$1/state/review-assignments/$(printf '%s' "stub/rigA#$2@$3" | tr -c 'A-Za-z0-9' '-').settled"
}

# The shell the sweep runs under (repair-sweep.test.sh's REPAIR_TEST_SH knob).
REWORK_TEST_SH="${REWORK_TEST_SH:-sh}"

# run_sweep CITY [TTL] — one sweep cycle against CITY. The lane switch lives
# in roster.conf, where an operator would set it.
run_sweep() {
	printf 'PR_REWORK_RIGS="rigA"\n' >"$1/state/roster.conf"
	GC_CITY="$1" \
		GC_PACK_STATE_DIR="$1/state" \
		PR_REWORK_ASSIGNMENT_TTL="${2:-7200}" \
		PATH="$1/bin:$PATH" \
		"$REWORK_TEST_SH" "$SWEEP" >/dev/null 2>&1
}

nudges() {
	local n
	[ -f "$1/nudged.log" ] || { echo 0; return 0; }
	n="$(grep -c '^NUDGE ' "$1/nudged.log" 2>/dev/null)"
	echo "${n:-0}"
}

# routed_for CITY NUM — how many dispatches name PR NUM, anchored on the
# message's PR REWORK header so a body mentioning a sibling cannot count.
routed_for() {
	local n
	[ -f "$1/nudged.log" ] || { echo 0; return 0; }
	n="$(grep -c "^PR REWORK stub/rigA#$2 " "$1/nudged.log" 2>/dev/null)"
	echo "${n:-0}"
}

# ---------------------------------------------------------------------------
# 1. POSITIVE CONTROL — load-bearing. If a standing reject did NOT route,
#    every negative case below would pass vacuously by routing nothing.
# ---------------------------------------------------------------------------
c="$(new_city)"
pr "$c" 7 aaa111
view "$c" 7 "2026-08-01T00:00:00Z"
reject_comment "$c" 7 "2026-08-02T00:00:00Z" "finding: the frobnicator is unguarded"
run_sweep "$c"
n="$(nudges "$c")"
if [ "$n" = 1 ] && [ "$(routed_for "$c" 7)" = 1 ]; then
	report ok "a standing reject routes exactly one rework assignment"
else
	report FAIL "a standing reject routes exactly one rework assignment" \
		"routed $n, $(routed_for "$c" 7) naming PR 7"
fi

# The assignment must carry the findings — a worker told only "go fix it" has
# not been handed the refusal — and must NOT claim a conflict this PR lacks.
if grep -q 'finding: the frobnicator is unguarded' "$c/nudged.log" 2>/dev/null &&
	! grep -q 'CONFLICTING' "$c/nudged.log" 2>/dev/null; then
	report ok "the assignment carries the reject findings and no false conflict note"
else
	report FAIL "the assignment carries the reject findings and no false conflict note" \
		"$(head -c 300 "$c/nudged.log" 2>/dev/null)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 2. NEVER A SECOND WHILE THE FIRST IS LIVE — three cycles, one assignment.
# ---------------------------------------------------------------------------
c="$(new_city)"
pr "$c" 7 aaa111
view "$c" 7 "2026-08-01T00:00:00Z"
reject_comment "$c" 7 "2026-08-02T00:00:00Z"
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
# 3. THE WINDOW ENDS. An assignment past its TTL is routed again — otherwise
#    the marker is a tombstone and each head is reworkable once, ever.
# ---------------------------------------------------------------------------
c="$(new_city)"
pr "$c" 7 aaa111
view "$c" 7 "2026-08-01T00:00:00Z"
reject_comment "$c" 7 "2026-08-02T00:00:00Z"
run_sweep "$c" 7200
run_sweep "$c" 0
n="$(nudges "$c")"
if [ "$n" = 2 ]; then
	report ok "an assignment past its liveness window is routed again"
else
	report FAIL "an assignment past its liveness window is routed again" "routed $n"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 4. ONLY A STANDING REJECT. An approved PR, an unreviewed PR, and a PR whose
#    newest standing verdict is an approve must all route nothing.
# ---------------------------------------------------------------------------
c="$(new_city)"
pr "$c" 1 aaa111 MERGEABLE APPROVED # formally approved: first-cut exclusion
view "$c" 1 "2026-08-01T00:00:00Z"
reject_comment "$c" 1 "2026-08-02T00:00:00Z"
pr "$c" 2 bbb222 # no verdict anywhere: the review lane's ball
view "$c" 2 "2026-08-01T00:00:00Z"
pr "$c" 3 ccc333 # rejected then approved: the approve is the standing verdict
view "$c" 3 "2026-08-01T00:00:00Z"
reject_comment "$c" 3 "2026-08-02T00:00:00Z"
approve_comment "$c" 3 "2026-08-03T00:00:00Z"
run_sweep "$c"
n="$(nudges "$c")"
if [ "$n" = 0 ]; then
	report ok "approved, unreviewed and approve-superseded PRs route no rework"
else
	report FAIL "approved, unreviewed and approve-superseded PRs route no rework" \
		"routed $n: $(grep '^PR REWORK' "$c/nudged.log" 2>/dev/null)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 5. A STALE REJECT IS NOT STANDING — unless the settled ledger says the
#    current head is still rejected. Both halves, same fixture: first no
#    ledger entry (the head moved with NEW content — the reviewer's ball),
#    then review-sweep's reject record for this exact head (a content-
#    identical rebase — this lane's work, the observed 6–8h orphan).
# ---------------------------------------------------------------------------
c="$(new_city)"
pr "$c" 7 rebased99
view "$c" 7 "2026-08-05T00:00:00Z"                            # rebase: fresh commit date
reject_comment "$c" 7 "2026-08-02T00:00:00Z" "finding: still unfixed" # verdict predates it
run_sweep "$c"
n="$(nudges "$c")"
if [ "$n" = 0 ]; then
	report ok "a reject predating the head routes nothing without a settled record"
else
	report FAIL "a reject predating the head routes nothing without a settled record" "routed $n"
fi
settle "$c" 7 rebased99 reject
run_sweep "$c"
n="$(nudges "$c")"
if [ "$n" = 1 ] && grep -q 'finding: still unfixed' "$c/nudged.log" 2>/dev/null; then
	report ok "a settled-rejected rebased head routes the rework with the old findings"
else
	report FAIL "a settled-rejected rebased head routes the rework with the old findings" "routed $n"
fi
rm -rf "$c"

# A settled APPROVE must not be read as a reject: field 2 is the verdict, and
# a reader that only checks the file's existence would dispatch rework onto an
# approved head the moment any rebase landed.
c="$(new_city)"
pr "$c" 7 rebased99
view "$c" 7 "2026-08-05T00:00:00Z"
reject_comment "$c" 7 "2026-08-02T00:00:00Z"
settle "$c" 7 rebased99 approve
run_sweep "$c"
n="$(nudges "$c")"
if [ "$n" = 0 ]; then
	report ok "a settled-approved rebased head routes nothing"
else
	report FAIL "a settled-approved rebased head routes nothing" "routed $n"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 6. A FORMAL CHANGES_REQUESTED REVIEW IS A REJECT TOO — the first cut must
#    keep the CHANGES_REQUESTED reviewDecision in (review-sweep excludes it,
#    for the opposite reason), and the reviews[] read must classify it.
# ---------------------------------------------------------------------------
c="$(new_city)"
pr "$c" 8 ddd444 MERGEABLE CHANGES_REQUESTED
view "$c" 8 "2026-08-01T00:00:00Z"
formal_cr "$c" 8 "2026-08-02T00:00:00Z"
run_sweep "$c"
n="$(nudges "$c")"
if [ "$n" = 1 ] && grep -q 'formal: needs a guard' "$c/nudged.log" 2>/dev/null; then
	report ok "a standing formal CHANGES_REQUESTED review routes the rework"
else
	report FAIL "a standing formal CHANGES_REQUESTED review routes the rework" "routed $n"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 6b. A FORMAL REJECT SURVIVES A REBASE VIA THE reviewDecision LATCH. The
#     settled ledger structurally cannot answer for a formal reject
#     (review-sweep's first cut drops those PRs before its settle path runs),
#     so the latch — which GitHub holds until a re-review or dismissal — is
#     the only signal left. Without this leg, every formally-rejected PR was
#     orphaned forever after its first rebase.
# ---------------------------------------------------------------------------
c="$(new_city)"
pr "$c" 8 rebased77 MERGEABLE CHANGES_REQUESTED
view "$c" 8 "2026-08-05T00:00:00Z"    # rebase: fresh commit date
formal_cr "$c" 8 "2026-08-02T00:00:00Z" # the review predates it
run_sweep "$c"
n="$(nudges "$c")"
if [ "$n" = 1 ] && grep -q 'formal: needs a guard' "$c/nudged.log" 2>/dev/null; then
	report ok "a rebased formally-rejected PR still routes via the reviewDecision latch"
else
	report FAIL "a rebased formally-rejected PR still routes via the reviewDecision latch" "routed $n"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 7. A CONFLICTING PR'S ASSIGNMENT SAYS SO. The conflict state is half the
#    brief — pr-refresh aborts conflicted rebases by design, so a rework that
#    is not told to resolve them pushes onto a branch that still cannot merge.
# ---------------------------------------------------------------------------
c="$(new_city)"
pr "$c" 9 eee555 CONFLICTING
view "$c" 9 "2026-08-01T00:00:00Z"
reject_comment "$c" 9 "2026-08-02T00:00:00Z"
run_sweep "$c"
if [ "$(nudges "$c")" = 1 ] && grep -q 'CONFLICTING' "$c/nudged.log" 2>/dev/null; then
	report ok "a conflicted PR's assignment carries the conflict state"
else
	report FAIL "a conflicted PR's assignment carries the conflict state" \
		"routed $(nudges "$c")"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 8. A FAILED DISPATCH LEAVES NOTHING LIVE. It must mail, and the next cycle
#    must retry — a dropped assignment that suppresses its own retry is the
#    silent orphaning this order exists to remove.
# ---------------------------------------------------------------------------
c="$(new_city)"
pr "$c" 7 aaa111
view "$c" 7 "2026-08-01T00:00:00Z"
reject_comment "$c" 7 "2026-08-02T00:00:00Z"
touch "$c/nudge-broken"
run_sweep "$c"
if grep -q '^SUBJ pr-rework-sweep: could not dispatch' "$c/mailed.log" 2>/dev/null; then
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
# 9. NO LIVE REWORK SESSION: spawn one, route NEXT cycle (a nudge into a
#    booting pane is lost behind a live marker). An ASLEEP session is woken,
#    never buried under a second spawn that bounces off max_active_sessions=1.
# ---------------------------------------------------------------------------
c="$(new_city)"
pr "$c" 7 aaa111
view "$c" 7 "2026-08-01T00:00:00Z"
reject_comment "$c" 7 "2026-08-02T00:00:00Z"
echo '{"sessions":[]}' >"$c/sessions.json"
run_sweep "$c"
n_spawn="$(grep -c '^SPAWN rigA/switchyard-ops.rework$' "$c/spawned.log" 2>/dev/null)" || n_spawn=0
if [ "$(nudges "$c")" = 0 ] && [ "$n_spawn" = 1 ]; then
	report ok "no live rework session spawns one and routes next cycle"
else
	report FAIL "no live rework session spawns one and routes next cycle" \
		"routed $(nudges "$c"), spawned: $(cat "$c/spawned.log" 2>/dev/null)"
fi
cat >"$c/sessions.json" <<'JSON'
{"sessions":[{"template":"rigA/switchyard-ops.rework","alias":"rigA-rework-adhoc-stub","state":"active"}]}
JSON
run_sweep "$c"
if [ "$(nudges "$c")" = 1 ]; then
	report ok "the next cycle routes to the now-live session"
else
	report FAIL "the next cycle routes to the now-live session" "routed $(nudges "$c")"
fi
rm -rf "$c"

c="$(new_city)"
pr "$c" 7 aaa111
view "$c" 7 "2026-08-01T00:00:00Z"
reject_comment "$c" 7 "2026-08-02T00:00:00Z"
cat >"$c/sessions.json" <<'JSON'
{"sessions":[{"template":"rigA/switchyard-ops.rework","alias":"rigA-rework-adhoc-stub","state":"asleep"}]}
JSON
run_sweep "$c"
n_wake="$(grep -c '^WAKE rigA-rework-adhoc-stub$' "$c/woken.log" 2>/dev/null)" || n_wake=0
n_spawn="$(grep -c '^SPAWN ' "$c/spawned.log" 2>/dev/null)" || n_spawn=0
if [ "$(nudges "$c")" = 0 ] && [ "$n_wake" = 1 ] && [ "$n_spawn" = 0 ]; then
	report ok "an asleep rework session is woken, not respawned"
else
	report FAIL "an asleep rework session is woken, not respawned" \
		"nudges $(nudges "$c") wake=$n_wake spawn=$n_spawn"
fi
rm -rf "$c"

# A FAILED spawn is not "warming": the PR must reach the failure accumulation
# and the mayor mail within the same cycle — the silent-failure invariant.
c="$(new_city)"
pr "$c" 7 aaa111
view "$c" 7 "2026-08-01T00:00:00Z"
reject_comment "$c" 7 "2026-08-02T00:00:00Z"
echo '{"sessions":[]}' >"$c/sessions.json"
: >"$c/spawn-broken"
run_sweep "$c"
if [ "$(nudges "$c")" = 0 ] && grep -q 'could not dispatch' "$c/mailed.log" 2>/dev/null; then
	report ok "a failed rework spawn mails no-live-worker instead of going quiet"
else
	report FAIL "a failed rework spawn mails no-live-worker instead of going quiet" \
		"routed $(nudges "$c"), mail: $(cat "$c/mailed.log" 2>/dev/null)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 9b. A DELIVERED ASSIGNMENT FREES THE SESSION. The marker's dispatch-dedup
#     job outlives the work, but its busy-ness must not: once the dispatched
#     PR's head moves (the rework pushed), the next standing-rejected PR must
#     route without waiting out the TTL — otherwise one 20-minute rework pins
#     the rig's throughput for hours.
# ---------------------------------------------------------------------------
c="$(new_city)"
pr "$c" 7 aaa111
view "$c" 7 "2026-08-01T00:00:00Z"
reject_comment "$c" 7 "2026-08-02T00:00:00Z"
run_sweep "$c" # cycle 1: dispatches PR 7
# The rework lands: PR 7's head moves (its fix awaits re-review — no standing
# verdict), and PR 12 arrives standing-rejected.
echo '[]' >"$c/prlist.json"
pr "$c" 7 fff000
view "$c" 7 "2026-08-03T00:00:00Z"
reject_comment "$c" 7 "2026-08-02T00:00:00Z" # predates the fixed head: stale, no ledger record
pr "$c" 12 bbb999
view "$c" 12 "2026-08-01T00:00:00Z"
reject_comment "$c" 12 "2026-08-02T00:00:00Z"
run_sweep "$c" # cycle 2: PR 7's marker is stamped delivered; PR 12 routes
if [ "$(nudges "$c")" = 2 ] && [ "$(routed_for "$c" 12)" = 1 ]; then
	report ok "a delivered assignment frees the session for the next rejected PR"
else
	report FAIL "a delivered assignment frees the session for the next rejected PR" \
		"routed $(nudges "$c") total, $(routed_for "$c" 12) naming PR 12"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 9c. A FAILED PR LIST IS A FAILURE, NOT AN EMPTY QUEUE. An API outage or an
#     expired token must mail within the cycle — laundered into a zero-byte
#     queue it reads exactly like a rig with no rejected PRs, forever.
# ---------------------------------------------------------------------------
c="$(new_city)"
pr "$c" 7 aaa111
view "$c" 7 "2026-08-01T00:00:00Z"
reject_comment "$c" 7 "2026-08-02T00:00:00Z"
: >"$c/prlist-broken"
run_sweep "$c"
if [ "$(nudges "$c")" = 0 ] && grep -q 'could not dispatch' "$c/mailed.log" 2>/dev/null; then
	report ok "a failed gh pr list is mailed instead of reading as a quiet queue"
else
	report FAIL "a failed gh pr list is mailed instead of reading as a quiet queue" \
		"routed $(nudges "$c"), mail: $(cat "$c/mailed.log" 2>/dev/null)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 9d. A MARKER THAT DID NOT PERSIST ENDS THE CYCLE. The busy gate reads the
#     marker directory, so an unwritable state dir means the next candidate
#     reads the singleton session as free and nudges it again — dropping the
#     PR just sent to a max-1, fresh-wake agent. The write failure must be
#     mailed AND stop further dispatch: a bookkeeping fault must not become
#     lost work.
# ---------------------------------------------------------------------------
# The unwritable directory below is the whole mechanism, and root ignores the
# permission bits that create it — the marker would WRITE, the case would
# assert against a fault that never happened, and a red here would say nothing
# about the sweep. CI runs unprivileged, so the guard executes there; skipping
# under root is the suite's tool-missing posture, not a silenced assertion.
if [ "$(id -u 2>/dev/null || echo 1)" = 0 ]; then
	echo "SKIP — the marker-write-failure case needs an unprivileged user (root ignores chmod)"
else
c="$(new_city)"
pr "$c" 7 aaa111
view "$c" 7 "2026-08-01T00:00:00Z"
reject_comment "$c" 7 "2026-08-02T00:00:00Z"
pr "$c" 12 bbb999
view "$c" 12 "2026-08-01T00:00:00Z"
reject_comment "$c" 12 "2026-08-02T00:00:00Z"
# Make the assignment directory unwritable so the marker write fails while the
# nudge itself succeeds — the exact split this case is about.
run_sweep "$c" >/dev/null 2>&1 # cycle 0: create the dirs
rm -f "$c"/state/pr-rework-assignments/* 2>/dev/null
rm -f "$c/nudged.log"
chmod 500 "$c/state/pr-rework-assignments"
run_sweep "$c"
chmod 700 "$c/state/pr-rework-assignments"
n="$(nudges "$c")"
if [ "$n" = 1 ] && grep -q 'marker-write-failed\|could not dispatch' "$c/mailed.log" 2>/dev/null; then
	report ok "a marker that did not persist stops the cycle instead of double-nudging"
else
	report FAIL "a marker that did not persist stops the cycle instead of double-nudging" \
		"nudged $n (want 1), mail: $(cat "$c/mailed.log" 2>/dev/null)"
fi
rm -rf "$c"
fi

# ---------------------------------------------------------------------------
# 10. THE SESSION IS BUSY WITH A CRITERION REPAIR. Both sweeps route to the
#     same singleton specialist; a fresh repair-sweep assignment naming this
#     alias means a nudge now would drop that repair on the floor. Quiet wait,
#     no mail — the serialization is the agent's own pool ceiling.
# ---------------------------------------------------------------------------
c="$(new_city)"
pr "$c" 7 aaa111
view "$c" 7 "2026-08-01T00:00:00Z"
reject_comment "$c" 7 "2026-08-02T00:00:00Z"
mkdir -p "$c/state/repair-assignments"
printf '%s rigA-rework-adhoc-stub\n' "$(date +%s)" >"$c/state/repair-assignments/prd330-crit-aaa"
run_sweep "$c"
if [ "$(nudges "$c")" = 0 ] && [ ! -s "$c/mailed.log" ]; then
	report ok "a session holding a live criterion repair is not handed a PR too"
else
	report FAIL "a session holding a live criterion repair is not handed a PR too" \
		"routed $(nudges "$c"), mail: $(cat "$c/mailed.log" 2>/dev/null)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 11. A CLEAN CITY IS SILENT, and a held PR is exempt.
# ---------------------------------------------------------------------------
c="$(new_city)"
pr "$c" 2 bbb222
view "$c" 2 "2026-08-01T00:00:00Z"
run_sweep "$c"
if [ "$(nudges "$c")" = 0 ] && [ ! -s "$c/mailed.log" ]; then
	report ok "a city with no standing rejects routes nothing and mails nothing"
else
	report FAIL "a city with no standing rejects routes nothing and mails nothing" \
		"routed $(nudges "$c"), mail: $(cat "$c/mailed.log" 2>/dev/null)"
fi
rm -rf "$c"

c="$(new_city)"
t="$(mktemp)"
jq '. += [{"number":5,"isDraft":false,"labels":[{"name":"do-not-merge"}],
           "createdAt":"2026-08-01T00:00:00Z","headRefOid":"held01",
           "headRefName":"feat-5","reviewDecision":"","mergeable":"MERGEABLE"}]' \
	"$c/prlist.json" >"$t" && mv "$t" "$c/prlist.json"
view "$c" 5 "2026-08-01T00:00:00Z"
reject_comment "$c" 5 "2026-08-02T00:00:00Z"
run_sweep "$c"
if [ "$(nudges "$c")" = 0 ]; then
	report ok "a PR carrying the hold label is never dispatched"
else
	report FAIL "a PR carrying the hold label is never dispatched" "routed $(nudges "$c")"
fi
rm -rf "$c"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
