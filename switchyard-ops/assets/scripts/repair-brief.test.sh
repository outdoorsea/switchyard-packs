#!/usr/bin/env bash
#
# Self-test for the repair assignment's BRIEF, in
# packs/switchyard-ops/assets/scripts/repair-sweep.sh
# (switchyard PRD #330, crit:d1c12adefee0).
#
# THE VERIFICATION CONTRACT
# -------------------------
#   "The repair assignment carries the judge's reason and the prior delivery's
#    evidence in the assignment itself, so the worker does not have to discover
#    why it was rejected."
#
# The trailing clause is the whole criterion, and it is what makes this
# separable from the sibling that routes the assignment (crit:b6ea44d544e6).
# That one is satisfied by a message naming the criterion; this one is not.
# Before it, the message ENDED with "read the rejecting verdict and its reason
# before you change anything" — a correct instruction that still made the worker
# go and find the reason, which is precisely the discovery this criterion
# removes. So a suite that only asserts "an assignment was routed", or only that
# the message mentions the criterion, proves nothing here: both were already
# true. Every positive case below therefore asserts the presence of the REASON
# TEXT ITSELF, and case 3 asserts the absence of the pointer that replaced it.
#
# WHY THE REASON IS HARD TO CARRY, and why the fixtures look the way they do.
# The rationale is stored on prd_criterion_validations, but NO criterion-shaped
# read exposes that column — not the daily rollup the sweep notices rejections
# in (DailyReportValidation carries validator/evidence_ref/verdict but no
# rationale), and not /criteria. The only read that surfaces it is the
# DELIVERING BEAD's handoff chain, where AttachJudgmentFailGuidance mirrors it
# into `broken_or_unverified` on a `judgment_fail` row. So the brief is assembled
# from two reads, and the interesting failures are all at that seam: the bead
# cannot be resolved, the chain holds an unrelated handoff, or the criterion was
# rejected more than once and the brief must speak about the CURRENT rejection.
#
# THE COLLIDING INVARIANT IS PINNED HERE TOO (case 5). The brief is enrichment
# hung off a routing path whose shipped guarantee is "exactly one assignment per
# rejected criterion". Those two interact in one specific way: the routing set is
# deduped with `sort -u` over `prd<TAB>label`, so had the brief been implemented
# by widening what the rollup read emits, a criterion rejected twice would have
# become two distinct rows and been routed TWICE. That regression would pass
# every other case in this file, and every case in the sibling's file (whose
# fixtures reject each criterion once), so it is asserted explicitly rather than
# left to the sibling suite.
#
# It runs hermetically: a throwaway city plus stub `gc`, `switchyard-mcp` and
# `curl` on PATH, answering from per-case fixtures. No real city, rig, session,
# mayor or switchyard instance is involved. Needs jq (skips without it).
#
# Run:  bash packs/switchyard-ops/assets/scripts/repair-brief.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SWEEP="$HERE/repair-sweep.sh"

if ! command -v jq >/dev/null 2>&1; then
	echo "SKIP — repair-brief self-test needs jq (not on PATH)"
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

# The distinctive rationale a judge recorded. Deliberately a phrase that appears
# NOWHERE in the sweep's own message template, so an assertion that finds it in
# the routed body can only have got it from the fixture — a generic string like
# "rejected" would be satisfied by the boilerplate and every positive case would
# pass vacuously.
REASON='the retry ceiling is read from a hardcoded 3 instead of project policy'
REASON2='the second rejection: it still never reads project policy'

# ---------------------------------------------------------------------------
# Fixtures. A FRESH city per case: markers and nudge logs accumulate, so a reused
# fixture lets a later case pass on an earlier one's state.
# ---------------------------------------------------------------------------

# new_city — scaffold a throwaway city plus stubs, and echo its path.
#
# Same shape as the sibling repair-sweep suite, plus the delivery-evidence read
# the brief needs. The stub `curl` drains stdin FIRST and unconditionally:
# sy_api_get pipes the Authorization header into `curl --config -`, and a stub
# that never reads it leaves the producing `printf` on a broken pipe, failing the
# read on its SUCCESS path.
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

	# The delivering bead's audit read: an empty chain until a case says otherwise.
	echo '{"bead_id":"stub","handoffs":[],"prd_prs":[]}' >"$city/evidence.json"

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

	# `evidence-broken` makes the audit read fail the way an unresolvable bead
	# really does (curl -f on a 404 → empty), which is the degrade case.
	cat >"$city/bin/curl" <<'STUBCURL'
