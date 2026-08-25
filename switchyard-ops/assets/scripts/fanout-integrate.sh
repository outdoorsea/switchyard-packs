#!/bin/sh
#
# fanout-integrate.sh — the parent's LOCAL INTEGRATION GATE: run a fan-out's
# children, account for every plan item, and prove the combination builds and
# passes before the criterion's single pull request exists.
#
# switchyard PRD #372, crit:c459203a6a63.
#
# WHAT THIS IS FOR
#
# A fan-out's children share one worktree on one branch, so there is no merge
# step: their work is already in one tree by construction. What is NOT
# guaranteed is that the tree they leave behind is whole, or that it builds.
# Two things can go wrong that nothing else in this pack would catch:
#
#   1. An item silently produces nothing. The child harness reports the
#      LAUNCHER'S EXIT CODE, not whether work happened, so a child that changed
#      zero files reports
#
#          fanout-child-run: child=… status=ok reason=ok … refusals=0
#
#      byte-for-byte identically to one that built the whole item. This has
#      been confirmed three separate times in this pack, from three different
#      causes — a brief that arrived empty, a child that asked for permission
#      instead of writing, and a child SIGTERM'd by its caller's timeout before
#      it printed any line at all. In every case the parent's only honest
#      signal was the tree, and in every case nobody looked until the pull
#      request came up short.
#
#   2. Two children edit one file and the combination is broken even though
#      each child succeeded. The decomposer slices by file ownership to avoid
#      this; slicing is a heuristic, and this gate is what catches what it
#      misses — while the damage is still local and free to fix.
#
# So this gate reads the TREE, not the report lines, and it runs the build and
# the criterion's own targeted tests over the combined result. Its exit code is
# the publish gate: zero means the criterion may be published, and nothing else
# does.
#
# THE GATE IS THE FAN-OUT'S BUILD STEP — AND IT RUNS THE ITEMS SERIALLY.
#
# This script is the fan-out's child RUNNER as well as its gate: the parent
# hands it a tree in which no plan item has been built yet, and it runs each
# item exactly once through the child harness, one child at a time. Serial
# execution is deliberate for now, not an accident of the loop: the per-item
# did-it-produce-anything check compares the tree before and after ONE child,
# which attributes production correctly only while nothing else touches the
# tree. Bounded parallelism is owned by this PRD's concurrency-cap criterion
# (crit:b88e92ac18fe) and lands there, not here.
#
# The corollary is a hard rule for the caller: do NOT build plan items before
# invoking the gate. A pre-built item re-briefs its child over finished work;
# the child changes nothing, the item folds back, and the run ends unfinished
# (exit 4, reason=unfinished-items) over a tree that is in fact complete. That
# refusal is fail-closed on purpose — this gate certifies only work it ran and
# can attribute, and a loud exit 4 on a mis-wired invocation beats silently
# crediting a tree it cannot account for.
#
# WHY THE TARGETED TESTS ARE THE CRITERION'S OWN COMMAND. switchyard judges a
# criterion by its verify_command, and a validator re-runs exactly that. A gate
# that chose its own suite would be green against a contract nobody is judged
# by, which is worse than no gate: it would certify the criterion under a
# command that never ran.
#
# WHY A FOLD-BACK IS RUN BY THE PARENT, UNCONFINED. The child confinement
# exists to stop a CHILD opening a second pull request or taking a cloud claim
# — both would cost the criterion its "one deliverable" invariant. The parent
# holds both legitimately; it is the session that will publish. So an item that
# folds back is retried by the parent's own runner, outside the confinement.
# Routing the retry back through the child harness would confine the one
# session that is supposed to be unconfined.
#
# WHY EVERY FAILURE PATH IS CLOSED. Each of these would otherwise report a
# green line over an incomplete criterion:
#
#   * no targeted tests configured  -> gate=fail (reason=no-verify)
#   * an item folded back with no serial runner configured -> unfinished
#   * a fold-back whose retry also produced nothing         -> unfinished
#   * an unreadable or empty plan   -> gate=fail (reason=no-plan)
#
# The last one matters more than it looks: zero items with a green build and
# green tests is a perfectly clean run of nothing, and it is indistinguishable
# from success in every field except this one.
#
# CONFIGURATION (roster.conf; a flag beats the environment)
#   SY_FANOUT_INTEGRATE_BUILD    build command line. Default `go build ./...`.
#   SY_FANOUT_INTEGRATE_VERIFY   the criterion's targeted tests. No default:
#                                unset is a failure, not a skip.
#   SY_FANOUT_INTEGRATE_SERIAL   the parent's serial-retry command line for a
#                                folded-back item. The item text is exported as
#                                SY_FANOUT_ITEM. Unset means a fold-back cannot
#                                be retried, and the item ends unfinished.
#   SY_FANOUT_INTEGRATE_PREPARE  how to make the tree buildable before the build
#                                judges it. `auto` (default) runs templ generate
#                                when the repo has .templ sources and nothing
#                                otherwise; `none` disables it; anything else is
#                                run as a command line in the worktree.
#   SY_FANOUT_INTEGRATE_LOG      optional path; the report line is appended.
#
# WHY THE GATE CARRIES A RIG. The child harness resolves its concurrency cap
# from the balancer's published target for a RIG, and it learns that rig only
# from its own --rig / SY_FANOUT_RIG. Since #1983 the gate is the only thing
# that invokes the harness, so a rig that stops here never reaches a child:
# every child would fall back to the configured cap while the decomposer — which
# does get --rig — reports the balancer's, and the two report lines of one
# fan-out disagree. So --rig is FORWARDED, not consumed. Absent, nothing is
# forwarded and the harness takes its own SY_FANOUT_RIG/config path unchanged.
#
# USAGE
#   fanout-integrate.sh --worktree <path> --branch <name> --plan <file>
#                       [--parent <bead>] [--crit <label>] [--prd <id>]
#                       [--rig <rig>]
#                       [--build <cmd>] [--verify <cmd>] [--serial-runner <cmd>]
#                       [--child-runner <path>] [--prepare auto|none|<cmd>]
#
# EXIT
#   0  gate passed: every item accounted for, build and targeted tests green.
#   1  the build or the targeted tests were red.
#   2  usage.
#   4  partial work: at least one plan item ended with nothing to show for it.

