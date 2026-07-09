#!/bin/sh
# intake-sweep: wake each coordinator into a triage pass over its switchyard
# project. Judgment lives in the session, not here — this script only decides
# WHO to nudge; assets/prompts/intake-sweep.md decides WHAT they do.
set -u

. "$(dirname "$0")/../lib/roster.sh"

PROMPT="$(dirname "$0")/../prompts/intake-sweep.md"
[ -r "$PROMPT" ] || exit 0
MSG="$(cat "$PROMPT")"

nudged=0
for agent in $(sy_coordinators); do
  gc session nudge "$agent" "$MSG" >/dev/null 2>&1 && nudged=$((nudged + 1))
done

# A city with no coordinators is a legitimate state (all rigs suspended, or a
# fresh city). Say nothing — silence is the correct output for an idle city.
[ "$nudged" -eq 0 ] && exit 0

exit 0