#!/bin/sh
cat >/dev/null   # drain the --config payload carrying the Authorization header
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
*/delivery-evidence*)
	[ -f "$GC_CITY/evidence-broken" ] && exit 22
	printf '%s\n' "$url" >>"$GC_CITY/evidence-urls.log"
	cat "$GC_CITY/evidence.json"
	;;
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

# reject CITY PRD LABEL [VALIDATOR] [EVIDENCE_REF] [VALIDATED_AT] — record a
# judgment `fail` in TODAY's rollup, with the fields the brief reports.
reject() {
	local t
	t="$(mktemp)"
	jq --argjson p "$2" --arg l "$3" --arg v "${4:-judge/stub}" \
		--arg e "${5:-}" --arg a "${6:-2026-08-09T12:00:00Z}" \
		'.retro.validations += [{"prd_id":$p,"crit_label":$l,"verdict":"fail",
		  "validator":$v,"evidence_ref":$e,"validated_at":$a,
		  "verdict_provenance":"judgment"}]' \
		"$1/rollup.json" >"$t" && mv "$t" "$1/rollup.json" || rm -f "$t"
}

# reject_prev — the same, in YESTERDAY's rollup. The sweep reads both days, so a
# criterion refused on each is the cross-day duplicate case 5 pins.
reject_prev() {
	local t
	t="$(mktemp)"
	jq --argjson p "$2" --arg l "$3" --arg v "${4:-judge/stub}" \
		--arg e "${5:-}" --arg a "${6:-2026-08-08T12:00:00Z}" \
		'.retro.validations += [{"prd_id":$p,"crit_label":$l,"verdict":"fail",
		  "validator":$v,"evidence_ref":$e,"validated_at":$a,
		  "verdict_provenance":"judgment"}]' \
		"$1/rollup-prev.json" >"$t" && mv "$t" "$1/rollup-prev.json" || rm -f "$t"
}

# criterion CITY PRD LABEL [CLAIMED_BY] — put a criterion in the criteria read.
#
# Carries prd_id because the real /criteria read always does (criterionTriageRow
# tags it with no omitempty), and the live-claim guard narrows on the
# (prd_id, crit_label) PAIR — a label alone is not unique in a project-wide read.
# A stub without it modelled a payload the server never sends.
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

# handoff CITY ACTION TEXT — PREPEND a handoff to the delivering bead's chain.
#
# Prepended because the real read returns the chain newest-first (bead_handoffs
# is ORDER BY created_at DESC), so "added last" must mean "newest" for the
# newest-wins cases to be testing what they claim.
handoff() {
	local t
	t="$(mktemp)"
	jq --arg a "$2" --arg b "$3" \
		'.handoffs = ([{"action":$a,"broken_or_unverified":$b}] + (.handoffs // []))' \
		"$1/evidence.json" >"$t" && mv "$t" "$1/evidence.json" || rm -f "$t"
}

# delivery_pr CITY URL — attach a PR to the prior delivery's evidence.
delivery_pr() {
	local t
	t="$(mktemp)"
	jq --arg u "$2" '.prd_prs += [{"url":$u}]' \
		"$1/evidence.json" >"$t" && mv "$t" "$1/evidence.json" || rm -f "$t"
}

REPAIR_TEST_SH="${REPAIR_TEST_SH:-sh}"

run_sweep() {
	GC_CITY="$1" \
		GC_PACK_STATE_DIR="$1/state" \
		SWITCHYARD_API_TOKEN="sy_stub_token" \
		REPAIR_ASSIGNMENT_TTL="${2:-3600}" \
		PATH="$1/bin:$PATH" \
		"$REPAIR_TEST_SH" "$SWEEP" >/dev/null 2>&1
}

# nudges CITY — how many assignments were routed. `grep -c` prints 0 AND exits 1,
# so the count is captured and defaulted rather than `|| echo 0`'d, which would
# emit "0 0" and make every count assertion unparseable.
nudges() {
	local n
	[ -f "$1/nudged.log" ] || { echo 0; return 0; }
	n="$(grep -c '^NUDGE ' "$1/nudged.log" 2>/dev/null)"
	echo "${n:-0}"
}

