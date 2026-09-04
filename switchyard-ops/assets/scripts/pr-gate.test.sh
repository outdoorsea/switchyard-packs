#!/usr/bin/env bash
#
# Self-test for packs/switchyard-ops/assets/scripts/pr-gate.sh — specifically its
# DEFERRAL to the pr-review working lane (switchyard PRD #360 P2,
# crit:b5602a794658).
#
# THE VERIFICATION CONTRACT
# -------------------------
#   "An aged item PR is escalated to the mayor UNLESS switchyard says a worker
#    already holds a pr-review bead for that PR at its current head — and a
#    deferral costs the PR nothing: it neither spends the tier nor survives the
#    bead's close."
#
# Two lanes now look at the same pull request. This one REPORTS an item PR that
# has aged past a tier; switchyard's pr-review lane mints a claimable bead per
# (PR, head sha) and a brakeman drains it — reviews, posts the verdict, merges.
# Reporting a PR the other lane is actively working tells a mayor "nobody has
# picked this up" about work that is moving, which is the same mislabelling the
# order's 2026-08-04 correction removed once already.
#
# The four failure modes this suite exists for, each of which passes a casual
# read of the diff:
#
#   THE CLAIMED HALF IS THE WHOLE POINT. "Open or claimed" is not decoration.
#   The cheap implementation asks the claim POOL whether the bead is there, and
#   the pool only ever lists UNCLAIMED work — so it answers "nobody has started"
#   and goes silent exactly when nobody is working, while double-reporting every
#   PR a brakeman is holding. Every live status is asserted, not just `open`.
#
#   A DEFERRAL MUST NOT SPEND THE TIER. The once-per-tier ledger is what keeps
#   this order quiet, and a skip written into it would convert "somebody is on
#   it" into permanent silence at that tier. A `request_changes` verdict closes
#   the bead and leaves the PR unmerged and unheld — the single most important
#   moment for this order to speak — so the suite runs that exact sequence in ONE
#   city: deferred at T1, then reported at T1 after the bead closes.
#
#   A CLOSED BEAD IS NOT A HELD ONE. `status <> closed` is the live test; keying
#   on "a bead exists" would silence the order forever after the first review.
#
#   AN UNREADABLE SWITCHYARD MUST NOT SILENCE THE GATE. The probe fails OPEN in
#   the reporting direction. A gate that goes quiet when its dependency is down
#   is a dead check that looks healthy — the exact failure class this pack was
#   written to catch — so the unreachable case asserts the mail still goes out.
#
# It runs hermetically: a throwaway city with stub `gc`, `gh` and `curl` on PATH,
# answering from fixtures. No real city, rig, session, network or token.
#
# Run:  bash packs/switchyard-ops/assets/scripts/pr-gate.test.sh
#       PR_GATE_TEST_SH=dash bash packs/switchyard-ops/assets/scripts/pr-gate.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/pr-gate.sh"

for tool in jq; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "SKIP — pr-gate self-test needs $tool (not on PATH)"
		exit 0
	fi
done
# The probe derives switchyard's bead id with a sha256 of its own; with no digest
# tool it correctly derives nothing and defers nothing, which would take every
# exclusion case green for the wrong reason.
if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1 &&
	! command -v openssl >/dev/null 2>&1; then
	echo "SKIP — pr-gate self-test needs a sha256 tool (shasum, sha256sum or openssl)"
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

# iso_ago HOURS — an ISO8601 UTC timestamp that many hours in the past, GNU then
# BSD. The same portability posture as the order's own iso_to_epoch.
iso_ago() {
	date -u -d "$1 hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return 0
	date -u -v-"$1"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return 0
	echo ""
}

if [ -z "$(iso_ago 4)" ]; then
	echo "SKIP — pr-gate self-test needs a date(1) that can subtract hours"
	exit 0
fi

# ---------------------------------------------------------------------------
# Fixtures. Every case builds a FRESH city, except the one that deliberately
# runs two cycles against the same state: the $SEEN ledger accumulates, and
# whether a deferral wrote to it IS the subject under test.
# ---------------------------------------------------------------------------

