#!/bin/sh
# nightly-retro: one coordinator closes the day across this city's switchyard
# projects. Which coordinator is a city decision (RETRO_AGENT in roster.conf);
# what it does is assets/prompts/nightly-retro.md.
set -u

. "$(dirname "$0")/../lib/roster.sh"
sy_load_conf

ROSTER_CONF="$(sy_state_dir)/roster.conf"
MARKER="$(sy_state_dir)/nightly-retro.unconfigured"
PROMPT="$(dirname "$0")/../prompts/nightly-retro.md"
[ -r "$PROMPT" ] || exit 0

if [ -z "${RETRO_AGENT:-}" ]; then
  # No retro agent declared. Tell the mayor once a day, then stay quiet: a city
  # may legitimately not want a retro, and a nightly nag would train the mayor
  # to ignore this pack's mail.
  mkdir -p "$(dirname "$MARKER")" 2>/dev/null
  if [ ! -f "$MARKER" ] || [ -n "$(find "$MARKER" -mmin +1440 2>/dev/null)" ]; then
    gc mail send mayor -s "nightly-retro: no RETRO_AGENT configured (daily notice)" \
      -m "switchyard-ops' nightly-retro order is enabled but no RETRO_AGENT is set in this city's roster.conf, so no daily report was drafted. Set RETRO_AGENT=\"<rig>/<agent>\" in $ROSTER_CONF (see assets/roster.conf.example), or remove the nightly-retro order from your imports." >/dev/null 2>&1
    touch "$MARKER" 2>/dev/null
  fi
  exit 0
fi

# RETRO_AGENT is an AGENT qualified name; `gc session nudge` resolves a SESSION
# id-or-alias, and a live session carries an instance suffix. Nudging the bare
# agent name silently did nothing (rc=1, discarded) — the retro simply never ran
# and never said so. Resolve to a live alias, and escalate when there is none.
#
# A FAILED lookup is not an absent session — see sy_live_session_for's contract.
# Telling the operator to spawn a session when the roster merely could not be
# read points them at the wrong repair.
if ! target="$(sy_live_session_for "$RETRO_AGENT")"; then
  gc mail send mayor -s "nightly-retro: session lookup failed for RETRO_AGENT" \
    -m "nightly-retro could not determine whether RETRO_AGENT=$RETRO_AGENT has a live session: 'gc session list --json' could not be run, or its output could not be parsed. No daily report was drafted. This is an UNKNOWN, not an absent session — check gc and jq rather than spawning a session." >/dev/null 2>&1
  exit 0
fi
if [ -z "$target" ]; then
  gc mail send mayor -s "nightly-retro: no live session for RETRO_AGENT" \
    -m "nightly-retro resolved RETRO_AGENT=$RETRO_AGENT from roster.conf, but that agent has no active session to nudge, so no daily report was drafted. Check the agent is imported into its rig and not suspended, then spawn a session for it." >/dev/null 2>&1
  exit 0
fi

if ! gc session nudge "$target" "$(cat "$PROMPT")" >/dev/null 2>&1; then
  gc mail send mayor -s "nightly-retro: nudge failed" \
    -m "nightly-retro resolved RETRO_AGENT=$RETRO_AGENT to session $target, but gc session nudge returned non-zero, so no daily report was drafted." >/dev/null 2>&1
fi

exit 0
