#!/bin/sh
# events-rotate: cap gc's append-only telemetry log, .gc/events.jsonl, to a
# recent tail. gc ships no retention for this file and holds it with a live
# O_APPEND fd, so it grows unbounded (~48 MB/day observed).
#
# Truncate-only: keep the last KEEP_LINES, drop older. The rewrite is IN-PLACE
# (`> "$LOG"` truncates the SAME inode gc's fd points at, then we write the tail
# back). A rename would strand gc's fd on the unlinked old file and silently
# lose events until gc restarts — so never mv, always copy-truncate. A sub-second
# race where gc appends during the rewrite can clobber a handful of telemetry
# lines; immaterial for a log gc never replays.
#
# Silent on success; mails the mayor on any anomaly (the pack invariant).
set -u

. "$(dirname "$0")/../lib/roster.sh"

CITY="$(sy_city)"
LOG="$CITY/.gc/events.jsonl"

MAX_MB="${EVENTS_ROTATE_MAX_MB:-100}"
KEEP_LINES="${EVENTS_ROTATE_KEEP_LINES:-30000}"

[ -f "$LOG" ] || exit 0

# Cheap size gate — below the cap, do nothing (don't rewrite a healthy file).
size_mb=$(( $(wc -c < "$LOG") / 1048576 ))
[ "$size_mb" -lt "$MAX_MB" ] && exit 0

lines=$(wc -l < "$LOG")
if [ "$lines" -le "$KEEP_LINES" ]; then
  # Over the cap but fewer lines than we'd keep => unusually large events.
  # Truncating would keep everything and reduce nothing, so surface instead.
  gc mail send mayor \
    -s "events-rotate: $LOG is ${size_mb}MB in only ${lines} lines" \
    -m "The gc event log exceeds ${MAX_MB}MB but has <= KEEP_LINES=${KEEP_LINES} lines — oversized events. Not truncating (would keep everything). Investigate what is emitting large events: tail -c 4096 '$LOG'." \
    >/dev/null 2>&1
  exit 0
fi

tmp="$(mktemp "${TMPDIR:-/tmp}/events-rotate.XXXXXX")" || {
  gc mail send mayor \
    -s "events-rotate: mktemp failed" \
    -m "Could not create a temp file to rotate $LOG (currently ${size_mb}MB). The gc event log is NOT being capped and will keep growing." \
    >/dev/null 2>&1
  exit 1
}
trap 'rm -f "$tmp"' EXIT

tail -n "$KEEP_LINES" "$LOG" > "$tmp" && cat "$tmp" > "$LOG"
rc=$?

new_mb=$(( $(wc -c < "$LOG") / 1048576 ))
if [ "$rc" -ne 0 ] || [ "$new_mb" -ge "$MAX_MB" ]; then
  gc mail send mayor \
    -s "events-rotate: truncation did not shrink $LOG" \
    -m "Tried to cap the gc event log to the last ${KEEP_LINES} lines but it is still ${new_mb}MB (was ${size_mb}MB, rc=${rc}). A non-append writer or a sparse-hole rewrite may be at fault — inspect: lsof '$LOG'." \
    >/dev/null 2>&1
  exit 1
fi

exit 0