# new_city — scaffold a throwaway city plus stubs, and echo its path.
#
# One rig, `rigA`, bound to the switchyard project `acme/rigA` by the slug
# convention sy_project_for_rig derives (the rig name matching the project slug),
# so no roster.conf binding is needed.
#
# The `curl` stub answers the switchyard API from fixtures and logs every URL to
# curl.log, so a case can assert both WHAT was asked and — for the integration
# class — that nothing was asked at all. A MISSING fixture exits 22 with no
# output, exactly as real `curl -f` reports a non-2xx: that is the "unreadable"
# mode, not a harness error.
new_city() {
	local city
	city="$(mktemp -d)"
	mkdir -p "$city/bin" "$city/state"
	: >"$city/state/roster.conf"

	cat >"$city/rigs.json" <<'JSON'
[{"name":"rigA","default_branch":"main"}]
JSON
	echo '[]' >"$city/beads.rigA.json"
	cat >"$city/api.projects.json" <<'JSON'
{"projects":[{"slug":"rigA","tenant_slug":"acme"}]}
JSON

	cat >"$city/bin/gc" <<'STUB'
#!/bin/sh
case "$1 $2" in
"rig list") cat "$GC_CITY/rigs.json" ;;
"bd list")
	rig=""
	while [ $# -gt 0 ]; do
		[ "$1" = "--rig" ] && { rig="$2"; break; }
		shift
	done
	cat "$GC_CITY/beads.$rig.json" 2>/dev/null || echo '[]'
	;;
"mail send")
	# The whole invocation, so a case can grep subject and body alike.
	printf 'MAIL %s\n' "$*" >>"$GC_CITY/mailed.log"
	;;
*) echo '[]' ;;
esac
exit 0
STUB
	chmod +x "$city/bin/gc"

	# `gh pr view <num> --repo <slug> --json <fields>` -> pr.<num>.json. A missing
	# fixture prints nothing, which the order reads as a transient gh failure.
	cat >"$city/bin/gh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$GC_CITY/gh.log"
case "$1 $2" in
"pr view") cat "$GC_CITY/pr.$3.json" 2>/dev/null || exit 1 ;;
*) exit 1 ;;
esac
STUB
	chmod +x "$city/bin/gh"

	cat >"$city/bin/curl" <<'STUB'
#!/bin/sh
# Drain the header config on stdin so the writing shell never takes a SIGPIPE.
cat >/dev/null 2>&1

url=""
for a in "$@"; do
	case "$a" in http://* | https://*) url="$a" ;; esac
done
printf '%s\n' "$url" >>"$GC_CITY/curl.log"

case "$url" in
*/api/v1/projects)
	f="$GC_CITY/api.projects.json"
	;;
*/beads/prreview-*/delivery-evidence)
	# The bead id carries the PR number ("prreview-<num>-<hash>"), so the fixture
	# is keyed on the number and the suite never has to reproduce the hash. The
	# id's SHAPE is asserted separately, from curl.log.
	id="${url##*/beads/}"
	id="${id%%/delivery-evidence}"
	rest="${id#prreview-}"
	f="$GC_CITY/api.review.${rest%%-*}.json"
	;;
*)
	exit 22
	;;
esac

[ -f "$f" ] || exit 22 # a missing fixture IS a non-2xx, the same as curl -f
cat "$f"
STUB
	chmod +x "$city/bin/curl"

	printf '%s' "$city"
}

# add_item_pr CITY NUM AGE_HOURS — an open item PR that has aged AGE_HOURS, with
# the closed work bead that carries its pr_url. Item class: a `gc-item-*` head
# against the integration branch, which is what the tiers escalate.
add_item_pr() {
	local city="$1" num="$2" age="$3" t
	t="$(mktemp)"
	jq --arg id "sy-item-$num" --arg url "https://github.com/acme/rigA/pull/$num" \
		'. += [{"id":$id,"status":"closed","metadata":{"pr_url":$url}}]' \
		"$city/beads.rigA.json" >"$t" && mv "$t" "$city/beads.rigA.json"

	jq -n --arg created "$(iso_ago "$age")" --arg num "$num" '{
		state:"OPEN", baseRefName:"staging", headRefName:("gc-item-" + $num),
		headRefOid:("f00dcafe" + $num + "00000000000000000000000000000"),
		createdAt:$created, reviewDecision:"", mergeable:"MERGEABLE"
	}' >"$city/pr.$num.json"
}