# body_has CITY TEXT — does any routed assignment carry TEXT?
# Greps the FILE, never a pipeline: under `set -o pipefail` a `producer | grep -q`
# fails on its SUCCESS path when grep exits early and the producer takes SIGPIPE.
body_has() {
	[ -f "$1/nudged.log" ] && grep -qF "$2" "$1/nudged.log" 2>/dev/null
}

# block_for CITY LABEL — the routed assignment BODY that names LABEL, on its own.
#
# Whole-file greps cannot answer "did THIS assignment carry its own judge": with
# two assignments in the log, every string either case wrote is present somewhere
# in it, so a cross-contamination bug reads as a pass. Bodies are delimited by the
# stub's `NUDGE <alias>` header line, and a block is kept when its first line is
# this criterion's REPAIR header.
block_for() {
	[ -f "$1/nudged.log" ] || return 0
	awk -v want="REPAIR $2 " '
		/^NUDGE /{ if (keep) printf "%s", blk; blk=""; keep=0; next }
		{ blk = blk $0 "\n"; if (substr($0, 1, length(want)) == want) keep=1 }
		END { if (keep) printf "%s", blk }
	' "$1/nudged.log"
}

# ---------------------------------------------------------------------------
# 1. POSITIVE CONTROL — the judge's REASON reaches the assignment body.
#    Load-bearing: if the reason never arrives, every "carries X" case below
#    would be measuring an empty brief, and case 3's absence assertion would
#    pass for the wrong reason.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
criterion "$c" 330 "crit:aaa"
handoff "$c" judgment_fail "A validator judged the prior delivery insufficient and rejected it: $REASON"
run_sweep "$c"
if [ "$(nudges "$c")" = 1 ] && body_has "$c" "$REASON"; then
	report ok "the assignment carries the judge's recorded reason"
else
	report FAIL "the assignment carries the judge's recorded reason" \
		"routed $(nudges "$c"); body: $(tail -c 400 "$c/nudged.log" 2>/dev/null)"
fi

# The brief must be labelled, not smuggled in as an unattributed sentence: a
# worker scanning the message needs to see WHY it was rejected as its own thing.
if body_has "$c" "WHY IT WAS REJECTED"; then
	report ok "the reason is presented under its own heading"
else
	report FAIL "the reason is presented under its own heading" \
		"$(tail -c 400 "$c/nudged.log" 2>/dev/null)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 2. THE PRIOR DELIVERY'S EVIDENCE — who refused it, what they reviewed, and
#    what the prior delivery actually was. The criterion names the evidence
#    alongside the reason, so a brief carrying only the rationale is half-built.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa" "judge/independent-1" "https://github.com/o/r/pull/999"
criterion "$c" 330 "crit:aaa"
handoff "$c" judgment_fail "A validator judged the prior delivery insufficient and rejected it: $REASON"
delivery_pr "$c" "https://github.com/o/r/pull/1234"
run_sweep "$c"
missing=""
body_has "$c" "judge/independent-1" || missing="$missing validator"
body_has "$c" "https://github.com/o/r/pull/999" || missing="$missing reviewed-evidence-ref"
body_has "$c" "https://github.com/o/r/pull/1234" || missing="$missing prior-delivery-pr"
body_has "$c" "2026-08-09T12:00:00Z" || missing="$missing rejected-at"
if [ -z "$missing" ]; then
	report ok "the assignment carries who rejected it, when, what they reviewed, and the prior delivery"
else
	report FAIL "the assignment carries who rejected it, when, what they reviewed, and the prior delivery" \
		"absent:$missing"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 3. NOT A POINTER — the message must not merely TELL the worker to go read the
#    verdict. This is the criterion's "does not have to discover" clause, and it
#    is the one assertion that fails against the pre-change message: that text
#    routed a worker correctly and named the criterion, so cases 1-2 aside,
#    nothing else in this file distinguishes it.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
criterion "$c" 330 "crit:aaa"
handoff "$c" judgment_fail "A validator judged the prior delivery insufficient and rejected it: $REASON"
run_sweep "$c"
if body_has "$c" "read the rejecting verdict and its reason before you change anything"; then
	report FAIL "the assignment does not send the worker off to discover the reason" \
		"the message still instructs the worker to go read the verdict"
else
	report ok "the assignment does not send the worker off to discover the reason"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 4. THE BRIEF DEGRADES, IT NEVER STALLS THE ROUTING. An unreadable audit read
