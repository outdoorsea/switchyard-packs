#!/bin/sh
# demand.sh — PRE-SPAWN demand predicates for the pack's standing scanner lanes.
#
# WHAT THIS IS FOR. A standing lane spawns a session on its cadence whether or
# not anything it studies has changed. The session then reads its subject,
# discovers there is nothing new, and exits — having paid a full session's
# tokens to answer "no". Measured on this city, the refactor-scout lane cost
# 45.4M tokens/24h that way, 23.8% of the whole city's burn (switchyard issue
# 163). The demand signal is what makes that cost zero: evaluated in the order
# script, BEFORE `gc session new`, a lane with nothing to do costs one cheap
# read of a marker file.
#
# WHY IT LIVES HERE RATHER THAN IN EACH LANE. Two lanes ask the same question
# ("has this repo moved since I last scanned it?") and a third asks a variant of
# it. Three copies of one predicate is the defect city-lane-ensure.sh's own
# header warns about, having been bitten by exactly that: the same counting bug
# was fixed in two of three copies and left live in the third for weeks. One
# implementation, parameterised by marker name, cannot drift against itself.
#
# FAIL OPEN, DELIBERATELY — the single rule both predicates obey. Every state we
# cannot read (no git, no state dir, a corrupt marker, a truncated ledger)
# answers DEMAND. A gate that failed closed would silently retire its lane, and
# a lane that never runs can never report that it isn't running. Failing open
# costs one session and shows up in the next token report; failing closed costs
# the lane and is visible to nobody. That asymmetry is why the marker parsers
# below are strict rather than lenient: a marker we cannot fully trust is
# treated as ABSENT (-> demand), never partially believed (-> skip).
#
# STAMPING HAPPENS AT GATE TIME, not after the session finishes. Same reasoning
# as refactor-scan-gate.sh: a separate end-of-pass record is one more step a
# caller can forget, and forgetting it restores the unbounded loop the gate
# exists to close. Two steps would also mean two reads of the signal, so a pass
# that scanned state A could be recorded against state B and B then skipped
# having never been scanned. One read and one write cannot race with themselves.
# The accepted cost: a session that dies at startup still consumed its demand.
# That is bounded and self-healing — the next change re-arms the gate — and it
# also caps runaway spawning by sessions that crash on startup.
#
# Requires roster.sh to be sourced first (sy_state_dir).

# sy_demand_marker NAME — absolute path of the demand marker called NAME.
# The name reaches the filesystem as a path segment and callers build it from
# rig names, so anything outside a conservative set is folded to '_'.
sy_demand_marker() {
	printf '%s/%s.demand' \
		"$(sy_state_dir)" \
		"$(printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g')"
}

# sy_demand_write FILE VALUE — persist VALUE as the whole of FILE, via temp file
# + rename so a process killed mid-write cannot leave a half-line that the
# strict parsers below would then reject (costing a spurious extra pass). A
# failed write is silent and non-fatal: the marker stays where it was and the
# lane gets one more pass rather than being retired by a full disk.
sy_demand_write() {
	mkdir -p "$(dirname "$1")" 2>/dev/null || return 0
	_sdw_tmp="$1.$$"
	if printf '%s\n' "$2" >"$_sdw_tmp" 2>/dev/null; then
		mv -f "$_sdw_tmp" "$1" 2>/dev/null || rm -f "$_sdw_tmp" 2>/dev/null
	else
		rm -f "$_sdw_tmp" 2>/dev/null
	fi
	unset _sdw_tmp
	return 0
}

