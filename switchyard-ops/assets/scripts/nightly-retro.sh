#!/bin/sh
# nightly-retro: one coordinator closes the day across this city's switchyard
# projects. Which coordinator is a city decision (RETRO_AGENT in roster.conf);
# what it does is assets/prompts/nightly-retro.md.
set -u

. "$(dirname "$0")/../lib/roster.sh"

# Orders run once, at city scope. See sy_city_scope_only.
sy_city_scope_only
sy_load_conf

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
      -m "switchyard-ops' nightly-retro order is enabled but no RETRO_AGENT is set in this city's roster.conf, so no daily report was drafted. Set RETRO_AGENT=\"<rig>/<agent>\" in \$GC_PACK_STATE_DIR/roster.conf (see assets/roster.conf.example), or remove the nightly-retro order from your imports." >/dev/null 2>&1
    touch "$MARKER" 2>/dev/null
  fi
  exit 0
fi

gc session nudge "$RETRO_AGENT" "$(cat "$PROMPT")" >/dev/null 2>&1

exit 0
