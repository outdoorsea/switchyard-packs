# pane-state — decide whether a session's tmux pane says it is SAFE TO REAP.
# Sourced by the sweep teardown path (switchyard PRD #299, crit:1d9368c361bb —
# the decision rule; crit:ca7a9d0965e8 — the fail-closed reads).
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

# _sy_pane_is_unparseable FILE — 0 when FILE contains bytes that cannot
# legitimately appear in a tmux pane capture, 1 otherwise.
#
# Uses the same byte-oriented delete set as sy_pane_classify_file; see the
# long rationale there. LC_ALL=C keeps the classes byte-oriented, and wc -c
# counts the remainder rather than command substitution (which strips NUL and
# warns).
_sy_pane_is_unparseable() {
	_syp_f="$1"
	_syp_junk="$(LC_ALL=C tr -d '[:print:][:space:]\033\200-\377' <"$_syp_f" 2>/dev/null | wc -c | tr -d ' ')"
	[ "${_syp_junk:-0}" -gt 0 ] 2>/dev/null
}

# _sy_pane_first_marker LIST FILE — print the first newline-separated marker in
# LIST that appears anywhere in FILE, or nothing if none match.
#
# Iterates with `for` rather than `printf | while read` on purpose: a piped
# `while` body runs in a SUBSHELL, so a result set inside it is lost. `set -f`
# guards the unquoted expansion that performs the newline splitting, so a marker
# containing a glob character can never be pathname-expanded into something else.
# The caller's globbing mode is captured and restored so a shell running under
# `set -f` stays under `set -f`.
_sy_pane_first_marker() {
	_syp_list="$1"
	_syp_file="$2"
	_syp_hit=""
	_syp_saved_ifs="$IFS"
	case $- in
		*f*) _syp_noglob=1 ;;
		*) _syp_noglob=0; set -f ;;
	esac
	IFS='
'
	for _syp_m in $_syp_list; do
		if [ -n "$_syp_m" ] && grep -qF "$_syp_m" "$_syp_file" 2>/dev/null; then
			_syp_hit="$_syp_m"
			break
		fi
	done
	if [ "$_syp_noglob" -eq 0 ]; then
		set +f
	fi
	IFS="$_syp_saved_ifs"
	printf '%s' "$_syp_hit"
}

