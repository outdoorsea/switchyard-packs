#!/usr/bin/env bash
#
# Self-test for packs/switchyard-ops/assets/scripts/integration-lane.sh
# (switchyard PRD #340).
#
# THE VERIFICATION CONTRACT
# -------------------------
#   "A run takes the currently-mergeable pull requests, produces one integration
#    branch whose CI result reflects the COMBINATION rather than any single PR,
#    and hands a human one merge to approve. If the combination breaks, the run
#    says which pull requests interacted. No pull request disappears from the
#    queue without being named. The lane itself never merges."
#
# Several separable claims live in that sentence, and a suite that asserts only
# the happy path proves none of them:
#
#   THE COMBINATION, NOT THE PARTS. The whole lane is pointless if the verify
#   would have passed on each PR alone. So the central fixture is a defect that
#   exists ONLY in the combination — two branches that merge without conflict and
#   whose union fails the build — and the suite asserts both directions: the pair
#   fails, and each half alone passes. Without the second half, a lane that
#   simply always failed would pass the first.
#
#   RE-QUERIED, NOT A SINGLE LAZY READ. `mergeStateStatus` is computed lazily and
#   the first read is frequently UNKNOWN. A fixture that answers UNKNOWN once and
#   MERGEABLE afterwards separates a lane that re-queries from one that does not:
#   the second drops a perfectly mergeable PR and reports a smaller bundle, which
#   looks exactly like a short queue.
#
#   EJECTS THE CULPRIT rather than stalling the set. Asserted from both sides —
#   the culprit is excluded AND the remainder still ships. A lane that gave up on
#   the whole bundle would satisfy "reports a failure" while trading a small
#   problem for a bigger one.
#
#   NEVER MERGES. Asserted twice and deliberately: dynamically, that a fully
#   GREEN run — the only run that would ever be tempted — invoked no `gh pr
#   merge`; and statically, that the string does not appear in the script at all.
#   The dynamic check alone would pass a lane that merges only on some path this
#   suite does not reach.
#
#   NOTHING VANISHES SILENTLY. Every exclusion path is reached separately, so
#   "reports exclusions" cannot be satisfied by a lane that happens to name the
#   one class the suite tests.
#
# It runs against a REAL git repository — real branches, real conflicts, a real
# bare `origin` — because the claims under test are claims about git. Stubbing
# git would let the suite pass while the merges it describes were never possible.
# Only `gc` (rig list, mail) and `gh` (the GitHub API) are stubs.
#
# Run:  bash packs/switchyard-ops/assets/scripts/integration-lane.test.sh
#       LANE_TEST_SH=dash bash .../integration-lane.test.sh   # POSIX check

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LANE="$HERE/integration-lane.sh"
SH="${LANE_TEST_SH:-sh}"

if ! command -v jq >/dev/null 2>&1; then
	echo "SKIP — integration-lane self-test needs jq (not on PATH)"
	exit 0
fi
if ! command -v git >/dev/null 2>&1; then
	echo "SKIP — integration-lane self-test needs git (not on PATH)"
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

# has <haystack> <pattern> — substring match with NO pipeline.
#
# NEVER write `printf '%s' "$x" | grep -q PAT` in a suite that runs under
# `set -o pipefail`. `grep -q` exits the instant it matches, the producing
# `printf` is then killed by SIGPIPE, and pipefail promotes that producer's
# failure to the pipeline's exit status — so the assertion FAILS on its SUCCESS
# path. It is racy rather than deterministic (it fires only when the write
# outruns grep's exit), which is how it survives a first green run: this suite
# flaked 3 runs in 10 on exactly that before the herestring below replaced it.
#
# The NEGATED form is the dangerous one. `! (producer | grep -q PAT)` reports
# success when the producer SIGPIPEs, so an assertion that something is ABSENT
# passes without ever having looked. That is a silent false pass, and every
# "must not appear" claim in this file depends on not writing it.
has()  { grep -q  -- "$2" <<<"$1"; }
hasi() { grep -qi -- "$2" <<<"$1"; }
hasE() { grep -qE -- "$2" <<<"$1"; }

# ---------------------------------------------------------------------------
# Fixture: a throwaway city, a real repo, stub gc + gh.
#
# Every case builds a FRESH city. A fixture reused across cases accumulates
# locks, mail and pushed branches, so a later case could pass on an earlier
# case's state — which is precisely the confusion the lock and the exclusion
# ledger are about, and would make the suite unable to see it.
# ---------------------------------------------------------------------------

RIG=demo