#    (an unresolvable bead — a rig-lane `sw-` delivery, a 404, a blip) must still
#    route the assignment, and must say the reason is missing rather than imply
#    there was none. Withholding the repair here would convert a degraded brief
#    into the silent stall this whole order exists to remove.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
criterion "$c" 330 "crit:aaa"
touch "$c/evidence-broken"
run_sweep "$c"
n="$(nudges "$c")"
if [ "$n" = 1 ] && body_has "$c" "could not be read"; then
	report ok "an unreadable rejection record still routes, and says the reason is missing"
else
	report FAIL "an unreadable rejection record still routes, and says the reason is missing" \
		"routed $n; body: $(tail -c 400 "$c/nudged.log" 2>/dev/null)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 5. THE SIBLING GUARANTEE SURVIVES THE BRIEF — exactly one assignment for a
#    criterion rejected TWICE, including once on each day the sweep reads.
#
#    This is the regression the implementation shape was chosen to avoid: the
#    routing set is deduped `sort -u` over `prd<TAB>label`, so a brief built by
#    widening that record with per-verdict fields (validator, timestamp) would
#    make these two rejections two distinct rows and route the worker twice.
#    Nothing else in either suite would catch it — the sibling's fixtures reject
#    each criterion exactly once.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa" "judge/second" "" "2026-08-09T18:00:00Z"
reject "$c" 330 "crit:aaa" "judge/first" "" "2026-08-09T09:00:00Z"
reject_prev "$c" 330 "crit:aaa" "judge/day-before" "" "2026-08-08T09:00:00Z"
criterion "$c" 330 "crit:aaa"
handoff "$c" judgment_fail "A validator judged the prior delivery insufficient and rejected it: $REASON"
run_sweep "$c"
n="$(nudges "$c")"
if [ "$n" = 1 ]; then
	report ok "a criterion rejected three times over two days is still routed exactly one assignment"
else
	report FAIL "a criterion rejected three times over two days is still routed exactly one assignment" \
		"routed $n"
fi

# ...and the brief speaks about the CURRENT rejection, not a superseded one. A
# brief that reported the first verdict would send the worker to answer criticism
# that has already been superseded.
if body_has "$c" "judge/second"; then
	report ok "the brief reports the newest rejection, not a superseded one"
else
	report FAIL "the brief reports the newest rejection, not a superseded one" \
		"$(tail -c 400 "$c/nudged.log" 2>/dev/null)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 6. THE NEWEST REJECTION'S RATIONALE WINS. A criterion refused twice has two
#    judgment_fail handoffs; the brief must carry the one that routed THIS
#    assignment. Reporting the older text is worse than reporting none — it is
#    confidently wrong about what the worker has to answer.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
criterion "$c" 330 "crit:aaa"
handoff "$c" judgment_fail "A validator judged the prior delivery insufficient and rejected it: $REASON"
handoff "$c" judgment_fail "A validator judged the prior delivery insufficient and rejected it: $REASON2"
run_sweep "$c"
if body_has "$c" "$REASON2" && ! body_has "$c" "$REASON"; then
	report ok "the newest rejection's rationale is the one carried"
else
	report FAIL "the newest rejection's rationale is the one carried" \
		"$(tail -c 400 "$c/nudged.log" 2>/dev/null)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 7. A CONTENTLESS ROW MUST NOT SHADOW THE REASON. The chain also holds markers
#    written when a session accounted for nothing, and they can be NEWER than the
#    rejection. Picking the newest row blindly would report an empty reason and
#    silently degrade a brief that was fully available.
#
#    ROBUSTNESS, NOT A LIVE PATH — and worth saying plainly. The empty
#    `judgment_fail` row below is a shape today's only writer cannot emit:
#    AttachJudgmentFailGuidance is the sole caller stamping that action and it
#    returns early on a blank rationale. The fixture is deliberately that shape
#    anyway, because the alternative — a realistic bare marker, which carries a
#    `release`/`complete` action — is excluded by the action filter case 8
#    already binds, so it would leave the emptiness guard asserted by nothing and
#    reading like a guard that had been tested. This costs one impossible fixture
#    and buys a guard that stays honest if that writer's precondition ever moves.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
criterion "$c" 330 "crit:aaa"
handoff "$c" judgment_fail "A validator judged the prior delivery insufficient and rejected it: $REASON"
handoff "$c" release "" # a realistic bare marker, newer than the rejection
handoff "$c" judgment_fail ""
run_sweep "$c"
if body_has "$c" "$REASON"; then
	report ok "a newer contentless row does not shadow the recorded reason"