set -u

# roster.conf FIRST, exactly as every roster-tunable sibling does: this script
# runs inside a brakeman session whose environment carries none of these vars,
# so without sy_load_conf every SY_FANOUT_INTEGRATE_* knob documented in
# roster.conf.example is dead config on every real deployment — an operator's
# build command would be silently ignored and the default used instead.
. "$(dirname "$0")/../lib/roster.sh"
sy_load_conf

GATE_FAILED_EXIT=1
USAGE_EXIT=2
PARTIAL_EXIT=4

DEFAULT_BUILD="go build ./..."

usage() {
	cat >&2 <<'USAGE'
usage: fanout-integrate.sh --worktree <path> --branch <name> --plan <file>
                          [--parent <bead>] [--crit <label>] [--prd <id>]
                          [--rig <rig>]
                          [--build <cmd>] [--verify <cmd>] [--serial-runner <cmd>]
                          [--child-runner <path>] [--prepare auto|none|<cmd>]
USAGE
	exit 2
}

wt=""
branch=""
plan=""
parent=""
crit=""
prd=""
rig=""
build_cmd=""
verify_cmd=""
serial_cmd=""
child_runner=""
prepare_cmd=""

while [ $# -gt 0 ]; do
	case "$1" in
	--worktree)
		[ $# -ge 2 ] || usage
		wt="$2"
		shift 2
		;;
	--branch)
		[ $# -ge 2 ] || usage
		branch="$2"
		shift 2
		;;
	--plan)
		[ $# -ge 2 ] || usage
		plan="$2"
		shift 2
		;;
	--parent)
		[ $# -ge 2 ] || usage
		parent="$2"
		shift 2
		;;
	--crit)
		[ $# -ge 2 ] || usage
		crit="$2"
		shift 2
		;;
	--prd)
		[ $# -ge 2 ] || usage
		prd="$2"
		shift 2
		;;
	--rig)
		[ $# -ge 2 ] || usage
		rig="$2"
		shift 2
		;;
	--build)
		[ $# -ge 2 ] || usage
		build_cmd="$2"
		shift 2
		;;
	--verify)
		[ $# -ge 2 ] || usage
		verify_cmd="$2"
		shift 2
		;;
	--serial-runner)
		[ $# -ge 2 ] || usage
		serial_cmd="$2"
		shift 2
		;;
	--prepare)
		[ $# -ge 2 ] || usage
		prepare_cmd="$2"
		shift 2
		;;
	--child-runner)
		[ $# -ge 2 ] || usage
		child_runner="$2"
		shift 2
		;;
	-h | --help) usage ;;
	*)
		printf 'fanout-integrate: unknown argument %s\n' "$1" >&2
		usage
		;;
	esac