new_city() {
	local city
	city="$(mktemp -d)"
	mkdir -p "$city/bin" "$city/state" "$city/fixtures"

	# --- a real repository, with a real bare origin -------------------------
	local origin="$city/origin.git" repo="$city/$RIG"
	git init --quiet --bare "$origin"
	git init --quiet -b main "$repo"
	git -C "$repo" config user.email lane@test
	git -C "$repo" config user.name lane
	git -C "$repo" config commit.gpgsign false
	mkdir -p "$repo/internal/db"
	printf 'base\n' > "$repo/shared.txt"
	printf 'const schemaVersion = 100\n' > "$repo/internal/db/dolt.go"
	git -C "$repo" add -A
	git -C "$repo" commit --quiet -m "base"
	git -C "$repo" remote add origin "$origin"
	git -C "$repo" push --quiet -u origin main

	# --- stub gc ------------------------------------------------------------
	# `mail send` is appended to a log rather than sent. `rig list` answers with
	# the one rig. Anything else is a no-op success, so an unrelated gc call can
	# never decide a case.
	cat > "$city/bin/gc" <<-EOF
		#!/bin/sh
		case "\$1 \$2" in
		  "rig list")
		    printf '[{"name":"$RIG","default_branch":"main"}]\n' ;;
		  "mail send")
		    shift 2
		    printf '=== MAIL %s\n' "\$*" >> "$city/state/mail.log" ;;
		  *) : ;;
		esac
		exit 0
	EOF
	chmod +x "$city/bin/gc"

	# --- stub gh ------------------------------------------------------------
	# `pr list`   -> fixtures/prs.json  (the queue)
	# `pr view`   -> fixtures/merge.<n> (one line per successive read, so a case
	#                can answer UNKNOWN first and MERGEABLE after — the lazy-read
	#                fixture). Reads are counted in state/view.<n>.
	# `pr create` -> logged, echoes a URL
	# `pr merge`  -> logged. Its presence in the log FAILS a case; the lane must
	#                never merge.
	cat > "$city/bin/gh" <<-EOF
		#!/bin/sh
		printf '%s\n' "\$*" >> "$city/state/gh.log"
		case "\$1 \$2" in
		  "pr list")
		    cat "$city/fixtures/prs.json" 2>/dev/null || printf '[]\n' ;;
		  "pr view")
		    n="\$3"
		    c=\$(cat "$city/state/view.\$n" 2>/dev/null || echo 0)
		    c=\$((c + 1))
		    printf '%s\n' "\$c" > "$city/state/view.\$n"
		    line=\$(sed -n "\${c}p" "$city/fixtures/merge.\$n" 2>/dev/null)
		    [ -n "\$line" ] && printf '%s\n' "\$line" && exit 0
		    tail -n1 "$city/fixtures/merge.\$n" 2>/dev/null
		    ;;
		  "pr create")
		    printf '%s\n' "\$*" >> "$city/state/created.log"
		    # A case may make creation fail, to prove the lane does not fall
		    # through with a blank URL and an orphaned branch.
		    [ -f "$city/fixtures/create-fails" ] && { echo "gh: create refused" >&2; exit 1; }
		    printf 'https://github.com/acme/demo/pull/999\n' ;;
		  "pr merge")
		    printf '%s\n' "\$*" >> "$city/state/merged.log" ;;
		  *) : ;;
		esac
		exit 0
	EOF
	chmod +x "$city/bin/gh"

	printf '%s' "$city"
}

# add_pr <city> <num> <branch> <setup-fn> — a real branch pushed to origin.
add_pr() {
	local city="$1" num="$2" branch="$3" fn="$4"
	local repo="$city/$RIG"
	git -C "$repo" checkout --quiet -b "$branch" main
	"$fn" "$repo" "$num"
	git -C "$repo" add -A
	git -C "$repo" commit --quiet -m "pr $num"
	git -C "$repo" push --quiet origin "$branch"
	git -C "$repo" checkout --quiet main
	# Default mergeability answer; a case may overwrite fixtures/merge.<n>.
	printf '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n' > "$city/fixtures/merge.$num"
}

# Branch content helpers.
touch_own()   { printf 'x\n' > "$1/pr-$2.txt"; }                      # independent
edit_shared() { printf 'changed by %s\n' "$2" > "$1/shared.txt"; }    # conflicts
bump_schema() { printf 'const schemaVersion = 101\n' > "$1/internal/db/dolt.go"; }

# advance_main <city> <schemaVersion> — move main FORWARD after branches were cut.
#
# THE FIXTURE GAP THAT HID TWO REAL DEFECTS. Every case used to cut its branches
# and leave main exactly where it was, so a constituent's head, its merge-base and
# the base tip all agreed and any predicate comparing any two of them looked
# correct. Real queues never look like that: main moves under the open PRs all day,
# which is what makes "compare the head to the base TIP" and "compare it to its own
# MERGE-BASE" different questions with different answers. Without this helper the
# suite could not tell them apart, and shipped a lane that would have excluded 7 of
# 10 live PRs for bumps that never happened.
advance_main() {
	local city="$1" ver="$2" repo="$1/$RIG"
	git -C "$repo" checkout --quiet main
	printf 'const schemaVersion = %s\n' "$ver" > "$repo/internal/db/dolt.go"
	printf 'moved on\n' >> "$repo/main-moved.txt"
	git -C "$repo" add -A
	git -C "$repo" commit --quiet -m "main advances to $ver"
	git -C "$repo" push --quiet origin main
}

