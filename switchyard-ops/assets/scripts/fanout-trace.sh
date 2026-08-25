#!/bin/sh
#
# fanout-trace.sh — the fan-out's failure ledger, and the trace it leaves on the
# parent's cloud bead (switchyard PRD #372, crit:cc901595a33b).
#
#   "A child that dies or times out leaves its task trace on the parent bead's
#    event record, and the parent's handoff names every unfinished child, so no
#    fan-out ends silently partial."
#
# TWO SUBCOMMANDS, ONE LEDGER
# ---------------------------
#   record   append one child's fate, and — for a fate that is neither `started`
#            nor `ok` — post a task-trace event to the PARENT bead.
#   handoff  read the ledger and print the text naming every unfinished child,
#            for the parent to pass as handoff.broken_or_unverified.
#
# WHY A LOCAL LEDGER AND NOT JUST THE POST. The post can fail — no token, a
# swept lease, a box with no network — and a fan-out whose legibility depends on
# the network is exactly as partial as one with no legibility at all. Every fate
# is written locally FIRST and the handoff is built from the ledger, so the
# parent can still name what it lost with the cloud unreachable. The post is the
# durable copy; the ledger is the one that cannot fail.
#
# WHY `started` IS A RECORD. The worst child is the one that writes nothing: a
# SIGKILLed harness runs no trap and reports nothing at all, and a ledger of
# failures alone cannot tell that child from one that never ran. Recording a
# child as `started` before it is launched turns "unfinished" into the ABSENCE
# of a terminal record, which is a fact a dead process cannot suppress.
#
# WHY AN `ok` CHILD POSTS NOTHING. The parent's own heartbeat already carries
# liveness. A trace stream that also carried successes would bury the four lines
# a successor actually needs under the fan-out's whole history.
#
# THE LEASE RULE, INHERITED FROM fanout-lease.sh. A beat that omits
# lease_seconds is not refused by the server — it is accepted, and silently
# downgrades the parent's lease to the five-minute default. So a trace that
# cannot name a lease length is NOT posted; it is recorded and reported
# `post_reason=no-lease-seconds`. A missed trace is visible. A downgraded lease
# that hands the bead back mid-fan-out is not.
#
# Environment:
#   SY_FANOUT_LEDGER          default ledger path for both subcommands.
#   SY_FANOUT_LEASE_SECONDS   lease length to carry on the trace beat, when
#                             --lease-seconds is not passed.
#   SY_FANOUT_AGENT           claimed_by for the trace beat, when --agent is not
#                             passed.
#   SY_FANOUT_TRACE_CMD       replaces the built-in poster entirely. Receives
#                             --parent/--child/--status/--reason.
#   SWITCHYARD_TENANT, SWITCHYARD_PROJECT, SWITCHYARD_API_TOKEN,
#   SWITCHYARD_BASE_URL       resolve the built-in poster's endpoint. Absent any
#                             of them there is no poster, which is REPORTED
#                             (`post_reason=no-poster`) rather than skipped.
#
# Run:  fanout-trace.sh record  --parent <bead> --child <id> --status <s> [...]
#       fanout-trace.sh handoff --parent <bead> [--ledger <path>]

set -u

USAGE_EXIT=2

sub="${1:-}"
[ $# -gt 0 ] && shift

parent=""
child=""
status=""
reason=""
ledger="${SY_FANOUT_LEDGER:-}"
agent="${SY_FANOUT_AGENT:-}"
lease="${SY_FANOUT_LEASE_SECONDS:-}"

while [ $# -gt 0 ]; do
	case "$1" in
	--parent) parent="${2:-}"; shift 2 ;;
	--child) child="${2:-}"; shift 2 ;;
	--status) status="${2:-}"; shift 2 ;;
	--reason) reason="${2:-}"; shift 2 ;;
	--ledger) ledger="${2:-}"; shift 2 ;;
	--agent) agent="${2:-}"; shift 2 ;;
	--lease-seconds) lease="${2:-}"; shift 2 ;;
	--) shift; break ;;
	*) shift ;;
	esac
done

# ---------------------------------------------------------------------------
# sanitize — strip the three bytes that would corrupt a TSV ledger: tab (a
# phantom column, so a fragment of prose is read as a child id), newline and
# carriage return (a phantom ROW, so prose is read as a whole child). Applied to
# every field before it is written, not just to the ones a caller controls
# today: `reason` already carries a child's own stderr in some paths.
# ---------------------------------------------------------------------------
sanitize() {
	printf '%s' "${1:-}" | tr -d '\011\012\015'
}

