# pane-state — decide whether a session's tmux pane says it is SAFE TO REAP.
# Sourced by the sweep teardown path (switchyard PRD #299, crit:1d9368c361bb).
#
# THE DISCRIMINATOR IS PANE STATE, NEVER AGE
#
# `judge-sweep` and `answer-sweep` spawn one adhoc session per rig per cycle and
# never remove them, so the population grows until the host saturates (14
# concurrent adhoc sessions across two rigs on 2026-08-03, load excursion to 311
# on a 16-core box). Teardown is the fix — but teardown needs a rule for "is
# this session finished?", and the obvious rule is wrong.
#
# AGE WAS TRIED AND IT KILLED LIVE AGENTS. An age-based guard classified 4 of 12
# sessions wrongly; one of the sessions it killed had authored an escalation
# still sitting unread in the mayor's inbox. Age cannot work here because the
# quantity it measures is uncorrelated with the quantity that matters: a long
# thinking turn emits nothing for minutes and looks exactly like an idle
# session, while a session that has been up for hours may have been handed work
# a second ago. So this classifier accepts ONE input — the pane capture — and
# deliberately has no parameter through which a timestamp, a start time, or an
# idle duration could ever be passed.
#
# PRECEDENCE: LIVE WINS, ALWAYS
#
# A capture can hold both kinds of marker at once, and this is ordinary rather
# than exotic: an agent prints `IDLE: no work, exiting turn.`, gets nudged, and
# is mid-turn again while the old line is still on screen. Scrollback is
# history, not state. So the live markers are tested FIRST and unconditionally —
# if one is present the verdict is `live` no matter what else the capture holds.
# Every ambiguous reading resolves the same way, because the two errors are not
# equal: failing to reap costs one retained session until the next cycle, while
# reaping a live agent destroys in-flight work irrecoverably.
#
# FAIL CLOSED, BUT NOT SHUT
#
# Empty, unreadable, unparseable and simply UNRECOGNISED captures all classify
# `live`. The last of those is the one worth stating plainly: absence of a live
# marker is not evidence of idleness, so a pane showing something this rule set
# has never seen is left running rather than reaped on a guess.
#
# The opposite failure is just as real, though — a gate that stops everything is
# a reaper that quietly does nothing, which is indistinguishable from the leak it
# was written to fix. That is why "unparseable" is drawn NARROWLY: only genuine
# non-text bytes count. ANSI escape sequences are explicitly tolerated, because
# a pane captured with `capture-pane -e` legitimately carries them and treating
# colour codes as corruption would pin every verdict to `live` forever.

# Markers that mean the session is MID-TURN.
#
# `esc to interrupt` is the footer offering a way to cancel the running turn: it
# is present for the whole of a turn and gone the moment it ends, which makes it
# a far better liveness signal than output recency. `Running` covers the spinner
# line of a tool call in flight. Matched case-sensitively and literally.
SY_PANE_LIVE_MARKERS='esc to interrupt
Running'

# Markers that mean the session has FINISHED and is safe to remove.
#
# `IDLE` is the uppercase protocol token the pack's own prompts emit when a
# worker finds nothing to do (`IDLE: no work, exiting turn.`); `exiting turn` is
# the same sentence's tail and also covers a turn that ended without the token.
# Matched case-sensitively on purpose: the English word "idle" appears in
# ordinary prose an agent may be reading or writing, and must not be mistaken
# for the protocol token that authorises a kill.
SY_PANE_REAPABLE_MARKERS='IDLE
exiting turn'

# _sy_pane_has_marker LIST FILE — 0 when any newline-separated marker in LIST
# appears anywhere in FILE, 1 otherwise.
#
# Iterates with `for` rather than `printf | while read` on purpose: a piped
# `while` body runs in a SUBSHELL, so a flag set inside it is lost and a match
# could only be signalled by an exit code — which inverts the logic into
# "failure means found" and reads as a bug. `set -f` guards the unquoted
# expansion that performs the newline splitting, so a marker containing a glob
# character can never be pathname-expanded into something else.
_sy_pane_has_marker() {
	_syp_list="$1"
	_syp_file="$2"
	_syp_found=1
	_syp_saved_ifs="$IFS"
	IFS='
'
	set -f
	for _syp_m in $_syp_list; do
		if [ -n "$_syp_m" ] && grep -qF "$_syp_m" "$_syp_file" 2>/dev/null; then
			_syp_found=0
			break
		fi
	done
	set +f
	IFS="$_syp_saved_ifs"
	return "$_syp_found"
}