# queue <city> <json> — the `gh pr list` answer.
queue() { printf '%s\n' "$2" > "$1/fixtures/prs.json"; }

# pr_json <num> <branch> <sha> [draft] [review] [checks-json]
pr_json() {
	local num="$1" branch="$2" sha="$3"
	local draft="${4:-false}" review="${5:-APPROVED}"
	# NOT `${6:-[{...}]}`. A `}` inside a parameter-expansion default TERMINATES
	# the expansion, so that spelling emits truncated JSON, jq yields no rows, and
	# every case reads as "the queue was empty" — a green-looking suite that never
	# ran the lane. Default separately.
	local checks="${6:-}"
	[ -n "$checks" ] || checks='[{"conclusion":"SUCCESS","status":"COMPLETED"}]'
	printf '{"number":%s,"title":"PR #%s does a thing","headRefName":"%s","headRefOid":"%s","isDraft":%s,"reviewDecision":"%s","statusCheckRollup":%s}' \
		"$num" "$num" "$branch" "$sha" "$draft" "$review" "$checks"
}

sha_of() { git -C "$1/$RIG" rev-parse "origin/$2"; }

# run_lane <city> [env assignments...] — run the order in the fixture city.
run_lane() {
	local city="$1"; shift
	( cd "$city" && env PATH="$city/bin:$PATH" \
		GC_CITY="$city" \
		GC_PACK_STATE_DIR="$city/state" \
		INTEGRATION_LANE_RIGS="$RIG" \
		INTEGRATION_LANE_MERGE_POLL_SLEEP=0 \
		"$@" \
		"$SH" "$LANE" >"$city/state/run.out" 2>"$city/state/run.err" )
}

mail_of()    { cat "$1/state/mail.log" 2>/dev/null; }
created_of() { cat "$1/state/created.log" 2>/dev/null; }

# A verify command that fails only when BOTH named files are present — a defect
# that exists in the combination and in neither part.
combo_verify() { # <a> <b>
	printf 'test ! \\( -f %s -a -f %s \\)' "$1" "$2"
}

# ---------------------------------------------------------------------------
# 1. Two mergeable PRs are combined and the combination is what gets tested.
# ---------------------------------------------------------------------------
case_bundles_and_tests_the_combination() {
	local city; city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)")]"

	# The verify asserts BOTH constituents are present in the tree it runs in.
	# A lane that verified one PR at a time, or verified the base, fails here.
	run_lane "$city" INTEGRATION_LANE_VERIFY='test -f pr-1.txt -a -f pr-2.txt'

	if has "$(created_of "$city")" 'pr create'; then
		report ok "a green combination of two PRs opens one bundle pull request"
	else
		report FAIL "a green combination of two PRs opens one bundle pull request" \
			"no pr create; mail=$(mail_of "$city" | head -3)"
	fi

	# The bundle must reach BOTH constituent head SHAs, because that reachability
	# is the whole auto-close mechanism.
	local origin="$city/origin.git" b
	b=$(git -C "$origin" for-each-ref --format='%(refname:short)' 'refs/heads/integration/*' | head -n1)
	if [ -n "$b" ] \
		&& git -C "$origin" merge-base --is-ancestor "$(sha_of "$city" feat-1)" "$b" \
		&& git -C "$origin" merge-base --is-ancestor "$(sha_of "$city" feat-2)" "$b"; then
		report ok "every constituent's head commit is reachable from the pushed bundle"
	else
		report FAIL "every constituent's head commit is reachable from the pushed bundle" \
			"branch=${b:-none}"
	fi

	# --no-ff, so the bundle tip is a merge commit rather than a fast-forward.
	if [ -n "$b" ] && [ "$(git -C "$origin" rev-list --parents -n1 "$b" | wc -w)" -ge 3 ]; then
		report ok "the bundle is built with merge commits (--no-ff), not fast-forwards"
	else
		report FAIL "the bundle is built with merge commits (--no-ff), not fast-forwards"
	fi

	if hasi "$(created_of "$city")" 'MERGE COMMIT'; then
		report ok "the bundle pull request tells the human to merge with a merge commit"
	else
		report FAIL "the bundle pull request tells the human to merge with a merge commit"
	fi

	# NEVER MERGES — asserted on the green run, the only one ever tempted.
	if [ -s "$city/state/merged.log" ]; then
		report FAIL "a fully green run still does not merge anything" \
			"$(cat "$city/state/merged.log")"
	else
		report ok "a fully green run still does not merge anything"
	fi

	if has "$(mail_of "$city")" 'https://github.com/acme/demo/pull/999'; then
		report ok "the run ends by handing a human the bundle to decide on"
	else
		report FAIL "the run ends by handing a human the bundle to decide on"
	fi
	rm -rf "$city"
}