# json_escape — backslash first, then quote. The other order double-escapes the
# backslash it just inserted.
json_escape() {
	printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

die_usage() {
	printf 'fanout-trace: %s\n' "$1" >&2
	printf 'usage: fanout-trace.sh record  --parent <bead> --child <id> --status <started|ok|failed|timeout|refused> [--reason <text>] [--ledger <path>]\n' >&2
	printf '       fanout-trace.sh handoff --parent <bead> [--ledger <path>]\n' >&2
	exit "$USAGE_EXIT"
}

case "$sub" in
record | handoff) ;;
*) die_usage "unknown subcommand ${sub:-<none>}" ;;
esac

[ -n "$parent" ] || die_usage "--parent is required"
[ -n "$ledger" ] || die_usage "--ledger is required (or set SY_FANOUT_LEDGER)"

# ===========================================================================
# record
# ===========================================================================
if [ "$sub" = record ]; then
	[ -n "$child" ] || die_usage "--child is required"
	[ -n "$status" ] || die_usage "--status is required"

	child="$(sanitize "$child")"
	status="$(sanitize "$status")"
	reason="$(sanitize "$reason")"
	[ -n "$reason" ] || reason="-"

	recorded=0
	posted=0
	post_reason="-"

	emit_and_exit() {
		printf 'fanout-trace: parent=%s child=%s status=%s reason=%s recorded=%s posted=%s post_reason=%s\n' \
			"$parent" "$child" "$status" "$reason" "$recorded" "$posted" \
			"$post_reason" >&2
		exit "${1:-0}"
	}

	_dir="$(dirname "$ledger")"
	[ -d "$_dir" ] || mkdir -p "$_dir" 2>/dev/null || :

	# ONE printf, appended. A single write of well under PIPE_BUF to an O_APPEND
	# descriptor is atomic, which is what lets concurrent children share one
	# ledger without a lock file — and a lock file is exactly what a killed
	# child would leave held.
	if printf '%s\t%s\t%s\t%s\n' "$(date -u +%s)" "$child" "$status" "$reason" \
		>>"$ledger" 2>/dev/null; then
		recorded=1
	else
		post_reason="ledger-unwritable"
		emit_and_exit 1
	fi

	# `started` is bookkeeping and `ok` is the happy path; neither is a trace.
	case "$status" in
	started | ok) emit_and_exit 0 ;;
	esac

	# -------------------------------------------------------------------
	# An override replaces the built-in poster entirely, so a city can send
	# the trace somewhere else without this script learning that transport.
	# -------------------------------------------------------------------
	if [ -n "${SY_FANOUT_TRACE_CMD:-}" ]; then
		if $SY_FANOUT_TRACE_CMD --parent "$parent" --child "$child" \
			--status "$status" --reason "$reason" >/dev/null 2>&1; then
			posted=1
			post_reason=hook
		else
			post_reason=hook-failed
		fi
		emit_and_exit 0
	fi

	_tenant="${SWITCHYARD_TENANT:-}"
	_project="${SWITCHYARD_PROJECT:-}"
	_token="${SWITCHYARD_API_TOKEN:-}"

	if [ -z "$_token" ] && [ -r "$(dirname "$0")/../lib/switchyard-api.sh" ]; then
		# Sourced only as a RESOLVER — the POST below lives here, not there.
		# shellcheck disable=SC1091
		. "$(dirname "$0")/../lib/switchyard-api.sh"
		_token="$(sy_api_token 2>/dev/null)" || _token=""
	fi

	if [ -z "$_tenant" ] || [ -z "$_project" ] || [ -z "$_token" ] ||
		! command -v curl >/dev/null 2>&1; then
		post_reason=no-poster
		emit_and_exit 0
	fi

	# See THE LEASE RULE above: no lease length, no beat.
	case "$lease" in
	'' | *[!0-9]*)
		post_reason=no-lease-seconds
		emit_and_exit 0
		;;
	esac

	[ -n "$agent" ] || {
		post_reason=no-agent
		emit_and_exit 0
	}

	_base="${SWITCHYARD_BASE_URL:-}"
	if [ -z "$_base" ]; then
		if command -v sy_api_base >/dev/null 2>&1; then
			_base="$(sy_api_base 2>/dev/null)" || _base=""
		fi
		[ -n "$_base" ] || _base="https://switchyard.work"
	fi
	_base="${_base%/}"

	_work="$(mktemp -d "${TMPDIR:-/tmp}/fanout-trace.XXXXXX")" || {
		post_reason=no-workdir
		emit_and_exit 0
	}
	trap 'rm -rf "$_work"' EXIT
	trap 'rm -rf "$_work"; exit 130' INT
	trap 'rm -rf "$_work"; exit 143' TERM

	_ec="$(json_escape "$child")"
	_es="$(json_escape "$status")"
	_er="$(json_escape "$reason")"

	printf '{"action":"heartbeat","claimed_by":"%s","lease_seconds":%s,"events":[{"kind":"blocked","payload":{"description":"fan-out child %s %s: %s","child":"%s","status":"%s","reason":"%s","source":"fanout-trace"}}]}' \
		"$(json_escape "$agent")" "$lease" \
		"$_ec" "$_es" "$_er" "$_ec" "$_es" "$_er" >"$_work/trace.json"

	# The bearer token goes in a --config file under umask 077, never in argv:
	# a token on the command line is readable by every process on the box.
	(umask 077 && printf 'header = "Authorization: Bearer %s"\n' "$_token" \
		>"$_work/curl.cfg")

	if curl -sS -f --max-time 20 --config "$_work/curl.cfg" \
		-H 'Content-Type: application/json' \
		--data @"$_work/trace.json" \
		"$_base/api/v1/projects/$_tenant/$_project/beads/$parent/action" \
		>/dev/null 2>&1; then
		posted=1
		post_reason=ok
	else
		post_reason=post-failed
	fi

	rm -f "$_work/curl.cfg" 2>/dev/null || :
	emit_and_exit 0