# sy_demand_sha_moved NAME REPO — has REPO's HEAD moved since marker NAME was
# stamped?  0 = DEMAND (run the pass), 1 = NO DEMAND (skip it).
#
# This is the scanners' signal, and "diff since the last scanned sha" is exactly
# what it means: the scouts' evidence is derived from the commit graph, so two
# passes at one commit derive the same answer from the same history and the
# second is a pure re-spend.
#
# On demand it stamps the new sha and echoes it, so a caller can name the sha in
# its log line without a second `rev-parse` that could read a different HEAD.
sy_demand_sha_moved() {
	_sdm_marker="$(sy_demand_marker "$1")"
	_sdm_head="$(git -C "$2" rev-parse HEAD 2>/dev/null | awk 'NF' | head -n1)"

	# Unreadable HEAD — not a git repo, no such path, a broken checkout. Fail
	# open: we cannot show the evidence has NOT moved.
	if [ -z "$_sdm_head" ]; then
		printf 'unknown'
		unset _sdm_marker _sdm_head
		return 0
	fi

	# The marker is EXACTLY one line of EXACTLY one 40-hex field. Anything else —
	# extra fields, extra lines, a short or non-hex sha, an empty file — is
	# treated as ABSENT, which resolves to DEMAND. Strict on purpose: a lenient
	# read of a corrupt marker is the one direction this gate must never fail in.
	_sdm_last=""
	if [ -f "$_sdm_marker" ]; then
		_sdm_last="$(awk '
			NR > 1  { bad = 1; exit }
			NF != 1 { bad = 1; exit }
			$1 !~ /^[0-9a-f]{40}$/ { bad = 1; exit }
			{ s = $1 }
			END { if (!bad && s != "") print s }
		' "$_sdm_marker" 2>/dev/null)"
	fi

	if [ "$_sdm_head" = "$_sdm_last" ]; then
		printf '%s' "$_sdm_head"
		unset _sdm_marker _sdm_head _sdm_last
		return 1
	fi

	sy_demand_write "$_sdm_marker" "$_sdm_head"
	printf '%s' "$_sdm_head"
	unset _sdm_marker _sdm_head _sdm_last
	return 0
}

# sy_demand_ledger_grew NAME LEDGER — has LEDGER gained lines since marker NAME
# was stamped?  0 = DEMAND, 1 = NO DEMAND.
#
# This is the auditor's signal. The auditor attributes spend recorded in the
# city's append-only usage sink, so "new usage-ledger lines since the last audit
# marker" is the honest measure of whether there is anything new to attribute.
#
# A MISSING LEDGER IS NO DEMAND, NOT A FAILURE, and that is the one place these
# two predicates deliberately differ. An absent sink is a READABLE fact — nothing
# has been recorded — not a state we failed to read, and token-report.sh already
# treats it as a clean exit rather than an incident. Spawning an auditor to
# attribute an empty file would be the pure re-spend this gate exists to stop.
# A ledger we cannot COUNT, by contrast, is unreadable and fails open.
#
# Echoes the current line count so the caller can log it.
sy_demand_ledger_grew() {
	_sdl_marker="$(sy_demand_marker "$1")"

	if [ ! -f "$2" ]; then
		printf 'absent'
		unset _sdl_marker
		return 1
	fi

	_sdl_now="$(wc -l <"$2" 2>/dev/null | tr -d ' ' | awk 'NF' | head -n1)"
	case "${_sdl_now:-}" in
	'' | *[!0-9]*)
		# Cannot count it — fail open.
		printf 'unknown'
		unset _sdl_marker _sdl_now
		return 0
		;;
	esac

	# Same strict-or-absent rule as the sha marker.
	_sdl_last=""
	if [ -f "$_sdl_marker" ]; then
		_sdl_last="$(awk '
			NR > 1  { bad = 1; exit }
			NF != 1 { bad = 1; exit }
			$1 !~ /^[0-9]+$/ { bad = 1; exit }
			{ n = $1 }
			END { if (!bad && n != "") print n + 0 }
		' "$_sdl_marker" 2>/dev/null)"
	fi

	if [ -n "$_sdl_last" ] && [ "$_sdl_now" -eq "$_sdl_last" ]; then
		printf '%s' "$_sdl_now"
		unset _sdl_marker _sdl_now _sdl_last
		return 1
	fi

	# A count BELOW the marker means the sink was rotated (events-rotate.sh) or
	# truncated, so the lines since the last audit are unknowable rather than
	# zero. Fail open and re-baseline, which is also what keeps a rotation from
	# wedging the lane shut until the ledger grows past its pre-rotation length.
	sy_demand_write "$_sdl_marker" "$_sdl_now"
	printf '%s' "$_sdl_now"
	unset _sdl_marker _sdl_now _sdl_last
	return 0
}