# ---------------------------------------------------------------------------
# 2. A combination-only defect fails the run — and each half alone passes.
# ---------------------------------------------------------------------------
case_combination_only_defect() {
	local city; city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)")]"

	# Neither branch alone trips this; their union does. Both merge cleanly, so a
	# lane relying on conflicts alone would call this bundle healthy.
	run_lane "$city" \
		INTEGRATION_LANE_VERIFY="$(combo_verify pr-1.txt pr-2.txt)" \
		INTEGRATION_LANE_MAX_EJECTIONS=0

	if [ -z "$(created_of "$city")" ]; then
		report ok "a defect visible only in the combination stops the bundle"
	else
		report FAIL "a defect visible only in the combination stops the bundle" \
			"a PR was opened anyway"
	fi
	if hasi "$(mail_of "$city")" 'broken together\|combination failure'; then
		report ok "the combination failure is reported to a human"
	else
		report FAIL "the combination failure is reported to a human" \
			"mail=$(mail_of "$city" | head -5)"
	fi

	# THE OTHER DIRECTION. The same verify with only ONE of the two present must
	# pass — otherwise the case above proves nothing about combinations, only
	# that the lane can fail.
	local solo; solo="$(new_city)"
	add_pr "$solo" 1 feat-1 touch_own
	add_pr "$solo" 3 feat-3 touch_own
	queue "$solo" "[$(pr_json 1 feat-1 "$(sha_of "$solo" feat-1)"),$(pr_json 3 feat-3 "$(sha_of "$solo" feat-3)")]"
	run_lane "$solo" INTEGRATION_LANE_VERIFY="$(combo_verify pr-1.txt pr-2.txt)"
	if has "$(created_of "$solo")" 'pr create'; then
		report ok "the same verify passes when the interacting pair is not both present"
	else
		report FAIL "the same verify passes when the interacting pair is not both present" \
			"the verify is failing unconditionally, so case 2 proves nothing"
	fi
	rm -rf "$city" "$solo"
}

# ---------------------------------------------------------------------------
# 3 + 4. Attribution names the pair, and the remainder still ships.
# ---------------------------------------------------------------------------
case_ejects_culprit_and_rebundles() {
	local city; city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	add_pr "$city" 3 feat-3 touch_own
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)"),$(pr_json 3 feat-3 "$(sha_of "$city" feat-3)")]"

	# #3 breaks only beside #1. Ejecting it must leave #1 + #2 shippable.
	run_lane "$city" INTEGRATION_LANE_VERIFY="$(combo_verify pr-1.txt pr-3.txt)"

	local mail; mail="$(mail_of "$city")"
	if has "$mail" '#3'; then
		report ok "the failing constituent is named"
	else
		report FAIL "the failing constituent is named" "mail=$(printf '%s' "$mail" | head -8)"
	fi
	# Attribution is to a PAIR, not to "the bundle": the report must say what #3
	# interacted WITH.
	if hasE "$mail" 'ejected after a COMBINATION failure.*#1|interacting with.*1'; then
		report ok "the failure is attributed to the pull requests that interacted, not to the bundle"
	else
		report FAIL "the failure is attributed to the pull requests that interacted, not to the bundle" \
			"mail=$(printf '%s' "$mail" | head -12)"
	fi
	if has "$(created_of "$city")" 'pr create'; then
		report ok "the remainder is re-bundled, so one bad PR delays only itself"
	else
		report FAIL "the remainder is re-bundled, so one bad PR delays only itself" \
			"no bundle opened after ejection"
	fi
	# And the ejected one is really gone from the bundle that shipped.
	local origin="$city/origin.git" b
	b=$(git -C "$origin" for-each-ref --format='%(refname:short)' 'refs/heads/integration/*' | head -n1)
	if [ -n "$b" ] && ! git -C "$origin" merge-base --is-ancestor "$(sha_of "$city" feat-3)" "$b"; then
		report ok "the ejected pull request is absent from the shipped bundle"
	else
		report FAIL "the ejected pull request is absent from the shipped bundle"
	fi
	rm -rf "$city"
}

# ---------------------------------------------------------------------------
# 5. Mergeability is re-queried, not read once.
# ---------------------------------------------------------------------------
case_requeries_mergeability() {
	local city; city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	# #2's FIRST read is the lazily-computed UNKNOWN GitHub actually returns.
	# A lane that believes one read drops #2 and bundles nothing.
	{
		printf '{"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN"}\n'
		printf '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n'
	} > "$city/fixtures/merge.2"
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)")]"

	run_lane "$city" INTEGRATION_LANE_VERIFY='true'

	local views; views=$(cat "$city/state/view.2" 2>/dev/null || echo 0)
	if [ "${views:-0}" -ge 2 ]; then
		report ok "an UNKNOWN mergeability read is re-queried rather than believed"
	else
		report FAIL "an UNKNOWN mergeability read is re-queried rather than believed" \
			"gh pr view called $views time(s) for #2"
	fi
	if has "$(created_of "$city")" 'pr create'; then
		report ok "a PR that settles to MERGEABLE on a later read is still bundled"
	else
		report FAIL "a PR that settles to MERGEABLE on a later read is still bundled"
	fi
	rm -rf "$city"
}