done

[ -n "$wt" ] || usage
[ -n "$branch" ] || usage

# A flag beats the environment, which beats the default. The verify command has
# no default on purpose: see the header.
[ -n "$build_cmd" ] || build_cmd="${SY_FANOUT_INTEGRATE_BUILD:-$DEFAULT_BUILD}"
[ -n "$verify_cmd" ] || verify_cmd="${SY_FANOUT_INTEGRATE_VERIFY:-}"
[ -n "$serial_cmd" ] || serial_cmd="${SY_FANOUT_INTEGRATE_SERIAL:-}"
[ -n "$child_runner" ] || child_runner="$(dirname "$0")/fanout-child-run.sh"
[ -n "$prepare_cmd" ] || prepare_cmd="${SY_FANOUT_INTEGRATE_PREPARE:-auto}"
# The flag beats the environment here too, and an absent rig stays absent: the
# harness must be free to report cap_source=config rather than claim a
# balancer-awareness nobody configured.
[ -n "$rig" ] || rig="${SY_FANOUT_RIG:-}"
[ -n "$parent" ] || parent="fanout"

work="$(mktemp -d "${TMPDIR:-/tmp}/fanout-integrate.XXXXXX")" || {
	printf 'fanout-integrate: cannot create a work directory\n' >&2
	exit "$USAGE_EXIT"
}
# Signals must EXIT after cleanup rather than resume: a caught INT falling
# through would find $work gone, read zero items, and report a clean-looking
# no-plan verdict — an interrupted run masquerading as a decision.
trap 'rm -rf "$work"' EXIT
trap 'rm -rf "$work"; trap - EXIT; exit 130' INT
trap 'rm -rf "$work"; trap - EXIT; exit 143' TERM

# ---------------------------------------------------------------------------
# Reporting. Assembled once, printed once, on every path out of this script —
# including the early ones, because a run that produced no line is a run whose
# reader cannot tell it from a run that never started.
# ---------------------------------------------------------------------------
gate="fail"
items=0
ok_n=0
folded=0
retried=0
unfinished=0
build_rc="skip"
verify_rc="skip"
reason=""

emit_and_exit() {
	printf 'fanout-integrate: gate=%s items=%s ok=%s folded=%s retried=%s unfinished=%s build=%s verify=%s reason=%s\n' \
		"$gate" "$items" "$ok_n" "$folded" "$retried" "$unfinished" \
		"$build_rc" "$verify_rc" "${reason:--}"

	if [ -n "${SY_FANOUT_INTEGRATE_LOG:-}" ]; then
		printf '%s\tgate=%s\titems=%s\tok=%s\tfolded=%s\tretried=%s\tunfinished=%s\tbuild=%s\tverify=%s\treason=%s\tcrit=%s\tprd=%s\n' \
			"$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)" \
			"$gate" "$items" "$ok_n" "$folded" "$retried" "$unfinished" \
			"$build_rc" "$verify_rc" "${reason:--}" "${crit:--}" "${prd:--}" \
			>>"$SY_FANOUT_INTEGRATE_LOG" 2>/dev/null || :
	fi
	exit "$1"
}

