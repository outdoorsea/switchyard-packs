#!/bin/sh
# fanout.sh — how many fan-out children may run at once, and the slot gate that
# holds them to it (switchyard PRD #372, crit:b88e92ac18fe).
#
# WHY A CAP AT ALL. A fan-out's children are LLM sessions, not threads: each one
# is a full model context doing real work on a shared worktree. An eight-item
# plan that starts eight of them at once does not go eight times faster — it
# competes for the same box the parent, its lease keeper, and every other rig's
# workers are already on, and the first thing to degrade is the thing hardest to
# see (a child that stalls looks exactly like a child that is thinking).
#
# WHY IT IS LOAD-AWARE AND NOT JUST A CONSTANT. The right number is not a
# property of the plan, it is a property of the box at the moment the fan-out
# runs. The balancer already measures that and publishes a per-lane target, and
# four spawn sites already cap themselves at it. A fan-out is a fifth spawn
# site, so it honours the same signal rather than inventing a second opinion
# about how busy the city is.
#
# THE ONE READER, REUSED. sy_balancer_capped (lib/roster.sh) is that signal's
# only reader, and this file calls it rather than parsing balancer.targets
# again. PRD #397 states the reason plainly: "a rule re-implemented per caller
# is the same rule only by coincidence, and drifts the first time one of them is
# fixed alone". Everything about freshness, the symmetric staleness window, and
# all-or-nothing well-formedness therefore lives in exactly one place, and this
# consumer inherits every fix to it. scripts/fanout-cap.test.sh asserts the
# reuse against the source, because a private copy would pass every behavioural
# case and still be the defect.
#
# TWO FAIL DIRECTIONS, AND BOTH POINT THE SAME WAY: KEEP BUILDING.
#
#   A cap we cannot compute falls back to the operator's configured value.
#   Inherited from sy_balancer_capped, whose absent/stale/malformed/unreadable
#   cases all answer "no target". A gate that failed CLOSED to zero would let
#   one corrupt state file stop every fan-out in the city — the outage the
#   balancer exists to prevent rather than cause.
#
#   A cap that resolves BELOW ONE is raised to one. This is the same argument
#   one step further in: zero concurrent children is not a throttle, it is a
#   silent stall, and it is reachable two ways — an operator typing 0, and a
#   balancer publishing a target of 0 for a saturated box. Both mean "as slow as
#   possible", which is one child at a time, not none. The floor SAYS so in the
#   report (cap_source=floor) rather than quietly rounding up, because a fan-out
#   pinned at one child is exactly the "throttled box" a reader needs to
#   recognise.
#
# A GARBAGE KNOB IS THE DEFAULT, NOT A REFUSAL — the same rule
# SY_FANOUT_THRESHOLD obeys, for the same reason: this runs from an order on
# someone else's box, and refusing to build because a knob is misspelled takes
# out the lane it exists to help.
#
# CONFIGURATION
#   SY_FANOUT_MAX_CONCURRENCY  children that may run at once, before the
#                              load-aware gate. Default 3.
#   SY_FANOUT_SLOT_DIR         where the slot gate keeps its slots. Defaults to
#                              a path derived from the shared worktree, so one
#                              fan-out's children share a slot set and two
#                              concurrent fan-outs do not.
#   SY_FANOUT_SLOT_WAIT        seconds a child waits for a slot before running
#                              anyway. Default 300.
#
# Requires roster.sh to be sourced first (sy_balancer_capped).

SY_FANOUT_DEFAULT_MAX_CONCURRENCY=3
SY_FANOUT_MIN_CONCURRENCY=1
SY_FANOUT_DEFAULT_SLOT_WAIT=300

# sy_fanout_cap RIG — echo "<cap> <source>": the number of children that may run
# at once, and which of default/config/balancer/floor decided it.
#
# The source is not decoration. "Two children ran" has two causes that want
# opposite responses — a two-item plan, or a box the balancer has throttled —
# and the value alone cannot tell them apart. Callers put both on their report.
sy_fanout_cap() {
	_sfc_source=default
	_sfc_cap="$SY_FANOUT_DEFAULT_MAX_CONCURRENCY"

	case "${SY_FANOUT_MAX_CONCURRENCY:-}" in
	'' | *[!0-9]*) ;;
	*)
		_sfc_cap="$SY_FANOUT_MAX_CONCURRENCY"
		_sfc_source=config
		;;
	esac

	# The load-aware gate. Guarded on the function EXISTING rather than assumed:
	# a caller that forgot to source roster.sh would otherwise take an empty
	# value as a cap of nothing, turning a missing `.` line into a stalled
	# fan-out. Absent the reader, the configured value stands — the same
	# fail-open direction the reader itself takes.
	if command -v sy_balancer_capped >/dev/null 2>&1; then
		_sfc_gated="$(sy_balancer_capped "${1:-}" brakeman "$_sfc_cap" 2>/dev/null)"
		case "$_sfc_gated" in
		'' | *[!0-9]*) ;;
		*)
			# Strictly lower only: min(), never max(). A published target above
			# the operator's configured cap is not authority to exceed it.
			if [ "$_sfc_gated" -lt "$_sfc_cap" ]; then
				_sfc_cap="$_sfc_gated"
				_sfc_source=balancer
			fi
			;;
		esac
	fi

	if [ "$_sfc_cap" -lt "$SY_FANOUT_MIN_CONCURRENCY" ]; then
		_sfc_cap="$SY_FANOUT_MIN_CONCURRENCY"
		_sfc_source=floor
	fi

	printf '%s %s' "$_sfc_cap" "$_sfc_source"
	unset _sfc_source _sfc_cap _sfc_gated
}