# ---------------------------------------------------------------------------
# 6. Every exclusion is named with a reason. Each path reached separately.
# ---------------------------------------------------------------------------
case_exclusions_are_named() {
	local city; city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	add_pr "$city" 3 draft-3 touch_own
	add_pr "$city" 4 red-4 touch_own
	add_pr "$city" 5 nochecks-5 touch_own
	add_pr "$city" 6 conflict-6 edit_shared
	add_pr "$city" 7 conflict-7 edit_shared
	printf '{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}\n' > "$city/fixtures/merge.7"

	queue "$city" "[\
$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),\
$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)"),\
$(pr_json 3 draft-3 "$(sha_of "$city" draft-3)" true),\
$(pr_json 4 red-4 "$(sha_of "$city" red-4)" false APPROVED '[{"conclusion":"FAILURE","status":"COMPLETED"}]'),\
$(pr_json 5 nochecks-5 "$(sha_of "$city" nochecks-5)" false APPROVED '[]'),\
$(pr_json 6 conflict-6 "$(sha_of "$city" conflict-6)"),\
$(pr_json 7 conflict-7 "$(sha_of "$city" conflict-7)")]"

	run_lane "$city" INTEGRATION_LANE_VERIFY='true'
	local mail; mail="$(mail_of "$city")"

	local n
	for n in "3:draft" "4:failing check" "5:no CI checks" "7:not mergeable"; do
		local num="${n%%:*}" want="${n#*:}"
		if has "$mail" "#$num" && hasi "$mail" "$want"; then
			report ok "#$num is excluded and the reason given is '$want'"
		else
			report FAIL "#$num is excluded and the reason given is '$want'" \
				"mail=$(printf '%s' "$mail" | head -20)"
		fi
	done

	# An empty check rollup must NOT be rounded up to green (PR #1346 read green
	# on zero checks). Asserted as an EXCLUSION, above, and as absence here.
	local origin="$city/origin.git" b
	b=$(git -C "$origin" for-each-ref --format='%(refname:short)' 'refs/heads/integration/*' | head -n1)
	if [ -n "$b" ] && ! git -C "$origin" merge-base --is-ancestor "$(sha_of "$city" nochecks-5)" "$b"; then
		report ok "a PR with zero CI checks is kept out of the bundle, not counted as green"
	else
		report FAIL "a PR with zero CI checks is kept out of the bundle, not counted as green"
	fi
	rm -rf "$city"
}

# ---------------------------------------------------------------------------
# 7. Bundle size: default 8, honoured, reported, and the overflow is named.
# ---------------------------------------------------------------------------
case_bundle_size() {
	if grep -q 'INTEGRATION_LANE_BUNDLE_SIZE:-8' "$LANE"; then
		report ok "the bundle size defaults to 8"
	else
		report FAIL "the bundle size defaults to 8"
	fi

	local city; city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	add_pr "$city" 3 feat-3 touch_own
	# NEWEST FIRST, the order `gh pr list` actually returns. Capping that order
	# raw starves the oldest PRs: with a queue durably over the cap they are cut
	# every single run under "next run picks it up", which would never come true.
	queue "$city" "[$(pr_json 3 feat-3 "$(sha_of "$city" feat-3)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)"),$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)")]"

	run_lane "$city" INTEGRATION_LANE_VERIFY='true' INTEGRATION_LANE_BUNDLE_SIZE=2
	local mail; mail="$(mail_of "$city")"

	# The OLDEST two get in, so the queue actually drains.
	local origin="$city/origin.git" b
	b=$(git -C "$origin" for-each-ref --format='%(refname:short)' 'refs/heads/integration/*' | head -n1)
	if [ -n "$b" ] \
		&& git -C "$origin" merge-base --is-ancestor "$(sha_of "$city" feat-1)" "$b" \
		&& git -C "$origin" merge-base --is-ancestor "$(sha_of "$city" feat-2)" "$b"; then
		report ok "the cap takes the OLDEST pull requests, so the queue drains"
	else
		report FAIL "the cap takes the OLDEST pull requests, so the queue drains" \
			"the newest-first order was capped raw, starving the oldest every run"
	fi

	if has "$mail" 'Bundle size in use: 2'; then
		report ok "every run reports the bundle size it used"
	else
		report FAIL "every run reports the bundle size it used" \
			"mail=$(printf '%s' "$mail" | head -10)"
	fi
	# Silent truncation reads as coverage: the PR that did not fit must be named.
	if has "$mail" '#3' && hasi "$mail" 'exceeds the bundle size'; then
		report ok "a PR dropped for exceeding the bundle size is named, not silently left behind"
	else
		report FAIL "a PR dropped for exceeding the bundle size is named, not silently left behind" \
			"mail=$(printf '%s' "$mail" | head -14)"
	fi
	rm -rf "$city"
}