# _sy_pane_has_marker LIST FILE — 0 when any newline-separated marker in LIST
# appears anywhere in FILE, 1 otherwise. Implemented on top of
# _sy_pane_first_marker so the two public classifiers share one copy of the
# scan loop.
_sy_pane_has_marker() {
	[ -n "$(_sy_pane_first_marker "$1" "$2")" ]
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
	if _sy_pane_is_unparseable "$_syp_f"; then
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

# ---------------------------------------------------------------------------
# FROZEN panes — a third reading, deliberately separate from live/reapable.
#
# A session whose turn ends at a TERMINAL API ERROR — the shared account's usage
# limit, a 529 overload — freezes at an idle prompt and never recovers on its
# own: nothing re-prompts it when the condition clears, the pane repaints, the
# reconciler counts it active, and a scaled lane (max=1) never spawns a
# replacement because the frozen session occupies the slot. Observed 2026-08-18:
# the switchyard judge sat 18h at the usage-limit message (zero validation
# verdicts in ~22h), a brakeman 22h mid-edit, both intake-triage sessions on
# 529s — the factory produced zero events for 7 hours.
#
# This is NOT a reapable/live question, which is why it is a separate function
# rather than a third verdict from sy_pane_classify_file: the reaper's caller
# must keep seeing `live` for a frozen pane (killing it destroys recoverable
# in-turn context — these sessions resume exactly where they froze when
# re-prompted), while the frozen-session sweep needs a reason string to act on.
#
# The markers are the error TEXTS the agent CLI prints when a turn dies:
#
#   /usage-credits   the usage-limit message's stable fragment; both observed
#                    wordings carry it ("Run /usage-credits to continue…",
#                    "…/usage-credits to finish what you're working on").
#   API Error:       the CLI's terminal API-failure prefix (observed: "API
#                    Error: 529 Overloaded"). Matched broadly on purpose — ANY
#                    turn-ending API error strands the session identically, and
#                    the consumer's action (a nudge, attempt-capped) is cheap
#                    enough to tolerate the rare prose false-positive.
#
# Live wins here exactly as it does for reaping: an error line with a live
# marker on screen is a RETRY IN FLIGHT (scrollback is history, not state), so
# it never reads as frozen. And where the reaper fails closed to `live`, this
# fails closed to EMPTY: the consumer is an actor, and "don't act on what you
# cannot read" is the safe direction for an actor.
SY_PANE_FROZEN_MARKERS='/usage-credits
API Error:'

# _sy_pane_last_marker_line LIST FILE — print "<line> <marker>" for the LAST
# line in FILE containing any marker from LIST, or "0 " when none match. Same
# iteration discipline as _sy_pane_first_marker (see its comment); differs in
# asking WHERE, not just whether — the frozen reading below needs positions.
_sy_pane_last_marker_line() {
	_syp_list="$1"
	_syp_file="$2"
	_syp_best=0
	_syp_best_m=""
	_syp_saved_ifs="$IFS"
	IFS='
'
	set -f
	for _syp_m in $_syp_list; do
		[ -n "$_syp_m" ] || continue
		_syp_n="$(grep -nF "$_syp_m" "$_syp_file" 2>/dev/null | tail -1 | cut -d: -f1)"
		case "$_syp_n" in '' | *[!0-9]*) continue ;; esac
		if [ "$_syp_n" -gt "$_syp_best" ]; then
			_syp_best="$_syp_n"
			_syp_best_m="$_syp_m"
		fi
	done
	set +f
	IFS="$_syp_saved_ifs"
	printf '%s %s' "$_syp_best" "$_syp_best_m"
}

# sy_pane_frozen_reason_file FILE — print the frozen marker the capture matches,
# or nothing when the pane is not frozen. Never fails; every error path prints
# nothing.
#
# THE ENDING STATE DECIDES, not mere presence. A capture can hold an error
# marker AND a reapable marker, and the ORDER tells two opposite stories:
#
#   error … then `IDLE: exiting turn`   the turn survived (a retry landed, or a
#                                       later turn ran) and the agent CHOSE to
#                                       end. The error is scrollback history;
#                                       nudging would re-wake a session that
#                                       deliberately finished — and pay for the
#                                       turn.
#   `IDLE: exiting turn` … then error   the agent idled, was nudged, and the NEW
#                                       turn died at the error. The IDLE line is
#                                       the history; the session is frozen. The
#                                       sweep's own retry nudges manufacture
#                                       exactly this ordering, so a mere
#                                       presence test would freeze it OUT of
#                                       the very recovery loop it needs.
#
# So the frozen reading compares POSITIONS: frozen only when the last frozen
# marker sits BELOW the last reapable marker. This is deliberately unlike the
# reaper's "live wins, always" rule, which exists because reaping is
# irreversible; a nudge is not, so the frozen reading can afford to read order.
# Live markers DO still win unconditionally — the busy footer is only ever
# present while a turn is actually running, so beside one, every other marker
# on screen is history.
sy_pane_frozen_reason_file() {
	_syp_f="${1:-}"

	# Unreadable or empty → not frozen. Nothing was learned, so nothing is acted on.
	if [ -z "$_syp_f" ] || [ ! -r "$_syp_f" ] || [ ! -s "$_syp_f" ]; then
		return 0
	fi

	# Unparseable → not frozen, same byte-oriented rule (and the same reasons)
	# as sy_pane_classify_file.
	if _sy_pane_is_unparseable "$_syp_f"; then
		return 0
	fi

	# Live wins, unconditionally: an error banner beside a live marker is a
	# retry in progress, not a frozen session.
	if _sy_pane_has_marker "$SY_PANE_LIVE_MARKERS" "$_syp_f"; then
		return 0
	fi

	_syp_frozen="$(_sy_pane_last_marker_line "$SY_PANE_FROZEN_MARKERS" "$_syp_f")"
	_syp_frozen_at="${_syp_frozen%% *}"
	[ "$_syp_frozen_at" -gt 0 ] 2>/dev/null || return 0

	_syp_reap="$(_sy_pane_last_marker_line "$SY_PANE_REAPABLE_MARKERS" "$_syp_f")"
	_syp_reap_at="${_syp_reap%% *}"
	if [ "${_syp_reap_at:-0}" -ge "$_syp_frozen_at" ] 2>/dev/null; then
		return 0
	fi

	printf '%s' "${_syp_frozen#* }"
	return 0
}