# add_integration_pr CITY NUM AGE_HOURS — a promotion PR: base = the rig default
# branch, head not an item branch. Reported on the wide tier, never probed.
add_integration_pr() {
	local city="$1" num="$2" age="$3" t
	t="$(mktemp)"
	jq --arg id "sy-int-$num" --arg url "https://github.com/acme/rigA/pull/$num" \
		'. += [{"id":$id,"status":"closed","metadata":{"pr_url":$url}}]' \
		"$city/beads.rigA.json" >"$t" && mv "$t" "$city/beads.rigA.json"

	jq -n --arg created "$(iso_ago "$age")" --arg num "$num" '{
		state:"OPEN", baseRefName:"main", headRefName:"staging",
		headRefOid:("beadfeed" + $num + "00000000000000000000000000000"),
		createdAt:$created, reviewDecision:"", mergeable:"MERGEABLE"
	}' >"$city/pr.$num.json"
}

# review_bead CITY NUM STATUS — switchyard's answer for that PR's review bead.
# The delivery-evidence read's shape, reduced to the field the probe reads.
review_bead() {
	jq -n --arg s "$3" --arg n "$2" \
		'{project_id:1, bead_id:("prreview-" + $n + "-000000000000"), status:$s}' \
		>"$1/api.review.$2.json"
}

# no_review_bead CITY NUM — switchyard has no such bead (the fixture's absence
# makes the stub exit 22, i.e. a 404).
no_review_bead() { rm -f "$1/api.review.$2.json"; }

# The shell the order itself runs under — the same knob as the sibling suites, so
# CI can run this POSIX order under dash explicitly.
PR_GATE_TEST_SH="${PR_GATE_TEST_SH:-sh}"

# run_gate CITY — one sweep cycle against the scaffolded city.
run_gate() {
	GC_CITY="$1" \
		GC_PACK_STATE_DIR="$1/state" \
		SWITCHYARD_BASE_URL="http://sy.test" \
		SWITCHYARD_API_TOKEN="sy_testtoken" \
		PATH="$1/bin:$PATH" \
		"$PR_GATE_TEST_SH" "$GATE" >/dev/null 2>&1
}

mailed_about() { # CITY NUM — did any mail to the mayor name that PR?
	grep -q "/pull/$2" "$1/mailed.log" 2>/dev/null
}

probed() { # CITY NUM — was a delivery-evidence read issued for that PR?
	grep -q "/beads/prreview-$2-[0-9a-f]\{12\}/delivery-evidence" "$1/curl.log" 2>/dev/null
}

seen_keys() { # CITY — the once-per-tier ledger, or empty
	cat "$1/state/pr-gate.reported" 2>/dev/null
}

# ---------------------------------------------------------------------------
# CONTROL — no review bead: the order reports exactly as it always has.
#
# Every absence assertion below leans on this. It proves the harness reaches the
# escalation at all: the rig is walked, the bead's pr_url is read, `gh` answers,
# the age crosses T1, and the mayor is mailed.
# ---------------------------------------------------------------------------
city="$(new_city)"
add_item_pr "$city" 101 10
no_review_bead "$city" 101
run_gate "$city"

if mailed_about "$city" 101; then
	report ok "CONTROL: an aged item PR with no pr-review bead is escalated"
else
	report FAIL "CONTROL: an aged item PR with no pr-review bead is escalated" \
		"$(cat "$city/mailed.log" 2>/dev/null)"
fi

if probed "$city" 101; then
	report ok "CONTROL: the probe asks switchyard about the PR's own review bead"
else
	report FAIL "CONTROL: the probe asks switchyard about the PR's own review bead" \
		"$(cat "$city/curl.log" 2>/dev/null)"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# THE EXCLUSION — every LIVE status defers, not merely `open`.
#
# `claimed` and `in_progress` are the statuses a brakeman actually holds a bead
# in, and they are the two the pool-listing implementation cannot see. A suite
# that only asserted `open` would pass against a probe that double-reports every
# PR anybody is working on.
# ---------------------------------------------------------------------------
for status in open claimed in_progress; do
	city="$(new_city)"
	add_item_pr "$city" 202 10
	review_bead "$city" 202 "$status"
	run_gate "$city"

	if mailed_about "$city" 202; then
		report FAIL "a PR whose pr-review bead is '$status' is NOT escalated" \
			"$(cat "$city/mailed.log" 2>/dev/null)"
	else
		report ok "a PR whose pr-review bead is '$status' is NOT escalated"
	fi
	rm -rf "$city"
done

# ---------------------------------------------------------------------------
# A CLOSED BEAD IS NOT A HELD ONE. The review landed (a `request_changes` verdict
# closes the bead and leaves the PR unmerged and unheld); the reporting lane is
# the only thing left watching it, so it must speak.
# ---------------------------------------------------------------------------
city="$(new_city)"
add_item_pr "$city" 303 10
review_bead "$city" 303 closed
run_gate "$city"