else
	report FAIL "a newer contentless row does not shadow the recorded reason" \
		"$(tail -c 400 "$c/nudged.log" 2>/dev/null)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 8. ONLY A JUDGMENT FAIL IS THE JUDGE'S REASON. A worker's own release handoff
#    also carries broken_or_unverified text. Presenting one as "why a judge
#    rejected this" would attribute a builder's note to a reviewer — a brief that
#    is not merely incomplete but false.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
criterion "$c" 330 "crit:aaa"
handoff "$c" release "ran out of context, the migration is half-written"
run_sweep "$c"
if body_has "$c" "ran out of context"; then
	report FAIL "a worker's release note is not reported as the judge's reason" \
		"a release handoff was presented as the rejection"
elif [ "$(nudges "$c")" = 1 ] && body_has "$c" "could not be read"; then
	report ok "a worker's release note is not reported as the judge's reason"
else
	report FAIL "a worker's release note is not reported as the judge's reason" \
		"routed $(nudges "$c"); body: $(tail -c 400 "$c/nudged.log" 2>/dev/null)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 9. THE BRIEF COSTS NOTHING ON A SUPPRESSED REJECTION. A criterion already held
#    by a worker is not routed, and must not be audited either: the read is a
#    network call per criterion per cycle, and the sweep walks every rig.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa"
criterion "$c" 330 "crit:aaa" "someone/else"
handoff "$c" judgment_fail "A validator judged the prior delivery insufficient and rejected it: $REASON"
run_sweep "$c"
if [ "$(nudges "$c")" = 0 ] && [ ! -f "$c/evidence-urls.log" ]; then
	report ok "a suppressed rejection is not audited for a brief it will never send"
else
	report FAIL "a suppressed rejection is not audited for a brief it will never send" \
		"routed $(nudges "$c"), evidence reads: $(wc -l <"$c/evidence-urls.log" 2>/dev/null || echo 0)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 10. THE BRIEF IS READ FOR THE RIGHT BEAD. The delivering bead is derived from
#     the criterion (prd-{prd}-{hash}, poolBeadID's documented determinism); a
#     derivation that dropped the `crit:` prefix or the PRD would read another
#     bead's chain and attribute a stranger's rejection to this criterion.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:d1c12adefee0"
criterion "$c" 330 "crit:d1c12adefee0"
handoff "$c" judgment_fail "A validator judged the prior delivery insufficient and rejected it: $REASON"
run_sweep "$c"
if [ -f "$c/evidence-urls.log" ] && grep -qF "/beads/prd-330-d1c12adefee0/delivery-evidence" "$c/evidence-urls.log"; then
	report ok "the brief audits the criterion's own delivering bead"
else
	report FAIL "the brief audits the criterion's own delivering bead" \
		"read: $(cat "$c/evidence-urls.log" 2>/dev/null)"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 11. EACH ASSIGNMENT CARRIES ITS OWN REJECTION. Two criteria refused in one
