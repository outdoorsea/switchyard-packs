#!/bin/sh
#
# resolve-fanout.sh — locate the switchyard-ops fan-out scripts from inside a
# `sy-build-from-prd` factory run, and hand off to them UNCHANGED.
#
# switchyard PRD #372, crit:6a3b156b1a02.
#
# WHY THIS EXISTS, AND WHY IT IS NOT A DECOMPOSER
#
# The `switchyard-ops` brakeman and this pack's per-item `implement` stage do
# the same job at the same granularity: build ONE criterion, in ONE worktree, on
# ONE branch, and leave ONE pull request. A criterion that is epic-sized is
# epic-sized in both lanes, so the fan-out decision — the threshold, the kill
# switch, the cap, the bead tree, the decision line — belongs to both. There is
# exactly one place that decision is implemented:
#
#     packs/switchyard-ops/assets/scripts/fanout-decompose.sh
#
# The obvious alternative — a formula-side decomposer of its own — is the thing
# this criterion forbids, and the reason is not tidiness. The decision line IS
# the operator's window into the mechanism (docs/epic-fanout.md §1), and two
# implementations means two report lines that drift, two threshold comparisons
# that disagree at the boundary, and a `SY_FANOUT_ENABLED=0` kill switch that
# stops one lane and not the other. An operator would have no way to tell which
# they were reading.
#
# So this file resolves and `exec`s. It never counts a plan item, never reads
# SY_FANOUT_THRESHOLD, never prints a `decision=`. Everything downstream of the
# resolution — argv, stdin, stdout, every knob, and the exit code — is the ops
# script's own.
#
# WHY RESOLUTION NEEDS A SCRIPT AT ALL
#
# The two packs are installed INDEPENDENTLY into a city. `switchyard-build` gets
# its own pack dir and cannot name `switchyard-ops`'s assets by a fixed relative
# path, and a prompt that told an LLM to "go find the decomposer" would be
# unpinnable, untestable, and would drift into a reimplementation the first time
# the search failed. A four-source ordered search, stated once here and asserted
# in `scripts/fanout-shared-decomposer.test.sh`, is what makes the sharing a
# property of the tree rather than a hope about a prompt.
#
# REFUSE, NEVER SUBSTITUTE. When no ops pack can be found this exits 3 with
# `source=none` and decides nothing. The caller's documented fallback is a plain
# serial build — which is exactly what `fanout-decompose.sh` itself folds back to
# when it cannot mint (docs/epic-fanout.md §1), so an unresolvable decomposer
# degrades the same way a broken one does: one worker, building serially, saying
# so. What it must never do is answer the question locally.
#
# THE REPORT GOES TO STDERR, and that is load-bearing. In exec mode this
# script's stdout IS the decomposer's stdout, and a caller greps it for the
# `fanout-decompose:` decision line. A resolution line printed there would be
# indistinguishable from the report it is wrapping.
#
# CONFIGURATION
#   SY_FANOUT_OPS_PACK_DIR  the installed `switchyard-ops` pack root. Set by the
#                           caller, like SY_FANOUT_RIG and SY_FANOUT_SLOT_DIR;
#                           it is a fact about pack layout, not a lane tunable,
#                           so it is not a roster.conf knob.
#   SY_FANOUT_REPO_ROOT     the rig checkout to search under, when the run is
#                           not inside one at the current directory.
#
# USAGE
#   resolve-fanout.sh --which <name>          print the resolved path
#   resolve-fanout.sh <name> [args...]        exec it with args
#
#   <name> is one of: decompose integrate lease child-run trace
#
# Exit 0 on a resolved `--which`; the delegate's own code in exec mode; 2 on a
# usage fault; 3 when nothing could be resolved.

set -u

RESOLVE_UNRESOLVED=3

usage() {
	cat >&2 <<'USAGE'
usage: resolve-fanout.sh --which <name>
       resolve-fanout.sh <name> [args...]
  <name>: decompose | integrate | lease | child-run | trace
USAGE
	exit 2
}

# A WHITELIST, not a filename. `--which` and the exec form both take their name
# from a prompt, and a name interpolated straight into a path lets
# `../../../anything` name any file in the city as "the decomposer". The set of
# fan-out scripts is closed and small, so it is spelled out.
script_for() {
	case "$1" in
	decompose | integrate | lease | child-run | trace)
		printf 'fanout-%s.sh\n' "$1"
		;;
	*) return 1 ;;
	esac
}

which_only=0
name=""

case "${1:-}" in
'') usage ;;
--which)
	[ $# -ge 2 ] || usage
	which_only=1
	name="$2"
	shift 2
	[ $# -eq 0 ] || usage
	;;
-h | --help) usage ;;
-*)
	printf 'resolve-fanout: unknown option %s\n' "$1" >&2
	usage
	;;
*)
	name="$1"
	shift
	;;
esac

file="$(script_for "$name")" || {
	printf 'resolve-fanout: %s is not a fan-out script\n' "$name" >&2
	usage
}

# ---------------------------------------------------------------------------
# The search, in precedence order. Each candidate is a directory that would
# hold the ops pack's scripts; the first that has THIS file wins.
#
# Order is deliberate. An explicitly configured pack dir outranks everything,
# because it is the only source an operator can state; a sibling install
# outranks the checkout, because a city running installed packs should run the
# version it installed rather than whatever happens to be checked out beside it;
# and PATH is last, because it is the only source that can be satisfied by an
# unrelated file with the right name.
# ---------------------------------------------------------------------------
here="$(cd "$(dirname "$0")" && pwd)"
pack_root="$(cd "$here/../.." && pwd)"

resolved=""
source_kind="none"

try_dir() {
	[ -n "$1" ] || return 1
	[ -f "$1/$file" ] || return 1
	resolved="$(cd "$1" && pwd)/$file"
	source_kind="$2"
	return 0
}

repo_root="${SY_FANOUT_REPO_ROOT:-}"
if [ -z "$repo_root" ]; then
	repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || repo_root=""
fi

try_dir "${SY_FANOUT_OPS_PACK_DIR:-}/assets/scripts" config ||
	try_dir "$pack_root/../switchyard-ops/assets/scripts" sibling ||
	try_dir "${repo_root:-/nonexistent}/packs/switchyard-ops/assets/scripts" repo ||
	{
		# PATH last, and only for the exact whitelisted filename.
		_p="$(command -v "$file" 2>/dev/null)" || _p=""
		if [ -n "$_p" ]; then
			resolved="$_p"
			source_kind="path"
		fi
	}

report() {
	printf 'resolve-fanout: script=%s resolved=%s source=%s\n' \
		"$name" "${resolved:--}" "$source_kind" >&2
}

if [ -z "$resolved" ]; then
	report
	printf 'resolve-fanout: no switchyard-ops pack found; set SY_FANOUT_OPS_PACK_DIR or SY_FANOUT_REPO_ROOT. Build this item SERIALLY — do not decide the fan-out here.\n' >&2
	exit "$RESOLVE_UNRESOLVED"
fi

report

if [ "$which_only" -eq 1 ]; then
	printf '%s\n' "$resolved"
	exit 0
fi

# Hand off. `exec` and not a subshell: the delegate inherits this process, so
# its stdin (a plan on `-`), its stdout (the decision line), its stderr and its
# exit code reach the caller untouched — there is no wrapper left to reinterpret
# any of them.
if [ -x "$resolved" ]; then
	exec "$resolved" "$@"
fi
# A checkout that lost the exec bit (a tarball install, a `zip` round-trip) must
# still run the ONE decomposer rather than fall through to no decomposer at all.
exec sh "$resolved" "$@"
