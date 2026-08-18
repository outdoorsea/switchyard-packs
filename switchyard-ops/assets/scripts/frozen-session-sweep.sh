#!/bin/sh
# frozen-session-sweep: revive sessions frozen at a terminal API error.
#
# THE FAILURE
#
# When an agent's turn dies at a terminal API error — the shared account's
# usage limit ("You've reached your … limit. Run /usage-credits …") or a 529
# overload — the CLI prints the error and returns to an idle prompt. Nothing
# ever re-prompts it: the limit window resets, the overload passes, and the
# session stays parked forever. Every health surface reads it as fine — the
# pane repaints, `gc status` is clean, the reconciler counts it active — and
# because a frozen session still OCCUPIES ITS SLOT, a scaled lane (max=1)
# never spawns a replacement either. One frozen judge silently unstaffs the
# whole judging lane.
#
# Observed 2026-08-18 on this city: the switchyard judge frozen 18h at the
# usage-limit message (zero validation verdicts in ~22h), a brakeman 22h
# mid-edit whose healthy sibling then idle-exited because the frozen one
# "held" the bead, both intake-triage sessions frozen on 529s. The factory
# produced zero events for 7 hours.
#
# THE REMEDY IS A NUDGE, NEVER A KILL
#
# A frozen session holds recoverable context — it resumes exactly where it
# froze when re-prompted, which a replacement session cannot. So this sweep
# sends `gc session nudge` with a resume message that tells the agent to
# RE-VERIFY STATE FIRST (its leases were likely reclaimed while it was
# frozen; sibling PRs may have merged). Nudging a still-capped session is
# effectively free — the attempt is refused before any inference happens —
# and the sweep simply tries again next cycle, which is exactly right for a
# limit window that clears on its own schedule.
#
# JURISDICTION — what this sweep deliberately does NOT touch:
#
#   * A pane with UNSUBMITTED TEXT on its input line is pane-stall's finding.
#     gc's nudge path types text and sends Enter WITHOUT clearing the line
#     first, so nudging such a pane would concatenate onto the fragment and
#     submit a corrupted string.
#   * A pane AWAITING A MENU SELECTION is pane-stall's finding too. A nudge
#     ends with Enter, and Enter on a menu SELECTS THE HIGHLIGHTED OPTION —
#     an action taken on the agent's behalf that nobody chose.
#   * A busy pane is never touched: live markers win in the classifier.
#   * A pane whose ENDING state is a clean exit (its last reapable marker
#     sits below any error) is the reaper's jurisdiction — the classifier
#     reads order, so such a pane never reaches the nudge at all.
#
# ATTEMPT CAP AND ESCALATION
#
# Retries are capped per frozen episode (default 20 — at the 15m cadence that
# covers a five-hour limit window) so a marker false-positive cannot burn
# tokens forever. At the cap the sweep mails the mayor ONCE and goes quiet
# about that episode. An episode is keyed on session + matched marker, and it
# RESETS the moment the session stops reading as frozen — a session that
# recovers and freezes again next week starts a fresh episode. The state file
# is rewritten from live observations each pass, so a session that disappears
# resets too — but ONLY from a pass that actually observed the session list:
# a dead tmux server or an unusable state dir keeps the old state untouched,
# because rebuilding from an unobserved pass would reset counters and re-mail
# escalations that already fired.
set -u

. "$(dirname "$0")/../lib/roster.sh"
. "$(dirname "$0")/../lib/pane-state.sh"

sy_load_conf

CITY_NAME="$(sy_city_name)"
STATE="$(sy_state_dir)/frozen-session.attempts"
NUDGE_CAP="${FROZEN_NUDGE_CAP:-20}"
STATE_DIR="$(dirname "$STATE")"

# Fail closed if we cannot read or persist state: a sweep that cannot record
# its attempts must not erase the existing counters or escalation history.
if ! mkdir -p "$STATE_DIR" 2>/dev/null || [ ! -w "$STATE_DIR" ]; then
  exit 0
fi
if [ ! -f "$STATE" ]; then
  : > "$STATE" 2>/dev/null || exit 0
fi
[ -r "$STATE" ] && [ -w "$STATE" ] || exit 0

# pane-stall's markers, for the two blocked-pane kinds this sweep must leave
# to it (see JURISDICTION above).
MENU_MARKER='Enter to select'
PROMPT_GLYPH='❯'

NEW_STATE="$(mktemp "$STATE_DIR/.sy-frozen-state.XXXXXX" 2>/dev/null)" || exit 0
escalations=""