# sy_pane_classify_session SESSION [SOCKET] — capture SESSION's pane and classify it.
#
# The thin tmux-facing wrapper — and the ONLY entry point the sweep's teardown
# calls (`lane_reap` in lane-ensure.sh). A weakness here is a weakness in the
# live reaper no matter how the pure functions above behave, so the two
# fail-closed properties are both enforced on THIS path rather than inherited.
#
# 1. A CAPTURE THAT ERRORS IS NEVER READ. capture-pane exiting non-zero (dead
#    session, unreachable server, wrong socket) yields `live` without consulting
#    whatever partial output it printed: a session we cannot see is never one we
#    kill. The status is therefore consulted before the bytes are, and it is
#    taken from an `if` condition so that a failed capture is a branch rather
#    than an error that could trip a caller's `set -e`.
#
# 2. AN UNPARSEABLE CAPTURE STAYS UNPARSEABLE. The capture is spooled to a file
#    and classified there, never round-tripped through a shell variable — the
#    same reason sy_pane_classify spools stdin, except that here it was a live
#    defect rather than a precaution.
#
#    COMMAND SUBSTITUTION STRIPS NUL BYTES. Reading the capture with
#    `cap="$(tmux capture-pane …)"` deleted precisely the evidence the
#    unparseable check exists to find: a garbage pane of
#    `IDLE\0\0\0 exiting turn` reached the classifier as the clean text
#    `IDLE exiting turn`, matched the reapable marker, and the reaper closed a
#    session this criterion requires be left running. The classifier was never
#    wrong — it was handed laundered input.
#
#    The defect was invisible from a developer shell: zsh is the one shell on
#    this city that PRESERVES NULs through `$(…)`, so the wrapper answered
#    `live` when probed interactively and `reapable` under the `#!/bin/sh` the
#    pack scripts actually run — i.e. it behaved correctly everywhere except
#    where it mattered. Both shells are covered in the self-test.
sy_pane_classify_session() {
	_syp_s="${1:?sy_pane_classify_session: SESSION is required}"
	_syp_sock="${2:-}"

	_syp_tmp="$(mktemp "${TMPDIR:-/tmp}/sy-pane-sess.XXXXXX" 2>/dev/null)" || {
		printf 'live'
		return 0
	}

	# Initialised to the FAILED value: any path that does not explicitly observe
	# a successful capture leaves the wrapper answering `live`.
	_syp_rc=1
	if [ -n "$_syp_sock" ]; then
		if tmux -L "$_syp_sock" capture-pane -p -t "$_syp_s" >"$_syp_tmp" 2>/dev/null; then
			_syp_rc=0
		fi
	else
		if tmux capture-pane -p -t "$_syp_s" >"$_syp_tmp" 2>/dev/null; then
			_syp_rc=0
		fi
	fi

	if [ "$_syp_rc" -ne 0 ]; then
		rm -f "$_syp_tmp" 2>/dev/null
		printf 'live'
		return 0
	fi

	_syp_verdict="$(sy_pane_classify_file "$_syp_tmp")"
	rm -f "$_syp_tmp" 2>/dev/null
	printf '%s' "$_syp_verdict"
}