# ---------------------------------------------------------------------------
# The tree fingerprint — the whole basis of "did this item produce anything".
#
# It is deliberately two signals joined: the committed tip AND the working
# tree's dirty set. A child that committed advances the first; a child that
# edited without committing advances the second, and that still counts as work
# because the parent commits the tree before publishing. Folding such an item
# back would re-do work already sitting in front of us, and a second runner
# editing the same files is how a clean tree becomes a conflicted one.
# ---------------------------------------------------------------------------
fingerprint() {
	printf '%s\n' "$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo none)"
	git -C "$wt" status --porcelain 2>/dev/null || :
}

# ---------------------------------------------------------------------------
# The plan. One item per line, normalised as the decomposer normalises it, so
# the gate iterates the same items the decomposer counted: a plan whose bullets
# survived here but not there would silently shift every child's item by one.
#
# ONE DELIBERATE DIFFERENCE, and it is a bug fix rather than a divergence:
# comments are dropped from the RAW line, BEFORE the bullet marker is stripped.
# The decomposer de-bullets first and filters `^#` after, which deletes any item
# whose text begins with `#` once its bullet is gone — `- # of retries must be
# capped at three` normalises to `# of retries…` and vanishes. In the decomposer
# that costs a miscounted threshold. Here it would cost a DELIVERABLE: the item
# is never run, never counted, never named, and the run reports
# `gate=pass items=2 ok=2 unfinished=0` over a plan of three. That is precisely
# the false green this gate exists to prevent, so the order is fixed here even
# though it now differs by two lines from the sibling it was copied from.
# ---------------------------------------------------------------------------
items_file="$work/items"
if [ "$plan" = "-" ]; then
	cat
elif [ -n "$plan" ] && [ -r "$plan" ]; then
	cat "$plan"
else
	:
fi |
	grep -v '^[[:space:]]*#' |
	sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
		-e 's/^[-*+][[:space:]]\{1,\}//' \
		-e 's/^[0-9]\{1,3\}[.)][[:space:]]\{1,\}//' \
		-e 's/[[:space:]]*$//' |
	grep '.' >"$items_file" 2>/dev/null || :

items="$(wc -l <"$items_file" 2>/dev/null | tr -d ' ')"
[ -n "$items" ] || items=0

if [ "$items" -eq 0 ]; then
	# Not an empty success. A run with no items has built nothing, and a green
	# build over nothing is the most convincing false pass this gate can emit.
	reason="no-plan"
	printf 'fanout-integrate: no plan items to integrate — refusing to certify an empty run\n' >&2
	emit_and_exit "$PARTIAL_EXIT"
fi

if [ ! -d "$wt" ]; then
	reason="no-worktree"
	printf 'fanout-integrate: %s is not a directory\n' "$wt" >&2
	emit_and_exit "$PARTIAL_EXIT"
fi