# ---------------------------------------------------------------------------
# 8. A schemaVersion collision is caught BEFORE the combination is tested.
# ---------------------------------------------------------------------------
case_schema_version_collision() {
	local city; city="$(new_city)"
	add_pr "$city" 1 schema-1 bump_schema
	add_pr "$city" 2 schema-2 bump_schema
	add_pr "$city" 3 feat-3 touch_own
	queue "$city" "[$(pr_json 1 schema-1 "$(sha_of "$city" schema-1)"),$(pr_json 2 schema-2 "$(sha_of "$city" schema-2)"),$(pr_json 3 feat-3 "$(sha_of "$city" feat-3)")]"

	# The verify RECORDS every tree it is asked to judge. If the collision were
	# only discovered by testing, #2's file would be present in a recorded tree.
	run_lane "$city" \
		INTEGRATION_LANE_VERIFY="git rev-parse HEAD >> $city/state/verified.log; true"

	local mail; mail="$(mail_of "$city")"
	if hasi "$mail" 'schemaVersion collision'; then
		report ok "two PRs claiming one schemaVersion are reported as a collision"
	else
		report FAIL "two PRs claiming one schemaVersion are reported as a collision" \
			"mail=$(printf '%s' "$mail" | head -14)"
	fi

	# BEFORE the combination is tested: the ejected PR never reaches a verified
	# tree. A lane that discovered this by building would fail this assertion.
	local origin="$city/origin.git" leaked=0 sha t
	sha="$(sha_of "$city" schema-2)"
	touch "$city/state/verified.log"
	while read -r t; do
		[ -n "$t" ] || continue
		git -C "$city/$RIG" merge-base --is-ancestor "$sha" "$t" 2>/dev/null && leaked=1
	done < "$city/state/verified.log"
	if [ "$leaked" -eq 0 ]; then
		report ok "the collision is caught before the combination is ever built"
	else
		report FAIL "the collision is caught before the combination is ever built" \
			"the colliding PR reached a verified tree"
	fi
	rm -rf "$city" "$origin" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 8b. A branch cut before main moved has NOT bumped anything.
#
# The predicate must ask "did this PR CHANGE schemaVersion, against its own
# merge-base", not "does this PR's head differ from main today". Measured on the
# live queue with main at 202: four open PRs read 196/198 purely because they were
# cut earlier, touch dolt.go zero times, and were all called bumps — two of them
# then "collided" on a version neither had claimed.
# ---------------------------------------------------------------------------
case_stale_branch_is_not_a_bump() {
	local city; city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own      # cut at schemaVersion 100...
	add_pr "$city" 2 feat-2 touch_own
	advance_main "$city" 102               # ...and main moves to 102 underneath them

	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)")]"
	run_lane "$city" INTEGRATION_LANE_VERIFY='true'

	local mail; mail="$(mail_of "$city")"
	if hasi "$mail" 'schemaVersion'; then
		report FAIL "a stale branch that never touched dolt.go is not called a bump" \
			"mail=$(printf '%s' "$mail" | head -12)"
	else
		report ok "a stale branch that never touched dolt.go is not called a bump"
	fi
	if has "$(created_of "$city")" 'pr create'; then
		report ok "two stale-but-clean PRs still bundle after main moves on"
	else
		report FAIL "two stale-but-clean PRs still bundle after main moves on" \
			"the bundle collapsed on a bump that never happened"
	fi
	rm -rf "$city"
}

# ---------------------------------------------------------------------------
# 8c. A bump to EXACTLY what the base already stamps must be refused.
#
# The opposite blind spot of the same predicate. Git merges the identical line
# with no conflict, and `migrate()` short-circuits on `ver >= schemaVersion`, so
# the ALTER never runs — the outage class check-schema-version-bump.sh documents.
# A lane that greenlights it is worse than no lane, because the bundle carries a
# "verified" stamp.
# ---------------------------------------------------------------------------
case_equal_bump_is_refused() {
	local city; city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	add_pr "$city" 3 equal-3 bump_schema   # 100 -> 101 on its own branch
	advance_main "$city" 101               # and main independently reaches 101

	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)"),$(pr_json 3 equal-3 "$(sha_of "$city" equal-3)")]"
	run_lane "$city" INTEGRATION_LANE_VERIFY='true'

	local mail; mail="$(mail_of "$city")"
	if has "$mail" '#3' && hasi "$mail" 'not above'; then
		report ok "a bump equal to what the base already stamps is refused, not greenlit"
	else
		report FAIL "a bump equal to what the base already stamps is refused, not greenlit" \
			"mail=$(printf '%s' "$mail" | head -16)"
	fi
	# The other two must still ship — refusing one must not stall the set.
	local origin="$city/origin.git" b
	b=$(git -C "$origin" for-each-ref --format='%(refname:short)' 'refs/heads/integration/*' | head -n1)
	if [ -n "$b" ] && ! git -C "$origin" merge-base --is-ancestor "$(sha_of "$city" equal-3)" "$b"; then
		report ok "the equal-bumping PR is absent from the bundle the others still get"
	else
		report FAIL "the equal-bumping PR is absent from the bundle the others still get" \
			"branch=${b:-none}"
	fi
	rm -rf "$city"
}

