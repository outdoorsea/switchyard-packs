#!/bin/sh
# _confine.sh — shared refusal + pass-through for the fan-out confinement.
# switchyard PRD #372, crit:cb7409dc0b5a. Sourced by every shim here; not a
# command itself.
#
# THE SHIMS ARE DEFENCE IN DEPTH, NOT THE ENFORCEMENT. A child's login shell
# re-sets PATH from the user profile, so a shim can be walked around without any
# adversarial intent, and MCP clients spawn their server by absolute path so
# PATH is never consulted at all. What actually stops a child is the harness
# withholding the credentials (fanout-child-run.sh). These exist to refuse
# LOUDLY and say why — a bare 401 teaches a child nothing.

CONFINE_REFUSAL_EXIT=3

# confine_refuse TOOL WHY ARGS... — complain, record, exit non-zero.
confine_refuse() {
	_cr_tool="$1"
	_cr_why="$2"
	shift 2
	printf 'fanout-confine: REFUSED %s %s\n' "$_cr_tool" "$*" >&2
	printf 'fanout-confine: %s\n' "$_cr_why" >&2
	printf 'fanout-confine: you are a fan-out CHILD. The parent brakeman holds this\n' >&2
	printf '  criterion s cloud claim for the whole fan-out and opens the ONE pull\n' >&2
	printf '  request that delivers it. Commit on the shared branch and stop.\n' >&2
	if [ -n "${SY_FANOUT_REFUSAL_LOG:-}" ]; then
		printf '%s\t%s\t%s\n' "${SY_FANOUT_BEAD:-unknown-child}" "$_cr_tool" "$*" \
			>>"$SY_FANOUT_REFUSAL_LOG" 2>/dev/null || :
	fi
	exit "$CONFINE_REFUSAL_EXIT"
}

# confine_exec_real BIN ARGS... — hand off to the real BIN behind this
# directory.
#
# TWO THINGS THIS GETS RIGHT that the first version did not:
#
#   1. The self-removal compares CANONICAL directories. A raw string compare
#      leaves `<confine>/`, `<confine>/.`, a doubled slash or a relative
#      spelling in the path, `command -v` resolves back to the shim, and the
#      exec re-enters it — a process spinning at 100% CPU with no output, which
#      in a fan-out wedges the whole thing. A re-entry sentinel backstops the
#      canonicalisation for any case it still misses.
#   2. PATH is passed as a PREFIX ASSIGNMENT rather than exported. Exporting it
#      hands the real binary — and everything it spawns — a PATH with the
#      confinement stripped out, so one pass-through call silently unconfines
#      every child process under it.
confine_exec_real() {
	_ce_bin="$1"
	shift

	if [ "${SY_FANOUT_CONFINE_REENTRY:-}" = "$_ce_bin" ]; then
		printf 'fanout-confine: re-entered the %s shim; refusing rather than looping\n' "$_ce_bin" >&2
		exit 127
	fi

	_ce_self="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)" || _ce_self=""
	_ce_new=""
	_ce_ifs="$IFS"
	IFS=:
	for _ce_d in $PATH; do
		[ -n "$_ce_d" ] || continue
		_ce_canon="$(cd "$_ce_d" 2>/dev/null && pwd -P)" || _ce_canon="$_ce_d"
		[ -n "$_ce_self" ] && [ "$_ce_canon" = "$_ce_self" ] && continue
		if [ -z "$_ce_new" ]; then _ce_new="$_ce_d"; else _ce_new="$_ce_new:$_ce_d"; fi
	done
	IFS="$_ce_ifs"

	_ce_real="$(PATH="$_ce_new" command -v "$_ce_bin" 2>/dev/null)"
	if [ -z "$_ce_real" ]; then
		printf 'fanout-confine: no %s on PATH behind the confinement\n' "$_ce_bin" >&2
		exit 127
	fi

	SY_FANOUT_CONFINE_REENTRY="$_ce_bin" PATH="$_ce_new" exec "$_ce_real" "$@"
}