RESUME_MSG="A terminal API error (usage limit or overload) ended your last turn and nothing resumed you; the condition may have cleared. Resume your role now. RE-VERIFY CURRENT STATE FIRST — hours may have passed: any lease you held was likely reclaimed, sibling PRs may have merged, and queues have moved. Re-read your queue and re-claim rather than trusting pre-freeze conclusions. If there is genuinely no work, exit the turn IDLE."

SESSIONS="$(mktemp "${TMPDIR:-/tmp}/sy-frozen-sessions.XXXXXX" 2>/dev/null)" || {
  rm -f "$NEW_STATE"
  exit 0
}
if ! tmux -L "$CITY_NAME" list-sessions -F '#{session_name}' >"$SESSIONS" 2>/dev/null; then
  rm -f "$SESSIONS" "$NEW_STATE"
  exit 0
fi

while IFS= read -r s; do
  [ -n "$s" ] || continue
  cap="$(mktemp "${TMPDIR:-/tmp}/sy-frozen-cap.XXXXXX" 2>/dev/null)" || continue
  if ! tmux -L "$CITY_NAME" capture-pane -p -t "$s" >"$cap" 2>/dev/null; then
    rm -f "$cap"
    continue
  fi

  # The classifier reads the pane's ENDING state, not marker presence: a pane
  # that recovered from its error and chose to exit (error above a later IDLE
  # line) returns empty here and is the reaper's to collect — while a nudged
  # session whose NEW turn died (IDLE line above a later error) still reads
  # frozen. A sweep-level "skip anything classify_file calls reapable" guard
  # was tried instead and is wrong for that second ordering, which this
  # sweep's own retry nudges manufacture every cycle.
  reason="$(sy_pane_frozen_reason_file "$cap")"
  if [ -z "$reason" ]; then
    # Not frozen: carrying nothing forward is what resets the episode.
    rm -f "$cap"
    continue
  fi

  # Menu on screen → awaiting-selection; Enter would choose an option.
  if grep -qF "$MENU_MARKER" "$cap"; then
    rm -f "$cap"
    continue
  fi

  # Text on the input line → unsubmitted-input; a nudge would append to it.
  # Same extraction and same placeholder allowances as pane-stall.
  pending="$(grep -E "^[[:space:]]*$PROMPT_GLYPH" "$cap" \
    | tail -1 \
    | sed "s/^[[:space:]]*$PROMPT_GLYPH//" \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  case "$pending" in
    ""|"Press up"*|"Try "*|"/"*|"Chat about"*) ;;
    *) rm -f "$cap"; continue ;;
  esac
  rm -f "$cap"

  key="$s|$(printf '%s' "$reason" | cksum | awk '{print $1}')"
  count="$(awk -F'\t' -v k="$key" '$1 == k { print $2 }' "$STATE" 2>/dev/null | head -1)"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac

  if [ "$count" -lt "$NUDGE_CAP" ]; then
    gc session nudge "$s" "$RESUME_MSG" >/dev/null 2>&1
    count=$((count + 1))
  elif [ "$count" -eq "$NUDGE_CAP" ]; then
    # Cap reached: escalate once, then only remember the episode.
    escalations="$escalations
  $s [$reason] $NUDGE_CAP resume nudges over $(( NUDGE_CAP / 4 ))h+ and it is still frozen"
    count=$((count + 1))
  fi

  printf '%s\t%s\n' "$key" "$count" >> "$NEW_STATE"
done < "$SESSIONS"
rm -f "$SESSIONS"

mv -f "$NEW_STATE" "$STATE" 2>/dev/null || rm -f "$NEW_STATE"

if [ -n "$escalations" ]; then
  gc mail send mayor \
    -s "frozen-session-sweep: session(s) still frozen after the nudge cap" \
    -m "These sessions froze at a terminal API error, and repeated resume nudges have not revived them:
$escalations

A frozen session reads active on every health surface while doing nothing, and it occupies its lane's slot, so the lane is unstaffed until this is cleared. The sweep has stopped nudging these episodes. Attach and resume each one by hand:

  tmux -L $CITY_NAME attach -t <session>

If the pane shows the usage-limit message, the account is still capped: add credits or switch the lane's model. If it shows something else, this sweep's markers may need extending — see SY_PANE_FROZEN_MARKERS in assets/lib/pane-state.sh. Each episode is reported once; the sweep resumes automatically if the session recovers and freezes afresh." >/dev/null 2>&1
fi

exit 0