# ---------------------------------------------------------------------------
# Run every item, and account for every item.
# ---------------------------------------------------------------------------
i=0
while IFS= read -r item; do
	[ -n "$item" ] || continue
	i=$((i + 1))

	item_file="$work/item.$i"
	printf '%s\n' "$item" >"$item_file"

	before="$(fingerprint)"

	"$child_runner" \
		--bead "$parent.$i" \
		--worktree "$wt" \
		--branch "$branch" \
		--item-file "$item_file" \
		${crit:+--crit "$crit"} \
		${prd:+--prd "$prd"} \
		${rig:+--rig "$rig"} \
		${parent:+--parent "$parent"} </dev/null
	child_rc=$?

	after="$(fingerprint)"

	produced=1
	[ "$before" = "$after" ] && produced=0

	if [ "$child_rc" -eq 0 ] && [ "$produced" -eq 1 ]; then
		ok_n=$((ok_n + 1))
		continue
	fi

	# Everything below here is the fold-back. A child that exited non-zero and
	# a child that exited zero over an untouched tree arrive at the same place
	# on purpose: from the deliverable's point of view they are one event —
	# this item has nothing to show for it.
	folded=$((folded + 1))
	if [ "$child_rc" -ne 0 ]; then
		printf 'fanout-integrate: item %s failed (child rc=%s) — folding back to serial retry\n' \
			"$i" "$child_rc" >&2
	else
		printf 'fanout-integrate: item %s reported success but left the tree untouched — folding back to serial retry\n' \
			"$i" >&2
	fi

	if [ -z "$serial_cmd" ]; then
		# Skipping it here is the one thing this gate must never do. An item
		# with no runner to retry it is an item nobody built.
		unfinished=$((unfinished + 1))
		printf 'fanout-integrate: no serial runner configured — item %s cannot be retried\n' "$i" >&2
		continue
	fi

	retry_before="$(fingerprint)"
	# The retry runs in the parent's worktree and, deliberately, NOT through the
	# child harness: no confinement is prepended to PATH and no credential is
	# withheld. This is the parent doing the item itself, which is the one
	# session entitled to the tokens the confinement exists to keep from
	# children.
	(
		cd "$wt" || exit 127
		SY_FANOUT_ITEM="$item"
		SY_FANOUT_ITEM_FILE="$item_file"
		SY_FANOUT_ITEM_INDEX="$i"
		SY_FANOUT_WORKTREE="$wt"
		SY_FANOUT_BRANCH="$branch"
		SY_FANOUT_CRIT="${crit:-}"
		SY_FANOUT_PRD="${prd:-}"
		export SY_FANOUT_ITEM SY_FANOUT_ITEM_FILE SY_FANOUT_ITEM_INDEX
		export SY_FANOUT_WORKTREE SY_FANOUT_BRANCH SY_FANOUT_CRIT SY_FANOUT_PRD
		sh -c "$serial_cmd" </dev/null
	)
	serial_rc=$?
	retry_after="$(fingerprint)"

	if [ "$serial_rc" -eq 0 ] && [ "$retry_before" != "$retry_after" ]; then
		retried=$((retried + 1))
		continue
	fi

	# The retry is held to the SAME standard as the child it replaced: an
	# exit-0 retry over an untouched tree is the identical defect one level up,
	# and trusting it here would reintroduce the whole problem in the recovery
	# path.
	unfinished=$((unfinished + 1))
	printf 'fanout-integrate: serial retry of item %s produced nothing (rc=%s)\n' \
		"$i" "$serial_rc" >&2
done <"$items_file"

# ---------------------------------------------------------------------------
# The gate proper: the build, then the criterion's own targeted tests, both
# over the COMBINED tree and both in the parent's worktree.
#
# They run even when an item is unfinished. A partial run's build output is
# what the parent needs in order to finish the item by hand, and suppressing it
# would make the most common recovery path the least informative one.
# ---------------------------------------------------------------------------
# Make the tree BUILDABLE before the build judges it. templ files generate Go,
# so a fan-out where one child edits a .templ and a sibling edits Go against the
# generated symbol compiles the STALE *_templ.go: the gate either certifies a
# combination that reds in CI, or fails with an undefined-symbol error charged
# to the wrong item. The pack's other combined-tree prover (integration-lane.sh)
# prepares for exactly this reason, and CLAUDE.md states the rule outright.
#
# `auto` is repo-agnostic: a tree with no templ sources needs nothing and must
# not be failed for it. A preparation failure is a fault in THIS harness rather
# than evidence about the work, so it is reported under its own reason instead
# of being charged to the build.
if [ "$prepare_cmd" != "none" ]; then
	if [ "$prepare_cmd" != "auto" ]; then
		(cd "$wt" && sh -c "$prepare_cmd" </dev/null)
		prepare_rc=$?
	elif [ -n "$(git -C "$wt" ls-files '*.templ' 2>/dev/null | head -n 1)" ]; then
		(
			cd "$wt" || exit 1
			tv="$(go list -m -f '{{.Version}}' github.com/a-h/templ 2>/dev/null)"
			[ -n "$tv" ] || {
				printf 'fanout-integrate: templ sources present but github.com/a-h/templ is not a module dependency\n' >&2
				exit 1
			}
			go install "github.com/a-h/templ/cmd/templ@$tv" >/dev/null 2>&1 || {
				printf 'fanout-integrate: could not install templ %s\n' "$tv" >&2
				exit 1
			}
			PATH="$(go env GOPATH)/bin:$PATH"
			export PATH
			templ generate
		)
		prepare_rc=$?
	else
		prepare_rc=0
	fi

	if [ "$prepare_rc" -ne 0 ]; then
		reason="prepare-failed"
		gate="fail"
		printf 'fanout-integrate: could not make the tree buildable — this is a fault in the\n' >&2
		printf '  gate, not a verdict on the work. Fix it, or set --prepare none.\n' >&2
		emit_and_exit "$GATE_FAILED_EXIT"
	fi
