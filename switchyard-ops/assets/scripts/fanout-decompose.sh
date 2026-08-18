#!/bin/sh
#
# fanout-decompose.sh — judge a claimed criterion's build plan against the
# configured fan-out threshold, and past it, mint the local bead tree that a
# fan-out runs on: one parent epic bead, one child per plan item.
#
# switchyard PRD #372, crit:251bc1bcc12e.
#
# WHY THIS EXISTS
#
# The switchyard-ops pack dispatches at exactly one granularity — the cloud
# criterion bead — so an epic-sized criterion is built end to end by a single
# brakeman while Gas City's local bead layer sits idle. This script is the
# decomposition step BENEATH the cloud contract: the cloud pool keeps its
# meaning (criterion = deliverable = one PR = one verdict) and local beads
# become pure execution detail. Nothing here touches the claim protocol.
#
# THE REPORT IS THE PRODUCT, NOT A SIDE EFFECT
#
# Every run prints exactly one decision line, on BOTH branches:
#
#   fanout-decompose: decision=<fanout|serial> items=<n> threshold=<n> \
#     enabled=<0|1> serial_past_threshold=<0|1> reason=<slug> parent=<id|-> \
#     children=<n>
#
# A decomposer that fans out correctly and stays SILENT when it declines is,
# from the outside, indistinguishable from one that crashed: both leave a
# serial build and no beads. So a serial run states the values it judged, and
# a serial run whose plan EXCEEDED the threshold sets serial_past_threshold=1.
# That single field is the whole difference between "the plan was short" and
# "the decomposer is broken", and it is the ambiguity the criterion names.
#
# Two paths reach serial despite a long plan, and both must be loud:
#   - reason=disabled     the operator's kill switch (SY_FANOUT_ENABLED=0)
#   - reason=mint-failed  the bead tree could not be created
#
# FAIL-SAFE, NOT FAIL-FAST. A mint failure folds back to serial rather than
# dying. Dying here would strand a brakeman holding a live cloud claim with no
# path forward — the criterion still has to get built, and one worker building
# it serially is the correct degraded mode. A partial tree is reported (parent
# id plus the children that did land) so an operator can find and reap it.
#
# CONFIGURATION
#   SY_FANOUT_THRESHOLD   plan items above which fan-out happens. Default 4.
#                         Strictly EXCEEDS: a plan of exactly N stays serial.
#                         A non-numeric value falls back to the default rather
#                         than refusing to run — a typo in city config must not
#                         take the builder lane down.
#   SY_FANOUT_ENABLED     1 (default) or 0 to force serial everywhere.
#   SY_FANOUT_DECISION_LOG optional path; the decision line is appended to it.
#
# USAGE
#   fanout-decompose.sh --plan <file|-> [--rig <rig>] [--crit <label>]
#                       [--prd <id>] [--title <text>]
#
# Exit 0 once a decision is reported — on BOTH branches, because a serial
# decision is a successful outcome, not an error. Exit 2 on a usage fault only.

set -u

FANOUT_DEFAULT_THRESHOLD=4

usage() {
	cat >&2 <<'USAGE'
usage: fanout-decompose.sh --plan <file|-> [--rig <rig>] [--crit <label>]
                          [--prd <id>] [--title <text>]
USAGE
	exit 2
}

plan=""
rig=""
crit=""
prd=""
title=""

while [ $# -gt 0 ]; do
	case "$1" in
	--plan)
		[ $# -ge 2 ] || usage
		plan="$2"
		shift 2
		;;
	--rig)
		[ $# -ge 2 ] || usage
		rig="$2"
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
	--title)
		[ $# -ge 2 ] || usage
		title="$2"
		shift 2
		;;
	-h | --help) usage ;;
	*)
		printf 'fanout-decompose: unknown argument %s\n' "$1" >&2
		usage
		;;
	esac
done

# ---------------------------------------------------------------------------
# Configuration, sanitised. A garbage threshold behaves as the default: this
# script runs from an order on someone else's box, and refusing to decide
# because a knob is misspelled would take out the lane it exists to help.
#
# roster.conf is loaded FIRST, exactly as every roster-tunable sibling does
# (witness-sweep, token-report): this script runs inside a brakeman session
# whose environment carries no roster.conf vars, so without sy_load_conf the
# SY_FANOUT_* knobs documented in roster.conf.example would be dead config on
# every real deployment — the kill switch would print enabled=1 and keep
# fanning out.
# ---------------------------------------------------------------------------
. "$(dirname "$0")/../lib/roster.sh"
sy_load_conf