# sy_fanout_slot_dir WORKTREE — where this fan-out's slots live.
#
# Derived from the WORKTREE because that is exactly the set a cap must bound:
# one fan-out's children all share one worktree (the harness refuses any child
# on another), and two unrelated fan-outs on one box share nothing and must not
# contend for each other's slots. Keying on the parent bead instead would be
# wrong in the other direction — a serial retry of a failed child is a different
# bead doing the same fan-out's work.
sy_fanout_slot_dir() {
	if [ -n "${SY_FANOUT_SLOT_DIR:-}" ]; then
		printf '%s' "$SY_FANOUT_SLOT_DIR"
		return 0
	fi
	# cksum is POSIX and present wherever these orders run; a path is folded to
	# a short stable token so the slot directory name cannot itself carry
	# separators or an attacker-influenced string.
	_sfsd_key="$(printf '%s' "${1:-default}" | cksum 2>/dev/null | awk '{print $1}')"
	case "${_sfsd_key:-}" in
	'' | *[!0-9]*) _sfsd_key=default ;;
	esac
	printf '%s/sy-fanout-slots.%s' "${TMPDIR:-/tmp}" "$_sfsd_key"
	unset _sfsd_key
}

# sy_fanout_slot_acquire DIR CAP — take one of CAP slots under DIR, echoing the
# slot path taken and the outcome: "<path> acquired" or "<path> overrun".
#
# ATOMIC BY mkdir. `mkdir` either creates a directory or fails, indivisibly,
# on every filesystem these orders run on — so the first child to create
# slot.<n> owns it and a loser gets a clean failure rather than a torn read.
# A lock FILE tested with `[ -e ]` and then created would have a window between
# the two in which every child sees it free.
#
# A DEAD HOLDER'S SLOT IS RECLAIMED. The holding pid is recorded inside the
# slot, so a full slot set is re-examined rather than believed: a child killed
# by a lease timeout or a reaped fan-out leaves its slot behind, and without
# this every later child on that box would wait out the timeout for a holder
# that no longer exists. Liveness is `kill -0`, which answers for any process
# regardless of who owns it.
#
# WAITING ENDS IN AN OVERRUN, NOT A REFUSAL. Past SY_FANOUT_SLOT_WAIT the child
# runs anyway and the outcome says so. A refusal here would DROP a child, and a
# dropped child is silent partial work — the criterion ships missing a piece and
# the pull request comes up short. Briefly exceeding the cap is a throughput
# problem; losing a child is a correctness one, so the tie goes to running it.
sy_fanout_slot_acquire() {
	_sfsa_dir="$1"
	_sfsa_cap="$2"
	_sfsa_wait="${SY_FANOUT_SLOT_WAIT:-$SY_FANOUT_DEFAULT_SLOT_WAIT}"
	case "$_sfsa_wait" in
	'' | *[!0-9]*) _sfsa_wait="$SY_FANOUT_DEFAULT_SLOT_WAIT" ;;
	esac

	mkdir -p "$_sfsa_dir" 2>/dev/null || {
		# Nowhere to keep slots is not a reason to lose a child.
		printf '%s %s' "-" "unslotted"
		return 0
	}

	_sfsa_spent=0
	while :; do
		_sfsa_n=1
		while [ "$_sfsa_n" -le "$_sfsa_cap" ]; do
			if mkdir "$_sfsa_dir/slot.$_sfsa_n" 2>/dev/null; then
				printf '%s\n' "$$" >"$_sfsa_dir/slot.$_sfsa_n/holder" 2>/dev/null || :
				printf '%s %s' "$_sfsa_dir/slot.$_sfsa_n" "acquired"
				unset _sfsa_dir _sfsa_cap _sfsa_wait _sfsa_spent _sfsa_n
				return 0
			fi
			_sfsa_n=$((_sfsa_n + 1))
		done

		# Every slot is taken. Before waiting on them, check they are held by
		# processes that still exist.
		sy_fanout_slot_reap "$_sfsa_dir" "$_sfsa_cap"

		if [ "$_sfsa_spent" -ge "$_sfsa_wait" ]; then
			printf '%s %s' "-" "overrun"
			unset _sfsa_dir _sfsa_cap _sfsa_wait _sfsa_spent _sfsa_n
			return 0
		fi
		sleep 1
		_sfsa_spent=$((_sfsa_spent + 1))
	done
}

# sy_fanout_slot_reap DIR CAP — drop slots whose recorded holder is gone.
#
# A slot with NO holder file is left alone: it is a slot mid-acquisition, in the
# window between mkdir and the holder write, and reaping it would hand the same
# slot to two children.
sy_fanout_slot_reap() {
	_sfsr_n=1
	while [ "$_sfsr_n" -le "$2" ]; do
		_sfsr_slot="$1/slot.$_sfsr_n"
		if [ -d "$_sfsr_slot" ] && [ -f "$_sfsr_slot/holder" ]; then
			_sfsr_pid="$(head -n1 "$_sfsr_slot/holder" 2>/dev/null | tr -d ' ')"
			case "${_sfsr_pid:-}" in
			'' | *[!0-9]*) ;;
			*)
				if ! kill -0 "$_sfsr_pid" 2>/dev/null; then
					rm -rf "$_sfsr_slot" 2>/dev/null || :
				fi
				;;
			esac
		fi
		_sfsr_n=$((_sfsr_n + 1))
	done
	unset _sfsr_n _sfsr_slot _sfsr_pid
	return 0
}

# sy_fanout_slot_release SLOT — give the slot back. A no-op for "-", which is
# what an overrun or an unslotted run carries.
sy_fanout_slot_release() {
	case "${1:-}" in
	'' | '-') return 0 ;;
	esac
	rm -rf "$1" 2>/dev/null || :
	return 0
}