fi

# ===========================================================================
# handoff
# ===========================================================================
if [ ! -r "$ledger" ]; then
	# NOT an empty all-clear. A fan-out whose ledger is missing is the worst
	# case, not the clean one: nothing was recorded, so nothing can be
	# ruled out. Reporting "0 unfinished" here would be the silent partial
	# this whole criterion exists to forbid.
	printf 'fanout-trace: parent=%s unfinished=? ledger=%s status=no-ledger\n' \
		"$parent" "$ledger" >&2
	printf 'fanout-trace: no ledger at %s — the fate of this fan-out'"'"'s children is\n' \
		"$ledger" >&2
	printf '  UNKNOWN, not clean. Treat every child as unfinished.\n' >&2
	exit 1
fi

# A child is FINISHED only on an explicit terminal `ok`. Everything else —
# a non-ok terminal fate, or a `started` with no terminal record at all —
# is unfinished, which is what makes a hard-killed child visible.
unfinished="$(awk -F'\t' '
NF >= 3 {
	c = $2; s = $3; r = "-"
	if (NF >= 4 && $4 != "") r = $4
	if (!(c in seen)) { seen[c] = 1; order[++n] = c }
	if (s == "started") { next }
	term[c] = s
	tr[c] = r
}
END {
	for (i = 1; i <= n; i++) {
		c = order[i]
		if (c in term) {
			if (term[c] == "ok") continue
			printf "%s\t%s\t%s\n", c, term[c], tr[c]
		} else {
			printf "%s\tstarted\t%s\n", c, "no terminal record - killed before it could report"
		}
	}
}' "$ledger")"

if [ -z "$unfinished" ]; then
	printf 'fanout-trace: parent=%s unfinished=0 ledger=%s status=clean\n' \
		"$parent" "$ledger" >&2
	exit 0
fi

count="$(printf '%s\n' "$unfinished" | grep -c .)"

printf '%s fan-out %s did not finish — their work is absent or partial on this branch:\n' \
	"$count" "$([ "$count" = 1 ] && printf 'child' || printf 'children')"
printf '%s\n' "$unfinished" | while IFS="$(printf '\t')" read -r c s r; do
	[ -n "$c" ] || continue
	printf '  - %s (%s: %s)\n' "$c" "$s" "$r"
done

_names="$(printf '%s\n' "$unfinished" | awk -F'\t' '{ printf "%s%s", sep, $1; sep="," }')"
printf 'fanout-trace: parent=%s unfinished=%s ledger=%s children=%s\n' \
	"$parent" "$count" "$ledger" "$_names" >&2
exit 0