threshold="${SY_FANOUT_THRESHOLD:-$FANOUT_DEFAULT_THRESHOLD}"
case "$threshold" in
'' | *[!0-9]*) threshold="$FANOUT_DEFAULT_THRESHOLD" ;;
esac

enabled="${SY_FANOUT_ENABLED:-1}"
case "$enabled" in
1) enabled=1 ;;
*) enabled=0 ;;
esac

work="$(mktemp -d "${TMPDIR:-/tmp}/fanout-decompose.XXXXXX")" || {
	printf 'fanout-decompose: cannot create a work directory\n' >&2
	exit 2
}
# Signals must EXIT after cleanup, not resume the script: a caught INT that
# fell through would find $work gone, count zero items, and report a
# clean-looking `decision=serial reason=no-plan` — an interrupted run
# masquerading as a decision, the exact ambiguity the report exists to kill.
trap 'rm -rf "$work"' EXIT
trap 'rm -rf "$work"; trap - EXIT; exit 130' INT
trap 'rm -rf "$work"; trap - EXIT; exit 143' TERM

# ---------------------------------------------------------------------------
# The plan. One item per line; blank lines and # comments are not items — a
# plan file that counted its own header would cross the threshold on
# formatting alone. A missing or unreadable plan counts zero and stays serial.
# ---------------------------------------------------------------------------
items_file="$work/items"
if [ "$plan" = "-" ]; then
	cat
elif [ -n "$plan" ] && [ -r "$plan" ]; then
	cat "$plan"
else
	:
fi |
	sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
		-e 's/^[-*+][[:space:]]\{1,\}//' \
		-e 's/^[0-9]\{1,3\}[.)][[:space:]]\{1,\}//' \
		-e 's/[[:space:]]*$//' |
	grep -v '^#' |
	grep '.' >"$items_file" 2>/dev/null || :
# The bullet strip above is load-bearing, not cosmetic: a markdown-bulleted
# plan ("- refactor the parser") is the most natural shape for an LLM-written
# plan, and an item that still began with `-` would be parsed by `gc bd
# create` as a flag (the `--` guard in bd_create is the second layer).

items="$(wc -l <"$items_file" 2>/dev/null | tr -d ' ')"
[ -n "$items" ] || items=0

# ---------------------------------------------------------------------------
# Reporting. Assembled once, printed once, on every path out of this script.
# ---------------------------------------------------------------------------
decision="serial"
reason=""
parent="-"
children=0
spt=0

emit_and_exit() {
	printf 'fanout-decompose: decision=%s items=%s threshold=%s enabled=%s serial_past_threshold=%s reason=%s parent=%s children=%s\n' \
		"$decision" "$items" "$threshold" "$enabled" "$spt" "$reason" "$parent" "$children"

	if [ -n "${SY_FANOUT_DECISION_LOG:-}" ]; then
		printf '%s\tdecision=%s\titems=%s\tthreshold=%s\tenabled=%s\tserial_past_threshold=%s\treason=%s\tparent=%s\tchildren=%s\tcrit=%s\n' \
			"$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)" \
			"$decision" "$items" "$threshold" "$enabled" "$spt" "$reason" \
			"$parent" "$children" "${crit:--}" \
			>>"$SY_FANOUT_DECISION_LOG" 2>/dev/null || :
	fi
	exit 0
}

# ---------------------------------------------------------------------------
# Minting. Kept behind one function so the four flag permutations do not leak
# into the decision logic, and so an unquoted ${rig:+--rig $rig} — which would
# word-split a rig name — never appears.
# ---------------------------------------------------------------------------
meta=""
if [ -n "$crit" ] || [ -n "$prd" ]; then
	if command -v jq >/dev/null 2>&1; then
		meta="$(jq -nc --arg c "$crit" --arg p "$prd" \
			'{sy_fanout_crit: $c, sy_fanout_prd: $p}' 2>/dev/null)" || meta=""
	else
		# No jq: interpolation is safe only while neither value can close the
		# JSON string. A quote or backslash in either would make every mint
		# fail (reason=mint-failed), silently degrading to serial — so drop
		# the metadata instead, which only costs the reaper its tag.
		case "$crit$prd" in
		*[\"\\]*)
			printf 'fanout-decompose: crit/prd carry JSON-unsafe characters; minting without metadata\n' >&2
			;;
		*)
			meta="{\"sy_fanout_crit\":\"${crit}\",\"sy_fanout_prd\":\"${prd}\"}"
			;;
		esac
	fi
