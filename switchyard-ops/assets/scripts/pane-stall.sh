#!/bin/sh
# pane-stall: report a session sitting idle but BLOCKED AT ITS PANE — either
# holding unsubmitted text on its input line, or parked on a multiple-choice
# prompt. Either way it will never act and never say so.
#
# THE FAILURE
#
# A tmux-backed session's input line is a buffer, and text only becomes a turn
# when Enter arrives. Anything that leaves text there without submitting it
# parks the agent indefinitely: the pane repaints, `gc status` reads clean, the
# reconciler counts the session alive, orders keep firing ok:true. Nothing is
# wrong by any existing check, and the agent does nothing. Observed on
# switchyard-forge's coordinator overnight — the fragment "why didn't the" sat
# in the buffer while 13 beads stayed unrouted with no workers.
#
# TWO KINDS, deliberately reported by one order because they are indistinguishable
# from every other vantage point — both read `active`, both do nothing:
#
#   unsubmitted-input   text reached the line but never became a turn, so the
#                       agent has NOT SEEN IT. Done TO the agent; no prompt rule
#                       can prevent it.
#   awaiting-selection  the agent raised a menu and is waiting for a keypress.
#                       The agent CHOSE this; the prompts forbid it, and a
#                       report here means an agent whose prompt predates that
#                       rule, or one that ignored it.
#
# WHY IT HAPPENS, AND WHY THIS IS A DETECTOR RATHER THAN A FIX
#
# gc's live nudge path (internal/runtime/carrier.go, tmuxCarrier.Nudge) is two
# `send-keys` calls: type the literal text, then send Enter. It never clears the
# line first, so:
#   * a human who types a half-question and walks away leaves it there, and the
#     next nudge CONCATENATES onto the fragment before submitting;
#   * a nudge whose Enter step fails strands its own text (the function's own
#     comment acknowledges "the pane may hold a half-typed, unsubmitted line").
#
# A clearing implementation exists — `SendKeysReplace` in
# internal/runtime/tmux/tmux.go sends C-u first, and its comment says exactly
# why — but it has ZERO callers. The safe path is dead code and the live path
# skips it. Fixing that belongs in gc, not in this pack; until it lands, the
# condition is at least detectable, and that is what this order does.
#
# It reports and NEVER clears. Clearing another agent's input line is a
# destructive act on a session that might be one keystroke from doing real work,
# and a detector that guesses wrong about that is worse than the stall.
set -u

. "$(dirname "$0")/../lib/roster.sh"

sy_load_conf

CITY_NAME="$(sy_city_name)"
SEEN="$(sy_state_dir)/pane-stall.reported"
mkdir -p "$(dirname "$SEEN")" 2>/dev/null
[ -f "$SEEN" ] || : > "$SEEN"

# A pane is ACTIVELY WORKING when its footer offers a way to interrupt the turn.
# That marker is present for the whole of a turn and absent the moment it ends,
# which makes it a far better liveness signal than output recency: a long
# thinking turn emits nothing for minutes and would read as idle by any
# quiet-for-N-seconds rule.
BUSY_MARKER='esc to interrupt'

# An idle pane is blocked in one of two ways, and they need different remedies,
# so the report names which. Order matters: the menu test MUST come first,
# because a menu also renders the prompt glyph (it marks the SELECTED OPTION,
# not an input line) and would otherwise be misreported as pending text.
MENU_MARKER='Enter to select'
PROMPT_GLYPH='❯'

stalled=""

for s in $(tmux -L "$CITY_NAME" list-sessions -F '#{session_name}' 2>/dev/null); do
  pane="$(tmux -L "$CITY_NAME" capture-pane -p -t "$s" 2>/dev/null)" || continue
  [ -n "$pane" ] || continue

  # Busy: leave it alone. The common case, and it must stay cheap.
  printf '%s' "$pane" | grep -qF "$BUSY_MARKER" && continue

  kind=""
  detail=""

  if printf '%s' "$pane" | grep -qF "$MENU_MARKER"; then
    # Blocked on an interactive menu. The agent chose to ask; it will wait
    # forever because nobody is watching the pane.
    kind="awaiting-selection"
    detail="$(printf '%s\n' "$pane" | grep -E '^[[:space:]]*[❯>][[:space:]]*[0-9]+\.' | head -1 \
              | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$detail" ] || detail="(a multiple-choice prompt is on screen)"
  else
    # Blocked on unsubmitted text: it reached the input line but never became a
    # turn, so the agent has not seen it at all.
    pending="$(printf '%s\n' "$pane" \
      | grep -E "^[[:space:]]*$PROMPT_GLYPH" \
      | tail -1 \
      | sed "s/^[[:space:]]*$PROMPT_GLYPH//" \
      | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$pending" ] || continue
    # Placeholders and hints are not pending input.
    case "$pending" in
      "Press up"*|"Try "*|"/"*|"Chat about"*) continue ;;
    esac
    kind="unsubmitted-input"
    detail="$(printf '%s' "$pending" | cut -c1-72)"
  fi

  key="$s:$kind:$(printf '%s' "$detail" | cksum | awk '{print $1}')"
  grep -qxF "$key" "$SEEN" 2>/dev/null && continue
  printf '%s\n' "$key" >> "$SEEN"

  stalled="$stalled
  $s [$kind] $detail"
done

# If the MAYOR is itself among the stalled, this mail lands in a stalled inbox.
# Say so in the body rather than letting the escalation vanish into the very
# failure it is reporting.
mayor_note=""
case "$stalled" in
  *"
  mayor ["*) mayor_note="

⚠ THE MAYOR IS ITSELF ONE OF THE STALLED SESSIONS, so this message is sitting in an inbox nobody is reading. Clear the mayor's pane FIRST; nothing else here will be seen until you do." ;;
esac

if [ -n "$stalled" ]; then
  gc mail send mayor \
    -s "pane-stall: session(s) blocked at the pane, doing nothing" \
    -m "These sessions are idle and BLOCKED AT THEIR PANE. Every health surface reads them as fine — session active, status clean, orders firing — and none of them is doing any work:
$stalled

[unsubmitted-input] Text reached the input line but was never submitted, so the agent has NOT SEEN IT. Usually a half-typed line someone left behind, or a nudge whose Enter step failed. gc's nudge path types the text and sends Enter as two separate steps and does NOT clear the line first, so the fragment also CORRUPTS THE NEXT NUDGE — the new message is appended to it and submitted as one string. Clear it, or press Enter if it is a question worth answering:

  tmux -L $CITY_NAME attach -t <session>     # Ctrl-U clears the line

[awaiting-selection] The agent raised a multiple-choice prompt and is waiting for a keypress nobody is there to give. Answer it, then fix the agent's prompt — an agent in this city must never ask an interactive question; it should decide, act, and escalate asynchronously by mail.

Do not assume a reported agent is broken. It is waiting on something it cannot act on alone. Each distinct stall is reported once.$mayor_note" >/dev/null 2>&1
fi

exit 0