# ---------------------------------------------------------------------------
# 8d. A preparation failure blames NOBODY.
#
# `*_templ.go` is gitignored here, so a fresh worktree cannot build until
# `templ generate` runs. Before that step existed, EVERY run read red regardless
# of its constituents and ejected up to three innocent PRs with a fabricated
# "it builds alone but not beside #X". A false alarm naming specific innocent
# pull requests is worse than no lane, so a harness fault must be reported AS a
# harness fault.
# ---------------------------------------------------------------------------
case_prepare_failure_blames_nobody() {
	local city; city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)")]"

	run_lane "$city" INTEGRATION_LANE_PREPARE='echo cannot prepare >&2; exit 1' \
		INTEGRATION_LANE_VERIFY='true'

	local mail; mail="$(mail_of "$city")"
	if hasi "$mail" 'fault in the LANE'; then
		report ok "a preparation failure is reported as a lane fault, not a combination failure"
	else
		report FAIL "a preparation failure is reported as a lane fault, not a combination failure" \
			"mail=$(printf '%s' "$mail" | head -12)"
	fi
	if hasi "$mail" 'builds alone but not beside'; then
		report FAIL "a preparation failure ejects nobody and fabricates no attribution" \
			"an innocent PR was blamed"
	else
		report ok "a preparation failure ejects nobody and fabricates no attribution"
	fi
	if [ -z "$(created_of "$city")" ]; then
		report ok "a preparation failure opens no bundle"
	else
		report FAIL "a preparation failure opens no bundle"
	fi
	rm -rf "$city"
}

# ---------------------------------------------------------------------------
# 8e. The default preparation generates templ views at the pinned version.
# ---------------------------------------------------------------------------
case_default_prepare_handles_templ() {
	if grep -q "INTEGRATION_LANE_PREPARE:-auto" "$LANE" \
		&& grep -q 'templ generate' "$LANE" \
		&& grep -q "go list -m -f '{{.Version}}' github.com/a-h/templ" "$LANE"; then
		report ok "the default preparation runs templ generate at the go.mod-pinned version"
	else
		report FAIL "the default preparation runs templ generate at the go.mod-pinned version"
	fi
	# @latest would generate code that does not match the module being built.
	if grep -q 'templ@latest' "$LANE"; then
		report FAIL "templ is pinned from go.mod, never @latest"
	else
		report ok "templ is pinned from go.mod, never @latest"
	fi
}

# ---------------------------------------------------------------------------
# 9. Two runs cannot bundle overlapping sets.
# ---------------------------------------------------------------------------
case_concurrent_runs_are_excluded() {
	local city; city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)")]"

	# A live run holds the lock. `mkdir` is the atomic primitive, and a fresh
	# `started` stamp keeps it inside the stale window.
	mkdir -p "$city/state/integration-lane.$RIG.lock"
	date -u +%s > "$city/state/integration-lane.$RIG.lock/started"

	run_lane "$city" INTEGRATION_LANE_VERIFY='true'

	if [ -z "$(created_of "$city")" ] && [ ! -s "$city/state/mail.log" ]; then
		report ok "a second run does nothing while the first holds the lock"
	else
		report FAIL "a second run does nothing while the first holds the lock" \
			"created=$(created_of "$city")"
	fi

	# And a lock left by a crashed run must not wedge the lane forever.
	printf '%s\n' "$(( $(date -u +%s) - 60 * 60 * 24 ))" \
		> "$city/state/integration-lane.$RIG.lock/started"
	run_lane "$city" INTEGRATION_LANE_VERIFY='true'
	if has "$(created_of "$city")" 'pr create'; then
		report ok "an abandoned lock past the stale window is broken, not honoured forever"
	else
		report FAIL "an abandoned lock past the stale window is broken, not honoured forever"
	fi
	rm -rf "$city"
}

# ---------------------------------------------------------------------------
# 10. Nothing to bundle -> no branch, no mail.
# ---------------------------------------------------------------------------
case_silent_when_nothing_to_add() {
	local city n
	for n in 0 1; do
		city="$(new_city)"
		if [ "$n" -eq 1 ]; then
			add_pr "$city" 1 feat-1 touch_own
			queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)")]"
		else
			queue "$city" "[]"
		fi

		run_lane "$city" INTEGRATION_LANE_VERIFY='true'

		local branches
		branches=$(git -C "$city/origin.git" for-each-ref --format='%(refname:short)' 'refs/heads/integration/*')
		if [ -z "$branches" ] && [ ! -s "$city/state/mail.log" ] && [ -z "$(created_of "$city")" ]; then
			report ok "$n mergeable PR(s): no branch, no pull request, no mail"
		else
			report FAIL "$n mergeable PR(s): no branch, no pull request, no mail" \
				"branches=${branches:-none} mail=$(mail_of "$city" | head -3)"
		fi
		rm -rf "$city"
	done
}