fi

json_id() {
	if command -v jq >/dev/null 2>&1; then
		jq -r '.id // empty' 2>/dev/null
	else
		sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
	fi
}

# bd_create TITLE [PARENT_ID] — echo the new bead's id, non-zero on failure.
#
# Flags are accumulated with `set --` rather than spelled out per permutation:
# an optional flag written as ${rig:+--rig $rig} word-splits a rig name, and
# passing `--metadata ""` on a run with no criterion hands `gc` a malformed
# JSON argument instead of omitting the flag.
#
# STDIN IS /dev/null, AND THAT IS LOAD-BEARING. Child mints run inside a
# `while read` loop fed by the plan file. A mint that inherited that stdin and
# read any of it would consume the remaining plan items, so a 7-item plan would
# mint one child and report a successful fan-out — the loop cannot tell the
# difference between "the plan ended" and "a child process drank it".
bd_create() {
	_bc_title="$1"
	_bc_parent="${2:-}"
	set --
	[ -n "$rig" ] && set -- "$@" --rig "$rig"
	[ -n "$_bc_parent" ] && set -- "$@" --parent "$_bc_parent"
	[ -n "$meta" ] && set -- "$@" --metadata "$meta"
	# `--` ends flag parsing: a plan item that still begins with a dash after
	# the bullet strip ("-v flag support") must become the title, not a gc
	# flag — an unguarded dash item would fail the mint at best, and at worst
	# ("--rig other") silently mint the bead into another rig.
	gc bd create "$@" --json -- "$_bc_title" </dev/null 2>"$work/mint.err"
}

# mint_cause — the first line the failing call complained with, trimmed. Empty
# when it said nothing. reason=mint-failed reports THAT the decomposer broke;
# this reports WHY, which is the difference between a bug and an expired token.
mint_cause() {
	head -n1 "$work/mint.err" 2>/dev/null | cut -c1-200
}

# ---------------------------------------------------------------------------
# The decision. Order is deliberate: an empty plan is benign whatever the
# knobs say, so it is judged before the kill switch — otherwise a city running
# with fan-out disabled would report every no-op run as "disabled" and bury the
# one signal an operator actually needs.
# ---------------------------------------------------------------------------
if [ "$items" -eq 0 ]; then
	reason="no-plan"
	emit_and_exit
fi

if [ "$items" -gt "$threshold" ]; then
	spt=1
fi

if [ "$enabled" -ne 1 ]; then
	reason="disabled"
	emit_and_exit
fi

if [ "$items" -le "$threshold" ]; then
	reason="at-or-under-threshold"
	emit_and_exit
fi

# ---------------------------------------------------------------------------
# Past the threshold and permitted: build the tree.
# ---------------------------------------------------------------------------
if [ -n "$title" ]; then
	parent_title="fan-out ${crit:-uncritted} — ${title}"
else
	parent_title="fan-out ${crit:-uncritted} — ${items} items"
fi
[ -n "$prd" ] && parent_title="$parent_title (PRD #${prd})"

parent_id="$(bd_create "$parent_title" | json_id)"
if [ -z "$parent_id" ]; then
	reason="mint-failed"
	printf 'fanout-decompose: could not mint the parent epic bead; building serially. cause: %s\n' \
		"$(mint_cause)" >&2
	emit_and_exit
fi
parent="$parent_id"

minted=0
while IFS= read -r item; do
	[ -n "$item" ] || continue
	child_id="$(bd_create "$item" "$parent_id" | json_id)"
	if [ -z "$child_id" ]; then
		# Fold back to serial with the partial tree named, rather than
		# shipping a half-decomposed fan-out. The parent id is on the report
		# AND on stderr so the orphans are findable.
		children="$minted"
		reason="mint-failed"
		printf 'fanout-decompose: child mint failed after %s of %s; parent %s left for reaping; building serially. cause: %s\n' \
			"$minted" "$items" "$parent_id" "$(mint_cause)" >&2
		emit_and_exit
	fi
	minted=$((minted + 1))
done <"$items_file"

decision="fanout"
reason="over-threshold"
children="$minted"
spt=0
emit_and_exit