# sy_pane_classify_file FILE — print `reapable` or `live` for the capture in FILE.
#
# Never fails: every error path prints `live`, so a caller that ignores exit
# status still gets the safe answer rather than an empty verdict it might treat
# as false.
sy_pane_classify_file() {
	_syp_f="${1:-}"

	# Unreadable (missing file, no permission, or the capture command failed and
	# left nothing behind) → live. Nothing was learned, so nothing is reaped.
	if [ -z "$_syp_f" ] || [ ! -r "$_syp_f" ]; then
		printf 'live'
		return 0
	fi

	# Empty → live. A pane that captured as nothing is a pane we failed to read,
	# not a pane with nothing on it.
	if [ ! -s "$_syp_f" ]; then
		printf 'live'
		return 0
	fi

	# Unparseable → live. Deleting every byte that can legitimately appear in a
	# capture leaves nothing for well-formed text; a non-empty remainder is a
	# genuine control byte, i.e. not a pane capture at all.
	#
	# The delete set is wider than "printable ASCII" for two reasons, and BOTH
	# are load-bearing:
	#
	#   \033       ANSI escapes. A pane captured with `capture-pane -e` carries
	#              colour sequences; treating those as corruption would answer
	#              `live` for every coloured pane.
	#   \200-\377  every high byte, i.e. all of UTF-8. LC_ALL=C makes the
	#              character classes BYTE-oriented, so without this range each
	#              continuation byte of `╭`, `●` or `✻` reads as a control byte
	#              — and an agent pane is nothing but box-drawing chrome and
	#              status glyphs. Omitting it pinned every real capture to
	#              `live`, which is not a safe classifier but a reaper that
	#              silently never reaps.
	#
	# LC_ALL=C is kept deliberately: byte-oriented classification is what makes
	# this check independent of the locale the sweep happens to run under.
	#
	# Counted with `wc -c` rather than captured with `$(…)`: the remainder is
	# exactly the bytes that may include NUL, and command substitution both
	# strips NUL and warns about it on every call.
	_syp_junk="$(LC_ALL=C tr -d '[:print:][:space:]\033\200-\377' <"$_syp_f" 2>/dev/null | wc -c | tr -d ' ')"
	if [ "${_syp_junk:-0}" -gt 0 ] 2>/dev/null; then
		printf 'live'
		return 0
	fi

	# Live markers FIRST — see the precedence note in the header. Any hit ends
	# the classification; reapable markers are never consulted.
	if _sy_pane_has_marker "$SY_PANE_LIVE_MARKERS" "$_syp_f"; then
		printf 'live'
		return 0
	fi

	if _sy_pane_has_marker "$SY_PANE_REAPABLE_MARKERS" "$_syp_f"; then
		printf 'reapable'
		return 0
	fi

	# Recognised nothing → live. Absence of a live marker is not evidence of
	# idleness.
	printf 'live'
	return 0
}

# sy_pane_classify — print `reapable` or `live` for a capture read from stdin.
#
# Spools to a temp file rather than a shell variable because the input may hold
# NUL bytes: command substitution silently drops those, which would erase the
# very evidence the unparseable check looks for and let binary garbage classify
# as ordinary text.
sy_pane_classify() {
	_syp_tmp="$(mktemp "${TMPDIR:-/tmp}/sy-pane.XXXXXX" 2>/dev/null)" || {
		printf 'live'
		return 0
	}
	cat >"$_syp_tmp" 2>/dev/null
	_syp_verdict="$(sy_pane_classify_file "$_syp_tmp")"
	rm -f "$_syp_tmp" 2>/dev/null
	printf '%s' "$_syp_verdict"
}

# sy_pane_classify_session SESSION [SOCKET] — capture SESSION's pane and classify it.
#
# The thin tmux-facing wrapper. A capture-pane that exits non-zero (dead
# session, unreachable server, wrong socket) yields `live` without consulting
# its partial output: a session we cannot see is never one we kill.
sy_pane_classify_session() {
	_syp_s="${1:?sy_pane_classify_session: SESSION is required}"
	_syp_sock="${2:-}"

	if [ -n "$_syp_sock" ]; then
		_syp_cap="$(tmux -L "$_syp_sock" capture-pane -p -t "$_syp_s" 2>/dev/null)" || {
			printf 'live'
			return 0
		}
	else
		_syp_cap="$(tmux capture-pane -p -t "$_syp_s" 2>/dev/null)" || {
			printf 'live'
			return 0
		}
	fi

	printf '%s' "$_syp_cap" | sy_pane_classify
}