if mailed_about "$city" 303; then
	report ok "a PR whose pr-review bead has CLOSED is escalated again"
else
	report FAIL "a PR whose pr-review bead has CLOSED is escalated again" \
		"$(cat "$city/mailed.log" 2>/dev/null)"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# THE DEFERRAL DOES NOT SPEND THE TIER — the sequence, in one city.
#
# Cycle 1: the bead is claimed, the PR is deferred, and NOTHING is written to the
# once-per-tier ledger. Cycle 2: the review closed with the PR still open at the
# same tier, and T1 is still owed, so it is reported. Had the deferral consumed
# the tier, cycle 2 would be silent — a PR that a review rejected and nobody
# merged, escalated by nothing, which is the state this whole order exists for.
# ---------------------------------------------------------------------------
city="$(new_city)"
add_item_pr "$city" 404 10
review_bead "$city" 404 claimed
run_gate "$city"

if mailed_about "$city" 404; then
	report FAIL "cycle 1: the held PR is deferred" "$(cat "$city/mailed.log" 2>/dev/null)"
else
	report ok "cycle 1: the held PR is deferred"
fi

if [ -n "$(seen_keys "$city")" ]; then
	report FAIL "a deferral writes NO once-per-tier key" "$(seen_keys "$city")"
else
	report ok "a deferral writes NO once-per-tier key"
fi

# Each later cycle asserts what THAT cycle mailed, so the mail log is cleared
# between them — otherwise cycle 2 would pass on cycle 1's escalation, which is
# exactly the output an order with no deferral at all produces.
: >"$city/mailed.log"
review_bead "$city" 404 closed
run_gate "$city"

if mailed_about "$city" 404; then
	report ok "cycle 2: the tier survived the deferral and is reported once the bead closes"
else
	report FAIL "cycle 2: the tier survived the deferral and is reported once the bead closes" \
		"$(cat "$city/mailed.log" 2>/dev/null)"
fi

# And the ordinary once-per-tier suppression is intact: a third cycle in the same
# state says nothing more. Without this, "the tier survived" could equally be
# satisfied by a probe that had broken the ledger outright.
: >"$city/mailed.log"
run_gate "$city"
if [ -s "$city/mailed.log" ]; then
	report FAIL "cycle 3: the tier is still reported ONCE, not every sweep" \
		"$(cat "$city/mailed.log" 2>/dev/null)"
else
	report ok "cycle 3: the tier is still reported ONCE, not every sweep"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# FAIL OPEN — an unreadable switchyard reports, it does not silence.
#
# No api.projects.json, so the project list is a non-2xx: the rig resolves to no
# project and nothing is deferred. A probe that failed CLOSED here would take the
# whole gate quiet the moment switchyard, the token or the network went away,
# and the city would look healthy.
# ---------------------------------------------------------------------------
city="$(new_city)"
rm -f "$city/api.projects.json"
add_item_pr "$city" 505 10
review_bead "$city" 505 claimed # would defer, if the project resolved at all
run_gate "$city"

if mailed_about "$city" 505; then
	report ok "an unreadable switchyard still escalates (fails open)"
else
	report FAIL "an unreadable switchyard still escalates (fails open)" \
		"$(cat "$city/mailed.log" 2>/dev/null)"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
# THE INTEGRATION CLASS IS UNTOUCHED. A promotion PR mints no review bead by
# construction, so it is reported on its own wide tier and never probed — the
# deferral must not have widened into the class it was not written for, nor spend
# a call per sweep asking a question with a known answer.
# ---------------------------------------------------------------------------
city="$(new_city)"
add_integration_pr "$city" 606 200
review_bead "$city" 606 claimed # present, and deliberately never consulted
run_gate "$city"

if mailed_about "$city" 606; then
	report ok "an aged integration PR is still reported"
else
	report FAIL "an aged integration PR is still reported" \
		"$(cat "$city/mailed.log" 2>/dev/null)"
fi

if probed "$city" 606; then
	report FAIL "an integration PR is never probed" "$(cat "$city/curl.log" 2>/dev/null)"
else
	report ok "an integration PR is never probed"
fi
rm -rf "$city"

# ---------------------------------------------------------------------------
echo
echo "pr-gate self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
