#!/bin/sh
# stray-reaper: find sessions labeled for THIS city whose GC_CITY points
# somewhere else — the signature of a relocated or duplicated city root, where
# a session keeps writing to the old path. Report, don't kill.
set -u

. "$(dirname "$0")/../lib/roster.sh"

CITY="$(sy_city)"
CITY_NAME="$(sy_city_name)"

# Match on the city NAME (which appears in GC_SESSION_NAME) but exclude the
# processes whose GC_CITY is this exact path. A session named for this city and
# rooted elsewhere is, by definition, a stray.
strays="$(ps axeww -o command 2>/dev/null \
  | grep -F 'GC_SESSION_NAME=' \
  | grep -F "$CITY_NAME" \
  | grep -v grep \
  | grep -vF "GC_CITY=$CITY" \
  | sed -E 's/.*GC_SESSION_NAME=([^ ]+).*/\1/' \
  | sort -u)"

if [ -n "$strays" ]; then
  gc mail send mayor -s "stray-reaper: sessions running outside $CITY" -m "These sessions are labeled '$CITY_NAME' but their GC_CITY is not $CITY (usually leftovers from a moved or duplicated city root — they read and write the WRONG store). Review and kill their tmux sessions if obsolete:
$strays" >/dev/null 2>&1
fi

exit 0