#     cycle must not cross-contaminate: the brief is assembled INSIDE the routing
#     loop, and POSIX sh has no `local`, so every variable it sets is global. A
#     field left over from the previous criterion — or simply not re-cleared when
#     the second read comes back empty — would attribute one judge's verdict to
#     another criterion, which is worse than an absent brief: it is a confident,
#     checkable-looking statement that is false.
#
#     ONE PRD, TWO LABELS — the fixture varies exactly ONE thing. The lookup is
#     keyed on the (prd_id, crit_label) pair, so a fixture that changed BOTH
#     halves at once would be separated by EITHER key alone: neutralise the label
#     filter and the PRD filter still tells the two apart, and the case passes
#     over a lookup that no longer keys on the criterion at all. Holding the PRD
#     constant makes the label the only thing that can discriminate, so this case
#     measures the half it names. Case 12 is its mirror for the other half.
#
#     The timestamps are explicit because the unkeyed failure mode is "take the
#     NEWEST fail in the rollup": bbb must be unambiguously newer than aaa for
#     the bleed to have a defined direction rather than depending on jq's sort
#     stability over two equal keys.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:aaa" "judge/alpha" "https://github.com/o/r/pull/111" "2026-08-09T09:00:00Z"
reject "$c" 330 "crit:bbb" "judge/beta" "https://github.com/o/r/pull/222" "2026-08-09T18:00:00Z"
criterion "$c" 330 "crit:aaa"
criterion "$c" 330 "crit:bbb"
handoff "$c" judgment_fail "A validator judged the prior delivery insufficient and rejected it: $REASON"
run_sweep "$c"
a_block="$(block_for "$c" "crit:aaa")"
b_block="$(block_for "$c" "crit:bbb")"
bleed=""
grep -qF "judge/alpha" <<<"$a_block" || bleed="$bleed aaa-missing-own-judge"
grep -qF "judge/beta" <<<"$a_block" && bleed="$bleed aaa-carries-bbb-judge"
grep -qF "judge/beta" <<<"$b_block" || bleed="$bleed bbb-missing-own-judge"
grep -qF "judge/alpha" <<<"$b_block" && bleed="$bleed bbb-carries-aaa-judge"
grep -qF "pull/111" <<<"$a_block" || bleed="$bleed aaa-missing-own-evidence"
grep -qF "pull/111" <<<"$b_block" && bleed="$bleed bbb-carries-aaa-evidence"
if [ "$(nudges "$c")" = 2 ] && [ -z "$bleed" ]; then
	report ok "two rejections in one cycle each carry their own judge and evidence"
else
	report FAIL "two rejections in one cycle each carry their own judge and evidence" \
		"routed $(nudges "$c"); bleed:${bleed:- none}"
fi
rm -rf "$c"

# ---------------------------------------------------------------------------
# 12. A LABEL IS NOT UNIQUE ACROSS PRDs — the mirror of case 11, holding the
#     LABEL constant so the PRD is the only thing that can discriminate.
#
#     `crit_label` is `crit:<hash of the criterion's TEXT>`, so two PRDs in one
#     project that carry the same boilerplate acceptance line carry the SAME
#     label — and the rollup the brief is assembled from is project-wide, not
#     PRD-scoped, so both verdicts sit in the one document. The codebase keys the
#     pair for exactly this reason: `prd_criterion_phases` is keyed
#     `(prd_id, crit_label)`, not by label alone. The routing set is deduped on
#     `prd<TAB>label` and the suppression marker on `prd<n>-<label>`, so both
#     rejections ARE routed — two assignments whose briefs must not be swapped.
#
#     Selected by the assignment's own header line (`REPAIR <label> (PRD #<n>,`)
#     rather than by label, which no longer names a single block.
# ---------------------------------------------------------------------------
c="$(new_city)"
reject "$c" 330 "crit:shared" "judge/alpha" "https://github.com/o/r/pull/111" "2026-08-09T09:00:00Z"
reject "$c" 331 "crit:shared" "judge/beta" "https://github.com/o/r/pull/222" "2026-08-09T18:00:00Z"
criterion "$c" 330 "crit:shared"
criterion "$c" 331 "crit:shared"
handoff "$c" judgment_fail "A validator judged the prior delivery insufficient and rejected it: $REASON"
run_sweep "$c"
a_block="$(block_for "$c" "crit:shared (PRD #330,")"
b_block="$(block_for "$c" "crit:shared (PRD #331,")"
bleed=""
grep -qF "judge/alpha" <<<"$a_block" || bleed="$bleed 330-missing-own-judge"
grep -qF "judge/beta" <<<"$a_block" && bleed="$bleed 330-carries-331-judge"
grep -qF "judge/beta" <<<"$b_block" || bleed="$bleed 331-missing-own-judge"
grep -qF "judge/alpha" <<<"$b_block" && bleed="$bleed 331-carries-330-judge"
grep -qF "pull/111" <<<"$a_block" || bleed="$bleed 330-missing-own-evidence"
grep -qF "pull/222" <<<"$b_block" || bleed="$bleed 331-missing-own-evidence"
grep -qF "pull/111" <<<"$b_block" && bleed="$bleed 331-carries-330-evidence"
if [ "$(nudges "$c")" = 2 ] && [ -z "$bleed" ]; then
	report ok "two PRDs sharing one criterion label do not swap briefs"
else
	report FAIL "two PRDs sharing one criterion label do not swap briefs" \
		"routed $(nudges "$c"); bleed:${bleed:- none}"
fi
rm -rf "$c"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
