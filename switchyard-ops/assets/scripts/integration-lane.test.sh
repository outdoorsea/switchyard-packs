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

# exclusion_reason <mail> <num> — the `excluded:` line exclude() wrote for ONE PR.
#
# Scoped deliberately. "The report does not blame #1" is meaningless asserted
# against the whole mail, because #1 legitimately appears in the constituents
# list of the bundle that shipped. The claim under test is about the reason
# given for a SINGLE exclusion, so the assertion must read that line and nothing
# else — otherwise it passes on unrelated text and proves nothing.
exclusion_reason() { # <mail> <num>
	awk -v n="$2" '$0 ~ ("^  #" n "  ") { getline; print; exit }' <<<"$1"
}

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
		    b=\$(cat "$city/fixtures/default-branch" 2>/dev/null || echo main)
		    printf '[{"name":"$RIG","default_branch":"%s"}]\n' "\$b" ;;
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
	#                A view of the BUNDLE's own pull request (matched by its
	#                /pull/ URL) answers from fixtures/bundle-checks instead, on
	#                the same successive-line rule — that is how a case makes the
	#                integration branch's CI report PENDING first and settle
	#                after, which is the whole thing the CI wait exists to do.
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
		    case "\$n" in
		      */pull/*)
		        n=bundle-checks ; f="$city/fixtures/bundle-checks"
		        # Observe the lane's own lock from inside the CI wait, then plant an
		        # ancient timestamp. A run that keeps its lock alive overwrites this
		        # before the next poll; one that does not leaves the 1 standing. See
		        # case_ci_wait_keeps_the_lock_alive.
		        cat "$city/state/integration-lane.$RIG.lock/started" \
		          >> "$city/state/lock-seen.log" 2>/dev/null
		        printf '1\n' > "$city/state/integration-lane.$RIG.lock/started" 2>/dev/null
		        ;;
		      *)        f="$city/fixtures/merge.\$n" ;;
		    esac
		    c=\$(cat "$city/state/view.\$n" 2>/dev/null || echo 0)
		    c=\$((c + 1))
		    printf '%s\n' "\$c" > "$city/state/view.\$n"
		    line=\$(sed -n "\${c}p" "\$f" 2>/dev/null)
		    [ -n "\$line" ] && printf '%s\n' "\$line" && exit 0
		    tail -n1 "\$f" 2>/dev/null
		    ;;
		  "repo view")
		    # The repository's merge-button configuration. A case may make the read
		    # FAIL, to prove the lane treats "cannot confirm" as "not allowed" rather
		    # than rounding it up. Defaults to BOTH allowed — today's real repository
		    # — so every other case is unaffected.
		    [ -f "$city/fixtures/repo-view-fails" ] && { echo "gh: repo view refused" >&2; exit 1; }
		    cat "$city/fixtures/repo.json" 2>/dev/null || printf '{"mergeCommitAllowed":true,"squashMergeAllowed":true}\n' ;;
		  "pr create")
		    printf '%s\n' "\$*" >> "$city/state/created.log"
		    # A case may make creation fail, to prove the lane does not fall
		    # through with a blank URL and an orphaned branch.
		    [ -f "$city/fixtures/create-fails" ] && { echo "gh: create refused" >&2; exit 1; }
		    printf 'https://github.com/acme/demo/pull/999\n' ;;
		  "pr merge")
		    printf '%s\n' "\$*" >> "$city/state/merged.log" ;;
		  "run view")
		    # The failing job's log. This is the EVIDENCE half of attributing a CI
		    # failure: the check's NAME says that something broke, its log says
		    # WHAT — and the file paths in it are what tie the failure back to the
		    # constituents that changed them.
		    cat "$city/fixtures/ci-log" 2>/dev/null ;;
		  *) : ;;
		esac
		exit 0
	EOF
	chmod +x "$city/bin/gh"

	# Default CI answer for the bundle's own pull request: a settled, passing
	# rollup. Same doctrine as add_pr's default MERGEABLE — the fixture's baseline
	# is the healthy world, and a case that is ABOUT the unhealthy one overwrites
	# it. Without a default every existing case would read as "the integration
	# branch has no CI", which is a refusal, and the suite would go red for a
	# reason none of those cases is about.
	printf '{"statusCheckRollup":[{"name":"build & test","status":"COMPLETED","conclusion":"SUCCESS"}]}\n' \
		> "$city/fixtures/bundle-checks"

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

# seed_wide <city> — a file with room for two FAR-APART edits, committed to main
# before any branch is cut.
#
# Every other fixture here has its constituents touch private files, so any two
# of them are related only by being in the same bundle. Real combination defects
# are not like that: #1484 and #1503 both added fields to the same
# `list_criteria` response rows, merged clean, and broke together. A suite whose
# constituents never share a file cannot tell an attribution that identifies the
# interacting pair from one that names the whole bundle.
seed_wide() {
	local repo="$1/$RIG" i
	git -C "$repo" checkout --quiet main
	for ((i = 1; i <= 40; i++)); do printf 'line %s\n' "$i"; done > "$repo/internal/db/wide.go"
	git -C "$repo" add -A
	git -C "$repo" commit --quiet -m "wide"
	git -C "$repo" push --quiet origin main
}
# Two edits 37 lines apart: git merges them without a conflict, which is the
# point — a conflict would be caught by the merge loop and never reach CI.
edit_wide_top() {
	awk 'NR==2 {print "edited near the top"; next} {print}' "$1/internal/db/wide.go" \
		> "$1/internal/db/wide.go.tmp" && mv "$1/internal/db/wide.go.tmp" "$1/internal/db/wide.go"
}
edit_wide_bottom() {
	awk 'NR==39 {print "edited near the bottom"; next} {print}' "$1/internal/db/wide.go" \
		> "$1/internal/db/wide.go.tmp" && mv "$1/internal/db/wide.go.tmp" "$1/internal/db/wide.go"
}

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

# merge_config <city> <mergeCommitAllowed> <squashMergeAllowed> — the repo's
# merge-button configuration, as `gh repo view` reports it.
merge_config() {
	printf '{"mergeCommitAllowed":%s,"squashMergeAllowed":%s}\n' "$2" "$3" > "$1/fixtures/repo.json"
}

# queue <city> <json> — the `gh pr list` answer.
queue() { printf '%s\n' "$2" > "$1/fixtures/prs.json"; }

# default_branch_is <city> <name> — what `gc rig list` reports for the rig.
# A name with no matching ref makes the scratch `worktree add` fail on a REAL
# git, which is how a lane fault is reproduced without shimming git itself.
default_branch_is() { printf '%s\n' "$2" > "$1/fixtures/default-branch"; }

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
		INTEGRATION_LANE_CI_POLL_SLEEP=0 \
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

# bundle_checks <city> <json...> — the answers `gh pr view <bundle PR>` gives,
# one per successive read, so a case can make CI report PENDING and then settle.
bundle_checks() {
	local city="$1"; shift
	: > "$city/fixtures/bundle-checks"
	local line
	for line in "$@"; do printf '%s\n' "$line" >> "$city/fixtures/bundle-checks"; done
}

# A settled rollup with one check of the given conclusion.
#
# `detailsUrl` is what a real GitHub Actions rollup entry carries, and it is the
# only handle on the run whose LOG says what actually broke — the check name
# alone is "build & test failed", which names no file and therefore implicates
# every constituent equally.
rollup()  { printf '{"statusCheckRollup":[{"name":"build & test","status":"COMPLETED","conclusion":"%s","detailsUrl":"https://github.com/acme/demo/actions/runs/4242/job/77"}]}' "$1"; }

# ci_log <city> <text...> — what `gh run view --log-failed` returns for the
# bundle's failing job.
ci_log() {
	local city="$1"; shift
	: > "$city/fixtures/ci-log"
	local line
	for line in "$@"; do printf '%s\n' "$line" >> "$city/fixtures/ci-log"; done
}
pending() { printf '{"statusCheckRollup":[{"name":"build & test","status":"IN_PROGRESS","conclusion":""}]}'; }
no_checks() { printf '{"statusCheckRollup":[]}'; }

# ---------------------------------------------------------------------------
# 2b. The INTEGRATION BRANCH'S OWN CI is the run's verdict — not the local
#     pre-flight, which is strictly weaker than the CI that judges the bundle.
#
# The local verify defaults to `go build && go vet`; ci.yml runs `go test ./...`
# and a Dolt-backed suite besides. So a combination defect that surfaces as a
# TEST failure — two PRs adding fields to the same response rows, the #1484 ×
# #1503 class this PRD cites — passes the local verify. If the lane reports the
# bundle green on that alone, a human is told "one merge is waiting for you"
# about a bundle whose CI is RED, which is the false green this criterion is
# about. The lane must read the branch's own CI result and fail the run on it.
# ---------------------------------------------------------------------------
case_bundle_ci_is_the_verdict() {
	local city; city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)")]"
	# The local pre-flight PASSES. Everything below is decided by CI alone.
	bundle_checks "$city" "$(rollup FAILURE)"
	run_lane "$city" INTEGRATION_LANE_VERIFY='true'
	local mail; mail="$(mail_of "$city")"

	if hasi "$mail" 'one merge is waiting for you'; then
		report FAIL "a red CI on the integration branch is not reported as a merge-ready bundle" \
			"the mayor was told to merge a bundle whose CI failed"
	else
		report ok "a red CI on the integration branch is not reported as a merge-ready bundle"
	fi
	if hasi "$mail" "the integration branch's ci\|combination.*failed ci\|ci.*failed"; then
		report ok "a red CI on the integration branch fails the run"
	else
		report FAIL "a red CI on the integration branch fails the run" \
			"mail=$(printf '%s' "$mail" | head -10)"
	fi
	# The PR stays open: it is the evidence a human reads. The lane reports, it
	# does not tidy away the thing that shows the failure.
	if has "$(created_of "$city")" 'pr create'; then
		report ok "the bundle pull request is still opened, so the failure is reviewable"
	else
		report FAIL "the bundle pull request is still opened, so the failure is reviewable" \
			"no PR was created, so nobody can read the failing checks"
	fi

	# THE OTHER DIRECTION. Same lane, same local verify, CI green — otherwise the
	# case above proves only that the lane can fail, not that CI decided it.
	local ok_city; ok_city="$(new_city)"
	add_pr "$ok_city" 1 feat-1 touch_own
	add_pr "$ok_city" 2 feat-2 touch_own
	queue "$ok_city" "[$(pr_json 1 feat-1 "$(sha_of "$ok_city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$ok_city" feat-2)")]"
	# PENDING first, then SUCCESS: proves the lane WAITS for a verdict instead of
	# reading once and calling an unfinished run whatever it happened to see.
	bundle_checks "$ok_city" "$(pending)" "$(rollup SUCCESS)"
	run_lane "$ok_city" INTEGRATION_LANE_VERIFY='true'
	if hasi "$(mail_of "$ok_city")" 'one merge is waiting for you'; then
		report ok "a green CI on the integration branch is still handed to a human to merge"
	else
		report FAIL "a green CI on the integration branch is still handed to a human to merge" \
			"mail=$(mail_of "$ok_city" | head -10)"
	fi

	# An EMPTY rollup is not success. PR #1346 read green on ZERO checks, which is
	# why the candidate filter already refuses this — the bundle's own CI is the
	# one place that mistake would be worst, since it is the measurement the whole
	# lane exists to produce.
	local none_city; none_city="$(new_city)"
	add_pr "$none_city" 1 feat-1 touch_own
	add_pr "$none_city" 2 feat-2 touch_own
	queue "$none_city" "[$(pr_json 1 feat-1 "$(sha_of "$none_city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$none_city" feat-2)")]"
	bundle_checks "$none_city" "$(no_checks)"
	run_lane "$none_city" INTEGRATION_LANE_VERIFY='true'
	if hasi "$(mail_of "$none_city")" 'one merge is waiting for you'; then
		report FAIL "an integration branch with NO checks is not rounded up to green" \
			"zero checks were reported as a verified combination"
	else
		report ok "an integration branch with NO checks is not rounded up to green"
	fi

	rm -rf "$city" "$ok_city" "$none_city"
}

# ---------------------------------------------------------------------------
# 2c. Waiting for CI does not make a live run look abandoned.
#
# The lock ages from a timestamp written when it was TAKEN, and a run past the
# stale window is broken open by the next one. Adding a CI wait pushed the worst
# case (four verifies at the 900s bound, then the CI budget) up against that
# window, so a run could be sitting on a legitimate wait while a rival decides it
# died and bundles the same PRs — the concurrent-bundle defect the lock exists to
# prevent. Staleness has to mean "no progress", not "taking a while".
# ---------------------------------------------------------------------------
case_ci_wait_keeps_the_lock_alive() {
	local city; city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)")]"
	# Three reads, so there is a poll AFTER the stub plants its ancient stamp.
	bundle_checks "$city" "$(pending)" "$(pending)" "$(rollup SUCCESS)"
	run_lane "$city" INTEGRATION_LANE_VERIFY='true'

	local seen; seen="$(tail -n1 "$city/state/lock-seen.log" 2>/dev/null)"
	# Count into a variable with an explicit 0 default: with the log absent the
	# `wc -l <` redirect fails, `[ "" -lt 2 ]` errors instead of failing, and the
	# regression this guard exists for would pass silently.
	local polls; polls="$(grep -c '' "$city/state/lock-seen.log" 2>/dev/null || true)"
	if [ "${polls:-0}" -lt 2 ]; then
		report FAIL "the CI wait refreshes the lane's lock" \
			"the lane polled CI fewer than twice, so this case proves nothing"
	elif [ "$seen" = 1 ]; then
		report FAIL "the CI wait refreshes the lane's lock" \
			"the lock still carried the ancient stamp on a later poll — a waiting run reads as abandoned"
	else
		report ok "the CI wait refreshes the lane's lock, so a waiting run is not read as abandoned"
	fi
	rm -rf "$city"
}

# ---------------------------------------------------------------------------
# 2d. A CI failure is attributed to the constituents that INTERACTED, not to
#     the bundle as a whole.
#
# The local pre-flight failure path already attributes: it ejects a suspect and
# names what that suspect broke beside (case 3+4 below). The CI path had no such
# thing. It reported the failing CHECK NAMES — "build & test" — and told the
# human to "let the next run rebuild without the culprit", which is the bundle
# as a whole wearing the blame and a person doing the bisect by hand.
#
# That gap matters more than it looks, because CI is the run's REAL measurement.
# The pre-flight is `go build && go vet`; ci.yml also runs the test suite. So the
# combination defects this PRD is actually about — #1484 × #1503, two pull
# requests adding fields to the same `list_criteria` response rows — are INVISIBLE
# to the pre-flight and surface only here. The one path that finds them was the
# one path that could not say who they were.
#
# There is no verify log to attribute from on this path, so attribution has to
# come from the failing job's own log: the files it names, matched against what
# each constituent changed.
# ---------------------------------------------------------------------------
case_ci_failure_is_attributed() {
	local city; city="$(new_city)"
	seed_wide "$city"
	add_pr "$city" 1 feat-1 edit_wide_top
	add_pr "$city" 2 feat-2 edit_wide_bottom
	add_pr "$city" 3 feat-3 touch_own          # the bystander
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)"),$(pr_json 3 feat-3 "$(sha_of "$city" feat-3)")]"

	# The local pre-flight PASSES. Everything here is decided by CI, exactly as
	# the real #1484 × #1503 pair would be.
	bundle_checks "$city" "$(rollup FAILURE)"
	ci_log "$city" \
		'--- FAIL: TestCriteriaRows (0.02s)' \
		'    internal/db/wide.go:39: duplicate field on the response row' \
		'FAIL	github.com/acme/demo/internal/db	0.4s'
	run_lane "$city" INTEGRATION_LANE_VERIFY='true'
	local mail; mail="$(mail_of "$city")"

	local attr; attr="$(grep -m1 'CI failure attributed to' <<<"$mail")"
	if [ -z "$attr" ]; then
		report FAIL "a CI failure names the constituents that interacted" \
			"nothing in the mail attributes the failure to anyone: $(printf '%s' "$mail" | head -14)"
	elif has "$attr" '#1' && has "$attr" '#2'; then
		report ok "a CI failure names the constituents that interacted"
	else
		report FAIL "a CI failure names the constituents that interacted" "attribution: $attr"
	fi

	# THE DISCRIMINATION, and the reason the bystander is in the fixture at all.
	# Naming every constituent satisfies "names the pair" while attributing the
	# defect to the bundle as a whole — the precise thing this criterion refuses.
	# #3 shares no file with the failure and none with the other two.
	if [ -n "$attr" ] && has "$attr" '#3'; then
		report FAIL "a constituent the failure does not touch is not implicated" \
			"#3 shares no file with the failure or with the pair, yet was named: $attr"
	else
		report ok "a constituent the failure does not touch is not implicated"
	fi

	# WHAT BROKE — the second half of the criterion. A check name is not a defect.
	if has "$mail" 'wide.go' && hasi "$mail" 'duplicate field'; then
		report ok "the report carries what broke, not only that CI was red"
	else
		report FAIL "the report carries what broke, not only that CI was red" \
			"mail=$(printf '%s' "$mail" | head -24)"
	fi

	# NO FABRICATION. A failing check whose log implicates nobody must say so.
	# This lane has a scar here: a missing `templ generate` once produced
	# confident "it builds alone but not beside #X" attributions against innocent
	# pull requests every single run. A named innocent is worse than no name, so
	# the honest answer has to be reachable and has to be said out loud.
	local blind; blind="$(new_city)"
	add_pr "$blind" 1 feat-1 touch_own
	add_pr "$blind" 2 feat-2 touch_own
	queue "$blind" "[$(pr_json 1 feat-1 "$(sha_of "$blind" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$blind" feat-2)")]"
	bundle_checks "$blind" "$(rollup FAILURE)"
	ci_log "$blind" 'Error: the runner ran out of disk space'
	run_lane "$blind" INTEGRATION_LANE_VERIFY='true'
	local bmail; bmail="$(mail_of "$blind")"
	if hasi "$bmail" 'could not attribute'; then
		report ok "a failure that implicates nobody says so rather than guessing"
	else
		report FAIL "a failure that implicates nobody says so rather than guessing" \
			"mail=$(printf '%s' "$bmail" | head -24)"
	fi
	if grep -qE '#[12].*(interact|attributed)' <<<"$bmail"; then
		report FAIL "an unattributable failure names no suspect" \
			"a pair was invented from a log that names no constituent's file"
	else
		report ok "an unattributable failure names no suspect"
	fi

	rm -rf "$city" "$blind"
}

# ---------------------------------------------------------------------------
# 2e. A CI failure EJECTS a constituent and re-bundles the remainder, so one bad
#     pull request delays itself rather than the whole set.
#
# Attribution (2d) names the pair; on its own it does not unblock anybody. When
# the bundle's CI came back red the run stopped there: the bundle sat red, and
# every constituent — including the ones the failure never touched — waited for a
# human to bisect by hand. That is one bad pull request delaying the whole set,
# at the layer this PRD calls the run's REAL measurement. The local pre-flight
# path has ejected and re-bundled since the lane shipped (case 3+4 below); this
# is the same guarantee on the path that actually finds the defects.
#
# EXACTLY ONE constituent is ejected, and that is the point rather than an
# optimisation. The implicated SET here is the interacting PAIR, and ejecting
# both would delay two pull requests to fix an interaction that breaking either
# half resolves. Ejecting the newest of them leaves the older one shipping.
#
# The fixture is the real #1484 × #1503 shape: two pull requests editing the same
# file far apart (git merges them clean, so the merge loop cannot catch it), plus
# a bystander that shares nothing. The bystander is what separates "re-bundled
# the remainder" from "gave up on the set".
# ---------------------------------------------------------------------------
case_ci_failure_ejects_and_rebundles() {
	local city; city="$(new_city)"
	seed_wide "$city"
	add_pr "$city" 1 feat-1 edit_wide_top
	add_pr "$city" 2 feat-2 edit_wide_bottom
	add_pr "$city" 3 feat-3 touch_own          # the bystander
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)"),$(pr_json 3 feat-3 "$(sha_of "$city" feat-3)")]"

	# Three successive reads of the bundle's checks: the first bundle's VERDICT,
	# the second read `ci_failure_log` makes to find the failing run, and then the
	# REPLACEMENT bundle's verdict. The replacement is green — which is the whole
	# claim, since the remainder was never what was broken.
	bundle_checks "$city" "$(rollup FAILURE)" "$(rollup FAILURE)" "$(rollup SUCCESS)"
	ci_log "$city" \
		'--- FAIL: TestCriteriaRows (0.02s)' \
		'    internal/db/wide.go:39: duplicate field on the response row' \
		'FAIL	github.com/acme/demo/internal/db	0.4s'
	# The local pre-flight passes throughout: everything here is decided by CI.
	run_lane "$city" INTEGRATION_LANE_VERIFY='true'
	local mail; mail="$(mail_of "$city")"
	local created; created="$(created_of "$city")"

	# 1. A SECOND bundle was opened. Without this the run merely reported.
	local n_created; n_created="$(grep -c 'pr create' <<<"$created")"
	if [ "${n_created:-0}" -ge 2 ]; then
		report ok "a CI-failed bundle is followed by a re-bundle of the remainder"
	else
		report FAIL "a CI-failed bundle is followed by a re-bundle of the remainder" \
			"only $n_created bundle(s) were opened; the remainder was left waiting on a human"
	fi

	# 2. The ejected constituent is named, with the CI failure as its reason.
	if has "$mail" '#2' && hasi "$mail" 'ejected'; then
		report ok "the ejected constituent is named with its reason"
	else
		report FAIL "the ejected constituent is named with its reason" \
			"mail=$(printf '%s' "$mail" | head -20)"
	fi

	# 3. THE SHIPPED BUNDLE. The other half of the pair and the bystander are both
	#    in it, and the ejected one is not — asserted on the real branch in the
	#    real origin, not on the prose of the mail.
	local origin="$city/origin.git" b found=""
	for b in $(git -C "$origin" for-each-ref --format='%(refname:short)' 'refs/heads/integration/*'); do
		if git -C "$origin" merge-base --is-ancestor "$(sha_of "$city" feat-1)" "$b" \
			&& git -C "$origin" merge-base --is-ancestor "$(sha_of "$city" feat-3)" "$b" \
			&& ! git -C "$origin" merge-base --is-ancestor "$(sha_of "$city" feat-2)" "$b"; then
			found="$b"
		fi
	done
	if [ -n "$found" ]; then
		report ok "the remainder ships without the ejected pull request"
	else
		report FAIL "the remainder ships without the ejected pull request" \
			"no integration branch carries #1 and #3 but not #2 (branches: $(git -C "$origin" for-each-ref --format='%(refname:short)' 'refs/heads/integration/*' | tr '\n' ' '))"
	fi

	# 4. The run ends by handing a human the bundle that IS mergeable.
	if hasi "$mail" 'one merge is waiting for you'; then
		report ok "the re-bundled remainder is handed to a human to merge"
	else
		report FAIL "the re-bundled remainder is handed to a human to merge" \
			"mail=$(printf '%s' "$mail" | head -20)"
	fi

	# 5. The superseded red bundle does not stay open competing for the same merge.
	#    Two open bundles containing overlapping constituents is an invitation to
	#    merge the red one, which would land the very pull request just ejected.
	if has "$(cat "$city/state/gh.log" 2>/dev/null)" 'pr close'; then
		report ok "the superseded red bundle is closed rather than left competing"
	else
		report FAIL "the superseded red bundle is closed rather than left competing" \
			"the red bundle is still open beside its replacement"
	fi

	# 6. The FIRST attribution survives into the report. The run's story is both
	#    failures; overwriting it with the latest would lose the pair that started
	#    it, which is the fact a human needs most.
	if has "$(grep -m1 'CI failure attributed to' <<<"$mail")" '#2'; then
		report ok "the attribution that caused the ejection is still reported"
	else
		report FAIL "the attribution that caused the ejection is still reported" \
			"mail=$(printf '%s' "$mail" | head -20)"
	fi

	# 7. NO FABRICATION, and this is the discrimination that makes the case mean
	#    something. A CI failure whose log implicates nobody must eject NOBODY —
	#    ejecting on no evidence is how the lane's old missing-`templ generate` bug
	#    threw innocent pull requests out of every bundle, and a re-bundle makes
	#    that worse by shipping the set minus an innocent.
	local blind; blind="$(new_city)"
	add_pr "$blind" 1 feat-1 touch_own
	add_pr "$blind" 2 feat-2 touch_own
	queue "$blind" "[$(pr_json 1 feat-1 "$(sha_of "$blind" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$blind" feat-2)")]"
	bundle_checks "$blind" "$(rollup FAILURE)" "$(rollup FAILURE)" "$(rollup SUCCESS)"
	ci_log "$blind" 'Error: the runner ran out of disk space'
	run_lane "$blind" INTEGRATION_LANE_VERIFY='true'
	local bcreated; bcreated="$(grep -c 'pr create' <<<"$(created_of "$blind")")"
	if [ "${bcreated:-0}" -le 1 ]; then
		report ok "an unattributable CI failure ejects nobody and does not re-bundle"
	else
		report FAIL "an unattributable CI failure ejects nobody and does not re-bundle" \
			"a constituent was ejected on a log that names none of them"
	fi
	# Matched on an ejection CLAIM, not on the word: the lane says "Nothing was
	# ejected: the failing job's log names no file any constituent changed", and
	# that sentence is the behaviour under test rather than a violation of it.
	# A bare `ejected` here would fail the lane for reporting honestly.
	if hasE "$(mail_of "$blind")" 'Ejected #|excluded: ejected after the bundle'; then
		report FAIL "an unattributable CI failure names no ejected suspect" \
			"mail=$(mail_of "$blind" | head -20)"
	else
		report ok "an unattributable CI failure names no ejected suspect"
	fi
	# And it says so out loud, rather than leaving a human to notice that a red
	# bundle simply stopped.
	if hasi "$(mail_of "$blind")" 'nothing was ejected'; then
		report ok "a CI failure with no attribution says why nobody was ejected"
	else
		report FAIL "a CI failure with no attribution says why nobody was ejected" \
			"mail=$(mail_of "$blind" | head -20)"
	fi

	rm -rf "$city" "$blind"
}

# ---------------------------------------------------------------------------
# 2f. Opting out of the CI wait must not claim the CI's verdict.
#
# INTEGRATION_LANE_CI_POLLS=0 is the documented opt-out: the run reports on the
# pre-flight alone and gives up the combination guarantee. The mail must SAY so.
# A green mail that still read "green on the integration branch's own CI" would
# be the false-green this layer exists to end, minted by configuration instead
# of by an empty rollup.
# ---------------------------------------------------------------------------
case_ci_polls_zero_says_preflight_only() {
	local city; city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)")]"
	run_lane "$city" INTEGRATION_LANE_VERIFY='true' INTEGRATION_LANE_CI_POLLS=0
	local mail; mail="$(mail_of "$city")"
	if hasi "$mail" 'one merge is waiting for you'; then
		report ok "POLLS=0: a clean bundle still ships and is handed to a human"
	else
		report FAIL "POLLS=0: a clean bundle still ships and is handed to a human" \
			"mail=$(printf '%s' "$mail" | head -10)"
	fi
	if hasi "$mail" "green on the integration branch's own CI"; then
		report FAIL "POLLS=0: the green mail claims no CI verdict it never read" \
			"the mail asserts the integration branch's own CI, but the wait was skipped by config"
	else
		report ok "POLLS=0: the green mail claims no CI verdict it never read"
	fi
	if hasi "$mail" 'pre-flight only'; then
		report ok "POLLS=0: the green mail states the pre-flight was the only check"
	else
		report FAIL "POLLS=0: the green mail states the pre-flight was the only check" \
			"mail=$(printf '%s' "$mail" | head -10)"
	fi
	rm -rf "$city"
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
# 7b. The DEFAULT size is the one a run with no configuration actually uses,
#     and a bundle SMALLER than it says so.
# ---------------------------------------------------------------------------
# case_bundle_size above pins the default by READING THE SOURCE, and every run
# it makes passes INTEGRATION_LANE_BUNDLE_SIZE=2 explicitly. So nothing observes
# the default in a run: a later assignment that overrode it — a helper exporting
# its own, a stray edit, a typo — would leave `:-8` in the source with the grep
# still green while every real run bundled some other number.
#
# The second assertion is the criterion's own worked example. A bundle of two
# under a size of eight has to be readable as a SHORT QUEUE rather than as a
# size somebody changed to two, and that is only true when the size and the
# count are BOTH on the report — so both are asserted against the one run.
case_bundle_size_default_is_what_a_run_uses() {
	local city; city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)")]"

	# Deliberately NO INTEGRATION_LANE_BUNDLE_SIZE: this run must fall back to
	# the configured default and report the number it really used.
	run_lane "$city" INTEGRATION_LANE_VERIFY='true'
	local mail; mail="$(mail_of "$city")"

	# The variable name is part of the pattern so the size cannot partial-match
	# a longer number: `: 8 (` cannot be read out of `: 80 (`.
	if has "$mail" 'Bundle size in use: 8 (INTEGRATION_LANE_BUNDLE_SIZE)'; then
		report ok "a run given no bundle size reports the default 8 it actually used"
	else
		report FAIL "a run given no bundle size reports the default 8 it actually used" \
			"mail=$(printf '%s' "$mail" | head -10)"
	fi

	if has "$mail" 'Bundle size in use: 8 (INTEGRATION_LANE_BUNDLE_SIZE)' \
		&& has "$mail" 'Constituents (2):'; then
		report ok "a bundle under the size reports both, so a short queue is not a changed setting"
	else
		report FAIL "a bundle under the size reports both, so a short queue is not a changed setting" \
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
# 9b. A run still BUNDLING keeps its lock alive.
# ---------------------------------------------------------------------------
# The CI wait refreshes the lock (9a), but the bundle loop is the LONGER half:
# prepare and verify are each bounded by INTEGRATION_LANE_VERIFY_TIMEOUT and the
# loop runs both once per ejection, so on stock defaults a legitimate run can
# outlive INTEGRATION_LANE_LOCK_STALE_MIN before it ever reaches CI. Ageing the
# lock from the moment it was TAKEN would declare that run abandoned mid-bundle,
# and the next cycle would bundle the same pull requests onto a second branch —
# two runs on overlapping sets, which is the whole thing the lock exists to stop.
case_bundle_loop_keeps_the_lock_alive() {
	local city; city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	add_pr "$city" 3 feat-3 touch_own
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)"),$(pr_json 3 feat-3 "$(sha_of "$city" feat-3)")]"

	local lock="$city/state/integration-lane.$RIG.lock"
	# Record the stamp the lane is holding, plant an ancient one, then fail so
	# the loop ejects and verifies again. A run that keeps its own lock warm
	# overwrites that ancient stamp before the second attempt reads it.
	run_lane "$city" \
		INTEGRATION_LANE_VERIFY="cat '$lock/started' >> '$city/state/bundle-lock.log' 2>/dev/null; printf '1\n' > '$lock/started' 2>/dev/null; exit 1"

	local attempts; attempts="$(grep -c '' "$city/state/bundle-lock.log" 2>/dev/null || true)"
	local second;   second="$(tail -n1 "$city/state/bundle-lock.log" 2>/dev/null)"
	if [ "${attempts:-0}" -lt 2 ]; then
		report FAIL "the bundle loop refreshes the lane's lock" \
			"the verify ran ${attempts:-0} time(s); this case needs a re-bundle to observe a refresh"
	elif [ "$second" = "1" ]; then
		report FAIL "the bundle loop refreshes the lane's lock" \
			"the lock still carried the ancient stamp on the re-bundle — a bundling run reads as abandoned"
	else
		report ok "the bundle loop refreshes the lane's lock, so a bundling run is not read as abandoned"
	fi
	rm -rf "$city"
}

# ---------------------------------------------------------------------------
# 9c. A run releases only a lock it still owns.
# ---------------------------------------------------------------------------
# Release used to be unconditional, so ONE mistaken break cascaded: the slow
# first run finished, deleted the SECOND run's live lock on its way out, and
# admitted a third. The pid is written when the lock is taken; reading it back
# on release is what stops the failure at one.
case_release_is_ownership_checked() {
	local city; city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)")]"

	local lock="$city/state/integration-lane.$RIG.lock"
	# A concurrent run breaks this lock and retakes it while we are mid-bundle:
	# from this point the directory belongs to pid 999999, not to us.
	run_lane "$city" \
		INTEGRATION_LANE_VERIFY="printf '999999\n' > '$lock/pid' 2>/dev/null; true"

	if [ -d "$lock" ]; then
		report ok "a finishing run does not release a lock it no longer owns"
	else
		report FAIL "a finishing run does not release a lock it no longer owns" \
			"it deleted the successor's live lock — one broken lock then admits a third run"
	fi
	rm -rf "$city"
}

# ---------------------------------------------------------------------------
# 9d. A lock taken microseconds ago is honoured, not broken on sight.
# ---------------------------------------------------------------------------
# The directory is the atomic claim and the stamp is written just after it, so
# there is a window in which a live lock carries no stamp at all. Reading "no
# stamp" as "stale" breaks a lock whose holder acquired it microseconds earlier
# — by construction, not by bad luck. Honour it and stamp it instead: it is then
# aged from first SIGHTING, so a run that really did die still ages out.
case_unstamped_lock_is_not_broken_on_sight() {
	local city; city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)")]"

	local lock="$city/state/integration-lane.$RIG.lock"
	mkdir -p "$lock"
	printf '999999\n' > "$lock/pid"

	run_lane "$city" INTEGRATION_LANE_VERIFY='true'
	if [ -n "$(created_of "$city")" ]; then
		report FAIL "a held lock with no stamp yet is honoured, not broken on sight" \
			"the second run bundled anyway — it broke a lock that had only just been taken"
	else
		report ok "a held lock with no stamp yet is honoured, not broken on sight"
	fi

	if [ -s "$lock/started" ]; then
		report ok "an unstamped lock is stamped on first sighting, so it can still age out"
	else
		report FAIL "an unstamped lock is stamped on first sighting, so it can still age out" \
			"nothing stamped it — a lock that cannot age is a lock that never releases"
	fi

	# ...and once it HAS aged past the window it is broken like any other.
	printf '%s\n' "$(( $(date -u +%s) - 60 * 60 * 24 ))" > "$lock/started"
	run_lane "$city" INTEGRATION_LANE_VERIFY='true'
	if has "$(created_of "$city")" 'pr create'; then
		report ok "an unstamped lock that has since aged past the window is broken"
	else
		report FAIL "an unstamped lock that has since aged past the window is broken" \
			"honouring it forever wedges the lane"
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

	# ANTI-VACUITY CONTROL. Every assertion above is an ABSENCE — no branch, no
	# mail, no pull request — and an absence proves nothing on its own. A lane
	# that never mailed at all, or a fixture whose mail.log was simply never
	# wired up, satisfies all of it. So the same fixture, the same helpers and
	# the same predicates must produce the OPPOSITE result when the lane does
	# have something to add. Without this the case is a green light bolted to a
	# disconnected wire.
	city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),\
$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)")]"
	run_lane "$city" INTEGRATION_LANE_VERIFY='true'
	if [ -s "$city/state/mail.log" ] && [ -n "$(created_of "$city")" ]; then
		report ok "control: two mergeable PRs DO branch and mail, so the silence above is a result"
	else
		report FAIL "control: two mergeable PRs DO branch and mail, so the silence above is a result" \
			"the fixture never mails or never creates, so every absence asserted above is vacuous"
	fi
	rm -rf "$city"
}

# ---------------------------------------------------------------------------
# 10b. Silence is for "nothing to ADD" — never for "nothing bundled".
#
# The lane decides whether to speak at TWO exits, and they disagreed. The late
# one, after a bundle attempt, is right: it goes quiet only when there is no
# bundle AND nothing was excluded. The early one — taken when fewer than two
# candidates survive the filters — went quiet unconditionally. So a run with
# one mergeable pull request and a queue full of rejected ones said nothing,
# and every rejection went with it.
#
# That is the silent-truncation failure this whole file is written against,
# and it is exactly what separates "the lane has nothing to add" from "the
# lane had plenty to say and swallowed it". The report for this case already
# exists in the lane — "nothing bundled, N PR(s) excluded", whose lead reads
# "fewer than two pull requests survived the filters". The early exit simply
# never reached it.
#
# Both arms below still assert the criterion's other half: no branch and no
# bundle pull request. Speaking up must not turn into bundling a single PR.
# ---------------------------------------------------------------------------
case_exclusions_break_the_silence() {
	local city n rows
	for n in 0 1; do
		city="$(new_city)"
		# Two pull requests that cannot be bundled, for two different reasons,
		# so a report that names only one is still a failure.
		add_pr "$city" 2 draft-2 touch_own
		add_pr "$city" 3 conflict-3 touch_own
		printf '{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}\n' > "$city/fixtures/merge.3"
		rows="$(pr_json 2 draft-2 "$(sha_of "$city" draft-2)" true),\
$(pr_json 3 conflict-3 "$(sha_of "$city" conflict-3)")"
		# n=0: nothing mergeable at all. n=1: exactly one, the boundary the
		# criterion names — one PR is no COMBINATION, so it must not be bundled.
		if [ "$n" -eq 1 ]; then
			add_pr "$city" 1 feat-1 touch_own
			rows="$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),$rows"
		fi
		queue "$city" "[$rows]"

		run_lane "$city" INTEGRATION_LANE_VERIFY='true'
		local mail; mail="$(mail_of "$city")"

		local branches
		branches=$(git -C "$city/origin.git" for-each-ref --format='%(refname:short)' 'refs/heads/integration/*')
		if [ -z "$branches" ] && [ -z "$(created_of "$city")" ]; then
			report ok "$n mergeable + 2 excluded: still no branch and no bundle pull request"
		else
			report FAIL "$n mergeable + 2 excluded: still no branch and no bundle pull request" \
				"branches=${branches:-none} created=$(created_of "$city")"
		fi

		local d c
		d="$(exclusion_reason "$mail" 2)"
		c="$(exclusion_reason "$mail" 3)"
		if hasi "$d" 'draft' && hasi "$c" 'not mergeable'; then
			report ok "$n mergeable + 2 excluded: the run still names every declined PR and why"
		else
			report FAIL "$n mergeable + 2 excluded: the run still names every declined PR and why" \
				"a run that bundles nothing still owes the queue an account; mail=$(printf '%s' "$mail" | head -20)"
		fi
		rm -rf "$city"
	done
}

# ---------------------------------------------------------------------------
# 11. A merge CONFLICT is attributed to the pair that collided, not the bundle.
#
# THE FIXTURE GAP THIS CLOSES. Every other case builds its PRs with `touch_own`,
# which edits disjoint files by construction, so the merge loop's conflict
# branch was never executed by any case in this file. The one case that uses
# `edit_shared` (case_exclusions_are_named) declares its PR CONFLICTING in the
# `gh` fixture, so requery_mergeable filters it out BEFORE the merge loop and it
# never reaches the conflict path either.
#
# The conflict that matters is the one the repo cannot see. Both PRs re-query
# as MERGEABLE because each merges clean against `main` ALONE; they collide only
# with each other. That is a combination-only defect in exactly the sense this
# lane exists to catch, and it is the most common one in a busy queue.
# ---------------------------------------------------------------------------
case_merge_conflict_names_the_counterpart() {
	local city; city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own       # innocent: only ever touches pr-1.txt
	add_pr "$city" 2 shared-2 edit_shared   # these two both ADD shared.txt with
	add_pr "$city" 3 shared-3 edit_shared   # different content -> add/add conflict
	queue "$city" "[\
$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),\
$(pr_json 2 shared-2 "$(sha_of "$city" shared-2)"),\
$(pr_json 3 shared-3 "$(sha_of "$city" shared-3)")]"

	# Every fixture answers MERGEABLE. add_pr's default is what makes this case
	# meaningful: the collision is invisible to the repo and appears only when
	# the lane puts them on one branch.
	run_lane "$city" INTEGRATION_LANE_VERIFY='true'

	local mail; mail="$(mail_of "$city")"
	local reason; reason="$(exclusion_reason "$mail" 3)"

	if [ -n "$reason" ]; then
		report ok "a constituent that conflicts inside the bundle is excluded and named"
	else
		report FAIL "a constituent that conflicts inside the bundle is excluded and named" \
			"mail=$(printf '%s' "$mail" | head -25)"
	fi

	# THE CRITERION. #3 collided with #2 over shared.txt. #1 was already merged
	# at that moment but touched nothing #3 touched, so naming "#2" is a pair and
	# naming "#1, #2" is the bundle-so-far wearing the blame collectively.
	if has "$reason" '#2'; then
		report ok "the conflict names the constituent it actually collided with"
	else
		report FAIL "the conflict names the constituent it actually collided with" \
			"reason=$reason"
	fi
	if has "$reason" '#1'; then
		report FAIL "the conflict does not blame a constituent that touched nothing it touched" \
			"reason=$reason"
	else
		report ok "the conflict does not blame a constituent that touched nothing it touched"
	fi

	# "and what broke" — the conflicted path, not merely the fact of a conflict.
	if has "$mail" 'shared.txt'; then
		report ok "the conflicting path is reported, so what broke is legible"
	else
		report FAIL "the conflicting path is reported, so what broke is legible" \
			"mail=$(printf '%s' "$mail" | head -25)"
	fi

	# The remainder still ships: a conflict delays its own PR, not the queue.
	if has "$(created_of "$city")" 'pr create'; then
		report ok "the constituents that did not conflict are still bundled"
	else
		report FAIL "the constituents that did not conflict are still bundled"
	fi
	rm -rf "$city"
}

# ---------------------------------------------------------------------------
# 11b. A conflict with the BASE is not a combination failure, and says so.
#
# The counterpart search can come back empty, and the report must not round that
# up to a pair. The reachable way to produce it: a stale MERGEABLE answer admits
# a PR that no longer merges against `main`, and it is the FIRST constituent, so
# nothing else is on the branch to have collided with it. Blaming the bundle
# there would be a FABRICATED combination defect — the exact failure the
# prepare-failure case guards on the verify side, on the conflict side.
# ---------------------------------------------------------------------------
case_conflict_with_base_implicates_nobody() {
	local city; city="$(new_city)"
	local repo="$city/$RIG"
	add_pr "$city" 1 shared-1 edit_shared
	add_pr "$city" 2 feat-2 touch_own

	# main moves under the open PR and lands its own shared.txt, so #1's branch
	# and `main` now both ADD that path from a merge-base that has neither.
	git -C "$repo" checkout --quiet main
	printf 'changed by main\n' > "$repo/shared.txt"
	git -C "$repo" add -A
	git -C "$repo" commit --quiet -m "main lands shared.txt"
	git -C "$repo" push --quiet origin main

	# The fixture still answers MERGEABLE for #1 — that staleness is the point.
	queue "$city" "[$(pr_json 1 shared-1 "$(sha_of "$city" shared-1)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)")]"
	run_lane "$city" INTEGRATION_LANE_VERIFY='true'

	local mail; mail="$(mail_of "$city")"
	local reason; reason="$(exclusion_reason "$mail" 1)"

	if has "$reason" 'shared.txt'; then
		report ok "a conflict against the base still reports the path that broke"
	else
		report FAIL "a conflict against the base still reports the path that broke" \
			"reason=$reason mail=$(printf '%s' "$mail" | head -20)"
	fi
	# THE CLAIM. Nothing had been merged yet, so no constituent can be implicated
	# and none may be named.
	if has "$reason" '#2'; then
		report FAIL "a conflict with the base implicates no other pull request" \
			"reason=$reason"
	else
		report ok "a conflict with the base implicates no other pull request"
	fi
	if hasi "$mail" 'not a combination failure'; then
		report ok "a conflict with the base is not reported as a combination failure"
	else
		report FAIL "a conflict with the base is not reported as a combination failure" \
			"mail=$(printf '%s' "$mail" | head -20)"
	fi
	rm -rf "$city"
}

# ---------------------------------------------------------------------------
# 12. The ejection ceiling must not swallow the evidence.
#
# The attribution/log write sits AFTER the ceiling test inside the loop, so when
# `ejections >= INTEGRATION_LANE_MAX_EJECTIONS` the loop breaks before anything
# is recorded. At the default ceiling of 3 that costs only the FINAL attempt's
# log — three earlier ones are already in notes. At 0 it costs every line, and
# the mail then asserts "each green alone and BROKEN TOGETHER" while showing
# neither a pair nor a single line of build output.
# ---------------------------------------------------------------------------
case_ceiling_break_reports_output() {
	local city; city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)")]"

	# A verify that SAYS something before it fails, so "was the output kept?" is
	# a question this fixture can actually answer. combo_verify alone is silent.
	#
	# THE MARKER IS SPLIT ON PURPOSE. The mail echoes the verify COMMAND back at
	# the reader ("Combination verify: ..."), so a plain marker matches that line
	# and the assertion passes even when the lane discarded every line of output
	# — which is exactly what it did when this case was first written. Splitting
	# the literal means the string exists only after `sh -c` evaluates it, so a
	# match can have come from nowhere but the captured output.
	run_lane "$city" \
		INTEGRATION_LANE_VERIFY="echo \"LANE_\"\"VERIFY_BROKE\"; $(combo_verify pr-1.txt pr-2.txt)" \
		INTEGRATION_LANE_MAX_EJECTIONS=0

	local mail; mail="$(mail_of "$city")"
	if has "$mail" 'LANE_VERIFY_BROKE'; then
		report ok "a run stopped by the ejection ceiling still reports what broke"
	else
		report FAIL "a run stopped by the ejection ceiling still reports what broke" \
			"mail=$(printf '%s' "$mail" | head -25)"
	fi
	# And it says WHY it could narrow no further, rather than presenting the
	# whole set as collectively guilty with no explanation.
	if hasi "$mail" 'ejection ceiling'; then
		report ok "the ceiling is named as the reason the failure was not narrowed"
	else
		report FAIL "the ceiling is named as the reason the failure was not narrowed" \
			"mail=$(printf '%s' "$mail" | head -25)"
	fi
	rm -rf "$city"
}

# ---------------------------------------------------------------------------
# 13. Static guards — claims a runtime case cannot fully establish.
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

# ---------------------------------------------------------------------------
# 12. The bundle must be mergeable AS A MERGE COMMIT, or it is a trap.
#
# Each constituent auto-closes because its own head commit becomes REACHABLE
# from the base when the bundle merges — which is why the lane merges every
# constituent with --no-ff. That reachability survives a merge commit and
# nothing else: a squash or a rebase rewrites those commits away, so the bundle
# would land and leave every constituent OPEN with its code already on main,
# each looking unmerged. That is the precise outcome this criterion forbids.
#
# So a repository whose merge-commit button is disabled cannot receive this
# bundle at all, and the body's "MERGE THIS WITH A MERGE COMMIT" is then an
# instruction nobody can follow. Asserted from BOTH sides: the impossible case
# refuses before pushing anything, and the possible case still ships.
# ---------------------------------------------------------------------------
case_merge_commit_is_required() {
	local city created mail left

	# (a) Merge commits DISABLED — refuse, and refuse before littering origin.
	city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	merge_config "$city" false true
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)")]"
	run_lane "$city" INTEGRATION_LANE_VERIFY='true'

	if [ -z "$(created_of "$city")" ]; then
		report ok "merge commits disabled: no bundle pull request is opened"
	else
		report FAIL "merge commits disabled: no bundle pull request is opened" \
			"created=$(created_of "$city" | head -2)"
	fi
	left=$(git -C "$city/origin.git" for-each-ref --format='%(refname:short)' 'refs/heads/integration/*')
	if [ -z "$left" ]; then
		report ok "merge commits disabled: nothing is pushed to origin"
	else
		report FAIL "merge commits disabled: nothing is pushed to origin" "left=$left"
	fi
	mail="$(mail_of "$city")"
	# NOT `hasi "$mail" "merge commit"`. The ordinary GREEN mail already says
	# "Merge it with a MERGE COMMIT, not a squash", so that assertion passes
	# without the refusal ever happening — it was green before this gate existed.
	# Assert the two things only a REFUSAL produces: no bundle is announced as
	# ready, and the blocked setting is named.
	if hasi "$mail" 'one merge is waiting for you'; then
		report FAIL "merge commits disabled: the run is not announced as a bundle ready to merge" \
			"mail=$(printf '%s' "$mail" | head -10)"
	else
		report ok "merge commits disabled: the run is not announced as a bundle ready to merge"
	fi
	if hasi "$mail" 'disabled'; then
		report ok "merge commits disabled: the mail names the merge-commit button as the blocker"
	else
		report FAIL "merge commits disabled: the mail names the merge-commit button as the blocker" \
			"mail=$(printf '%s' "$mail" | head -10)"
	fi
	rm -rf "$city"

	# (b) The setting cannot be READ. "Cannot confirm" is not "allowed" — the same
	# fail-closed choice the empty check rollup and the empty `gh pr list` make.
	city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	: > "$city/fixtures/repo-view-fails"
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)")]"
	run_lane "$city" INTEGRATION_LANE_VERIFY='true'
	left=$(git -C "$city/origin.git" for-each-ref --format='%(refname:short)' 'refs/heads/integration/*')
	if [ -z "$left" ]; then
		report ok "merge-commit setting unreadable: nothing is pushed to origin"
	else
		report FAIL "merge-commit setting unreadable: nothing is pushed to origin" "left=$left"
	fi
	if [ -z "$(created_of "$city")" ]; then
		report ok "merge-commit setting unreadable: no bundle pull request is opened"
	else
		report FAIL "merge-commit setting unreadable: no bundle pull request is opened" \
			"created=$(created_of "$city" | head -2)"
	fi
	mail="$(mail_of "$city")"
	if hasi "$mail" 'could not'; then
		report ok "merge-commit setting unreadable: the run says it could not confirm, rather than going quiet"
	else
		report FAIL "merge-commit setting unreadable: the run says it could not confirm, rather than going quiet" \
			"mail=$(printf '%s' "$mail" | head -10)"
	fi
	rm -rf "$city"

	# (c) Squash DISABLED — the bundle still ships, and the body must not offer a
	# button this repository does not have.
	city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	merge_config "$city" true false
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)")]"
	run_lane "$city" INTEGRATION_LANE_VERIFY='true'
	created="$(created_of "$city")"
	if [ -n "$created" ]; then
		report ok "merge commits allowed: the bundle pull request is opened"
	else
		report FAIL "merge commits allowed: the bundle pull request is opened" \
			"run.err=$(tail -3 "$city/state/run.err" 2>/dev/null)"
	fi
	if hasi "$created" 'allows squash merging'; then
		report FAIL "squash disabled: the body does not offer a squash button that is not there"
	else
		report ok "squash disabled: the body does not offer a squash button that is not there"
	fi
	if hasi "$created" 'Squash merging is disabled here'; then
		report ok "squash disabled: the body states that squash merging is disabled"
	else
		report FAIL "squash disabled: the body states that squash merging is disabled"
	fi
	rm -rf "$city"

	# (d) Both allowed — today's real repository. The squash warning must stay.
	city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	merge_config "$city" true true
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)")]"
	run_lane "$city" INTEGRATION_LANE_VERIFY='true'
	created="$(created_of "$city")"
	if hasi "$created" 'squash'; then
		report ok "squash allowed: the body warns that the wrong button is right there"
	else
		report FAIL "squash allowed: the body warns that the wrong button is right there"
	fi
	rm -rf "$city"
}

echo "integration-lane self-test (sh=$SH)"
echo
# ---------------------------------------------------------------------------
# A LANE FAULT still names the pull requests the run declined.
#
# The scratch-worktree exit was the last path that recorded exclusions and then
# threw them away: it appended a note, deleted $TMP with the ledger inside it,
# and continued with status 0. From outside, that run is indistinguishable from
# a clean one — the exact shape the criterion forbids, "never silently left
# behind while the run reports success".
#
# Failing `git worktree add` WITHOUT shimming git: point the rig's configured
# default branch at a ref that does not exist. The fetch finds nothing and
# `worktree add --detach ... origin/<name>` dies on `invalid reference`. That is
# a real git failure on the real repository the rest of this suite depends on,
# and it is a real-world fault too — a rig whose default branch was renamed.
# ---------------------------------------------------------------------------
case_lane_fault_names_what_it_declined() {
	local city mail branches
	city="$(new_city)"
	default_branch_is "$city" gone-branch
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	add_pr "$city" 3 feat-3 touch_own
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),\
$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)"),\
$(pr_json 3 feat-3 "$(sha_of "$city" feat-3)" true)]"

	run_lane "$city" INTEGRATION_LANE_VERIFY='true'
	mail="$(mail_of "$city")"

	# Read the reason off #3's OWN ledger line, not from the mail at large: a
	# bare `has "$mail" draft` passes on any sentence anywhere containing it.
	if hasi "$(exclusion_reason "$mail" 3)" 'draft'; then
		report ok "a lane fault still names the pull request it declined, and why"
	else
		report FAIL "a lane fault still names the pull request it declined, and why" \
			"reason for #3='$(exclusion_reason "$mail" 3)' mail=$(printf '%s' "$mail" | head -4)"
	fi

	if hasi "$mail" 'fault in the LANE'; then
		report ok "the lane fault reads as a lane fault, not as a verdict on the queue"
	else
		report FAIL "the lane fault reads as a lane fault, not as a verdict on the queue" \
			"mail=$(printf '%s' "$mail" | head -4)"
	fi

	# ANTI-VACUITY. Both assertions above would also be satisfied by a run that
	# failed somewhere EARLIER and happened to mail. Pin that the run really
	# reached — and stopped at — the worktree: nothing was bundled or pushed,
	# and the two PRs that passed every filter are accounted for rather than
	# dropped.
	branches=$(git -C "$city/origin.git" for-each-ref --format='%(refname:short)' 'refs/heads/integration/*')
	if [ -z "$branches" ] && [ -z "$(created_of "$city")" ]; then
		report ok "control: the lane-fault run opened no branch and no pull request"
	else
		report FAIL "control: the lane-fault run opened no branch and no pull request" \
			"branches=${branches:-none} created=$(created_of "$city")"
	fi
	if hasE "$mail" '#1[[:space:]]' && hasE "$mail" '#2[[:space:]]'; then
		report ok "control: the two PRs that passed the filters are named, not dropped"
	else
		report FAIL "control: the two PRs that passed the filters are named, not dropped" \
			"mail=$(printf '%s' "$mail" | head -12)"
	fi
	rm -rf "$city"
}

# ---------------------------------------------------------------------------
# A previous bundle's own pull request is NOTED, never put in the exclusion
# ledger.
#
# Both halves matter and they pull in opposite directions, which is why they are
# one case. The lane's own bundle stays open until a human merges it, so an
# entry in the EXCLUSION ledger would be non-empty on every run of that whole
# window — and the ledger is what the silent exits test. The mayor would get
# "nothing bundled, 1 PR(s) excluded", naming the lane's own output, every two
# hours until the merge. The notes ledger is carried into whatever mail the run
# was already sending and forces none of its own, which satisfies "name every
# pull request it did not include" without falsifying "a run with nothing to
# add is silent".
# ---------------------------------------------------------------------------
case_previous_bundle_is_noted_not_excluded() {
	local city mail

	# (a) A queue holding ONLY the lane's own open bundle is still a quiet
	#     queue. Nothing to add, so nothing is said.
	city="$(new_city)"
	add_pr "$city" 9 integration/prev-bundle touch_own
	queue "$city" "[$(pr_json 9 integration/prev-bundle "$(sha_of "$city" integration/prev-bundle)")]"
	run_lane "$city" INTEGRATION_LANE_VERIFY='true'
	if [ ! -s "$city/state/mail.log" ]; then
		report ok "a queue holding only the lane's own bundle stays silent"
	else
		report FAIL "a queue holding only the lane's own bundle stays silent" \
			"mail=$(mail_of "$city" | head -4)"
	fi
	rm -rf "$city"

	# (b) When the run DOES speak, that pull request is named — as an
	#     observation about its branch, and not as an exclusion.
	city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	add_pr "$city" 9 integration/prev-bundle touch_own
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),\
$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)"),\
$(pr_json 9 integration/prev-bundle "$(sha_of "$city" integration/prev-bundle)")]"
	run_lane "$city" INTEGRATION_LANE_VERIFY='true'
	mail="$(mail_of "$city")"

	if hasE "$mail" '#9[[:space:]]'; then
		report ok "a run that speaks names the previous bundle it skipped"
	else
		report FAIL "a run that speaks names the previous bundle it skipped" \
			"mail=$(printf '%s' "$mail" | head -12)"
	fi
	# exclusion_reason returns the line after `  #9  `; it is empty when #9 was
	# never written to the exclusion ledger, which is the claim under test.
	if [ -z "$(exclusion_reason "$mail" 9)" ]; then
		report ok "the previous bundle is not recorded as an exclusion"
	else
		report FAIL "the previous bundle is not recorded as an exclusion" \
			"#9 carries an exclusion reason: '$(exclusion_reason "$mail" 9)'"
	fi
	# ANTI-VACUITY: this same fixture, same helper, MUST find a reason for a PR
	# that genuinely was excluded — otherwise the emptiness above proves only
	# that exclusion_reason never matches anything here.
	rm -rf "$city"

	city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	add_pr "$city" 3 feat-3 touch_own
	add_pr "$city" 9 integration/prev-bundle touch_own
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),\
$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)"),\
$(pr_json 3 feat-3 "$(sha_of "$city" feat-3)" true),\
$(pr_json 9 integration/prev-bundle "$(sha_of "$city" integration/prev-bundle)")]"
	run_lane "$city" INTEGRATION_LANE_VERIFY='true'
	mail="$(mail_of "$city")"
	if hasi "$(exclusion_reason "$mail" 3)" 'draft' && [ -z "$(exclusion_reason "$mail" 9)" ]; then
		report ok "control: the same helper DOES find a reason for a genuinely excluded PR"
	else
		report FAIL "control: the same helper DOES find a reason for a genuinely excluded PR" \
			"#3='$(exclusion_reason "$mail" 3)' #9='$(exclusion_reason "$mail" 9)'"
	fi
	rm -rf "$city"
}

# ---------------------------------------------------------------------------
# A pull request that was never bundled is not called a constituent.
#
# `report_text` fills `constituents` from $TMP/candidates unconditionally, and
# `combine_and_verify` abandons at fewer than two inputs WITHOUT clearing that
# file. So every exit that reports without opening a bundle rendered the
# survivors under "Constituents (N)" — asserting membership of a bundle that
# does not exist. For this criterion that is the inverse of a silent drop and
# just as wrong: the run states a disposition for the pull request, and the
# disposition is false. Same list, honest heading.
# ---------------------------------------------------------------------------
case_unbundled_survivors_are_not_constituents() {
	local city mail
	city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),\
$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)" true)]"
	run_lane "$city" INTEGRATION_LANE_VERIFY='true'
	mail="$(mail_of "$city")"

	if has "$mail" 'Constituents ('; then
		report FAIL "a survivor of a run that bundled nothing is not called a constituent" \
			"mail=$(printf '%s' "$mail" | head -12)"
	else
		report ok "a survivor of a run that bundled nothing is not called a constituent"
	fi
	if hasE "$mail" '#1[[:space:]]' && hasi "$mail" 'not included'; then
		report ok "that survivor is still named, under a heading that says it was not included"
	else
		report FAIL "that survivor is still named, under a heading that says it was not included" \
			"mail=$(printf '%s' "$mail" | head -12)"
	fi
	rm -rf "$city"

	# ANTI-VACUITY. "Constituents (" being absent proves nothing unless this
	# fixture can produce it: a lane that never said it, or a mail.log never
	# wired up, satisfies the assertion above for free. A run that DOES bundle
	# must still use the word.
	city="$(new_city)"
	add_pr "$city" 1 feat-1 touch_own
	add_pr "$city" 2 feat-2 touch_own
	queue "$city" "[$(pr_json 1 feat-1 "$(sha_of "$city" feat-1)"),\
$(pr_json 2 feat-2 "$(sha_of "$city" feat-2)")]"
	run_lane "$city" INTEGRATION_LANE_VERIFY='true'
	if has "$(mail_of "$city")" 'Constituents ('; then
		report ok "control: a run that DOES bundle still calls them constituents"
	else
		report FAIL "control: a run that DOES bundle still calls them constituents" \
			"the heading never appears, so the absence asserted above is vacuous"
	fi
	rm -rf "$city"
}

# ---------------------------------------------------------------------------
# The two pre-queue exits are correct BY ORDER — and the order is now asserted.
#
# "gh returned nothing" and "merge commits are disabled" both leave with
# `rm -rf "$TMP"` and mail a bespoke body that does not carry the exclusion
# ledger. That is correct today for exactly one reason: both sit ABOVE the
# candidate loop, so nothing has been excluded yet and there is nothing to
# carry. Nothing in the file said so and no test held it, so a filter added
# later that recorded an exclusion before the queue read would silently re-arm
# the discard bug at both sites.
#
# This asserts the ORDER, not a spelling, and fails loudly if any anchor stops
# matching — so it cannot pass by quietly finding nothing.
# ---------------------------------------------------------------------------
case_pre_queue_exits_precede_the_ledger() {
	local loop_start first_exclude gh_exit merge_exit
	# Scoped to the rig loop deliberately. `exclude` is also called from
	# combine_and_verify, whose body is DEFINED hundreds of lines above the loop
	# and RUNS long after it — so comparing line numbers across the whole file
	# measures text order and mistakes it for execution order.
	loop_start=$(grep -n '^for rig in \$rigs; do' "$LANE" | head -1 | cut -d: -f1)
	if [ -z "$loop_start" ]; then
		report FAIL "both pre-queue exits sit above the first exclusion" \
			"the rig loop anchor stopped matching, so this assertion would prove nothing"
		return
	fi
	first_exclude=$(awk -v s="$loop_start" 'NR>s && /^[[:space:]]*exclude "/ {print NR; exit}' "$LANE")
	gh_exit=$(awk -v s="$loop_start" 'NR>s && /gh returned nothing for/ {print NR; exit}' "$LANE")
	merge_exit=$(awk -v s="$loop_start" 'NR>s && /is not bundling — merge commits/ {print NR; exit}' "$LANE")

	if [ -z "$first_exclude" ] || [ -z "$gh_exit" ] || [ -z "$merge_exit" ]; then
		report FAIL "both pre-queue exits sit above the first exclusion" \
			"an anchor stopped matching, so this assertion would prove nothing: first_exclude=${first_exclude:-none} gh_exit=${gh_exit:-none} merge_exit=${merge_exit:-none}"
		return
	fi
	if [ "$gh_exit" -lt "$first_exclude" ] && [ "$merge_exit" -lt "$first_exclude" ]; then
		report ok "both pre-queue exits sit above the first exclusion, so neither can drop a ledger"
	else
		report FAIL "both pre-queue exits sit above the first exclusion, so neither can drop a ledger" \
			"first exclude at $first_exclude, gh exit at $gh_exit, merge-commit exit at $merge_exit — an exit BELOW the first exclusion must carry the ledger into its report"
	fi
}


case_bundles_and_tests_the_combination
case_combination_only_defect
case_bundle_ci_is_the_verdict
case_ci_wait_keeps_the_lock_alive
case_ci_failure_is_attributed
case_ci_failure_ejects_and_rebundles
case_ci_polls_zero_says_preflight_only
case_ejects_culprit_and_rebundles
case_requeries_mergeability
case_exclusions_are_named
case_bundle_size
case_bundle_size_default_is_what_a_run_uses
case_schema_version_collision
case_stale_branch_is_not_a_bump
case_equal_bump_is_refused
case_prepare_failure_blames_nobody
case_default_prepare_handles_templ
case_create_failure_is_reported
case_concurrent_runs_are_excluded
case_bundle_loop_keeps_the_lock_alive
case_release_is_ownership_checked
case_unstamped_lock_is_not_broken_on_sight
case_silent_when_nothing_to_add
case_exclusions_break_the_silence
case_merge_commit_is_required
case_merge_conflict_names_the_counterpart
case_conflict_with_base_implicates_nobody
case_ceiling_break_reports_output
case_static_guards
case_lane_fault_names_what_it_declined
case_previous_bundle_is_noted_not_excluded
case_unbundled_survivors_are_not_constituents
case_pre_queue_exits_precede_the_ledger

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