fi

(cd "$wt" && sh -c "$build_cmd" </dev/null)
build_rc=$?

if [ -n "$verify_cmd" ]; then
	(cd "$wt" && sh -c "$verify_cmd" </dev/null)
	verify_rc=$?
else
	verify_rc="skip"
fi

# ---------------------------------------------------------------------------
# The accounting invariant: every item ended up in exactly one bucket.
#
# `unfinished` alone is not enough, because it only counts items the loop
# REACHED and could not finish. An item the loop never saw at all — dropped by
# the plan normaliser, or skipped by a loop that abandoned early — leaves
# unfinished at zero and every other counter self-consistent, so the run exits
# green having built one thing fewer than the plan asked for. That is the same
# class of failure as a no-op child, one level up, and this is the check that
# catches it: the buckets must sum to the item count.
#
# It is stated as an accounting identity rather than a specific guard because
# the ways an item can go missing are open-ended, while the arithmetic that
# proves none did is not.
# ---------------------------------------------------------------------------
accounted=$((ok_n + folded))
if [ "$accounted" -ne "$items" ] || [ "$i" -ne "$items" ]; then
	reason="accounting-mismatch"
	gate="fail"
	printf 'fanout-integrate: %s of %s plan items were never accounted for — refusing to\n' \
		"$((items - accounted))" "$items" >&2
	printf '  certify a run that lost an item. Ran %s, ok %s, folded back %s, of %s planned.\n' \
		"$i" "$ok_n" "$folded" "$items" >&2
	emit_and_exit "$PARTIAL_EXIT"
fi

if [ "$unfinished" -gt 0 ]; then
	# Stated before the build/test verdicts because it OUTRANKS them: a green
	# build and green tests say nothing about an item that was never written,
	# and a reader who saw only those two would read this run as a pass.
	reason="unfinished-items"
	gate="fail"
	printf 'fanout-integrate: %s of %s items ended with nothing to show — not publishable\n' \
		"$unfinished" "$items" >&2
	emit_and_exit "$PARTIAL_EXIT"
fi

if [ "$verify_rc" = "skip" ]; then
	reason="no-verify"
	gate="fail"
	printf 'fanout-integrate: no targeted tests configured — refusing to certify the criterion\n' >&2
	printf '  against a command that never ran. Set SY_FANOUT_INTEGRATE_VERIFY or pass --verify.\n' >&2
	emit_and_exit "$GATE_FAILED_EXIT"
fi

if [ "$build_rc" -ne 0 ]; then
	reason="build-failed"
	gate="fail"
	emit_and_exit "$GATE_FAILED_EXIT"
fi

if [ "$verify_rc" -ne 0 ]; then
	reason="verify-failed"
	gate="fail"
	emit_and_exit "$GATE_FAILED_EXIT"
fi

gate="pass"
reason="integrated"
emit_and_exit 0