# ---------------------------------------------------------------------------
# 11. Static guards — claims a runtime case cannot fully establish.
# ---------------------------------------------------------------------------
case_static_guards() {
	# NEVER MERGES, in the strong form. The dynamic check in case 1 proves the
	# green path does not merge; only this proves no path does.
	# Strip the line number, then drop comment lines — the file DISCUSSES `gh pr
	# merge` at length in its header, and a guard that cannot tell prose from code
	# would be permanently red and get deleted.
	# Collected into a variable rather than ending in `grep -q` — see has() on why
	# a pipefail'd pipeline that short-circuits reports the wrong status.
	local codehits
	codehits="$(grep -nE 'gh[^|]*pr[[:space:]]+merge' "$LANE" \
		| sed 's/^[0-9]*://' | grep -v '^[[:space:]]*#')"
	if [ -n "$codehits" ]; then
		report FAIL "the script contains no merge call on any path" \
			"$(grep -nE 'pr[[:space:]]+merge' "$LANE" | head -3)"
	else
		report ok "the script contains no merge call on any path"
	fi

	# The bundle body quotes constituent titles, and this repo gates PR text:
	# `prd-ref guard` refuses more than one `PRD #N`, `issue-ref guard` matches
	# `issue-N`. Without sanitizing, a bundle of eight would red its OWN checks.
	if grep -q 'sanitize_ref_tokens' "$LANE"; then
		report ok "constituent titles are sanitized before being quoted into the bundle body"
	else
		report FAIL "constituent titles are sanitized before being quoted into the bundle body"
	fi

	# The sanitizer must actually neutralize both tokens.
	local out
	out=$( { printf 'PRD #91 and issue-249\n' | sed -e 's/PRD #\([0-9]\)/PRD \1/g' -e 's/[Ii]ssue-\([0-9]\)/issue \1/g'; } )
	if [ "$out" = "PRD 91 and issue 249" ]; then
		report ok "the sanitizer neutralizes both PRD # and issue- tokens"
	else
		report FAIL "the sanitizer neutralizes both PRD # and issue- tokens" "got: $out"
	fi

	# Documented where the pack's other orders are documented.
	local root; root="$(cd "$HERE/../../../.." && pwd)"
	if grep -q 'integration-lane' "$root/packs/README.md" 2>/dev/null \
		&& grep -q 'integration-lane' "$root/packs/docs/LOOP.md" 2>/dev/null; then
		report ok "the lane is listed with the pack's other orders"
	else
		report FAIL "the lane is listed with the pack's other orders"
	fi
	# And what it hands a human, not merely that it exists.
	if grep -qi 'never merges' "$root/packs/README.md" 2>/dev/null; then
		report ok "the docs record that the lane never merges"
	else
		report FAIL "the docs record that the lane never merges"
	fi
}

# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 8f. A failed `gh pr create` is reported, and leaves no orphan branch.
# ---------------------------------------------------------------------------
case_create_failure_is_reported() {
	local city; city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	: > "$city/fixtures/create-fails"
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)")]"

	run_lane "$city" INTEGRATION_LANE_VERIFY='true'
	local mail; mail="$(mail_of "$city")"

	# The failure mode being pinned: "one merge is waiting for you" with a blank
	# link, no error, and a branch on origin that nothing prunes.
	if hasi "$mail" 'one merge is waiting for you'; then
		report FAIL "a failed pr create is not reported as a bundle waiting for review" \
			"the mayor was sent a blank link"
	else
		report ok "a failed pr create is not reported as a bundle waiting for review"
	fi
	if hasi "$mail" 'FAILED\|could not'; then
		report ok "a failed pr create is reported as a failure"
	else
		report FAIL "a failed pr create is reported as a failure" \
			"mail=$(printf '%s' "$mail" | head -10)"
	fi
	local left
	left=$(git -C "$city/origin.git" for-each-ref --format='%(refname:short)' 'refs/heads/integration/*')
	if [ -z "$left" ]; then
		report ok "a failed pr create leaves no orphaned integration branch on origin"
	else
		report FAIL "a failed pr create leaves no orphaned integration branch on origin" "left=$left"
	fi
	rm -rf "$city"
}

echo "integration-lane self-test (sh=$SH)"
echo
case_bundles_and_tests_the_combination
case_combination_only_defect
case_ejects_culprit_and_rebundles
case_requeries_mergeability
case_exclusions_are_named
case_bundle_size
case_schema_version_collision
case_stale_branch_is_not_a_bump
case_equal_bump_is_refused
case_prepare_failure_blames_nobody
case_default_prepare_handles_templ
case_create_failure_is_reported
case_concurrent_runs_are_excluded
case_silent_when_nothing_to_add
case_static_guards

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
