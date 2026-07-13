#!/bin/sh
# disk-watch: turn silent disk growth into mayor mail (the loop invariant). gc
# ships on-demand doctor checks for these paths but nothing SCHEDULES them, so a
# rig worktree or backup dir can bloat for days unseen. Report-only; mails at most
# once per 24h (like config-drift) so a chronic-but-known size does not nag.
#
# Thresholds (MB, env-tunable via roster.conf):
#   DISK_WATCH_WORKTREE_MB   per rig worktree     (default 10000 = 10 GB; gc-doctor warn)
#   DISK_WATCH_BACKUP_MB     .dolt-backup total   (default 5000)
#   DISK_WATCH_GC_MB         .gc total            (default 20000)
#   DISK_WATCH_EVENTS_MB     .gc/events.jsonl     (default 200; events-rotate caps ~100)
set -u

. "$(dirname "$0")/../lib/roster.sh"
sy_load_conf

CITY="$(sy_city)"
MARKER="$(sy_state_dir)/disk-watch.alerted"

WT_MB="${DISK_WATCH_WORKTREE_MB:-10000}"
BK_MB="${DISK_WATCH_BACKUP_MB:-5000}"
GC_MB="${DISK_WATCH_GC_MB:-20000}"
EV_MB="${DISK_WATCH_EVENTS_MB:-200}"

cd "$CITY" 2>/dev/null || exit 0

breaches=""
add() { breaches="$breaches
- $1: ${2} MB (threshold ${3} MB)"; }
dush() { du -sm "$1" 2>/dev/null | awk '{print $1}'; }   # size in MB (empty if absent)

# rig worktrees: a root dir with a .git (same signature scratch-reaper excludes)
for entry in */; do
  d="${entry%/}"
  [ -e "$d/.git" ] || continue
  sz=$(dush "$d"); [ -n "$sz" ] && [ "$sz" -ge "$WT_MB" ] && add "rig worktree $d" "$sz" "$WT_MB"
done

[ -d .dolt-backup ] && { sz=$(dush .dolt-backup); [ -n "$sz" ] && [ "$sz" -ge "$BK_MB" ] && add ".dolt-backup" "$sz" "$BK_MB"; }
[ -d .gc ] && { sz=$(dush .gc); [ -n "$sz" ] && [ "$sz" -ge "$GC_MB" ] && add ".gc" "$sz" "$GC_MB"; }
[ -f .gc/events.jsonl ] && { sz=$(( $(wc -c < .gc/events.jsonl) / 1048576 )); [ "$sz" -ge "$EV_MB" ] && add ".gc/events.jsonl" "$sz" "$EV_MB"; }

[ -z "$breaches" ] && exit 0

# once-per-24h gate
mkdir -p "$(dirname "$MARKER")" 2>/dev/null
if [ -f "$MARKER" ] && [ -z "$(find "$MARKER" -mmin +1440 2>/dev/null)" ]; then
  exit 0
fi

gc mail send mayor -s "disk-watch: city paths over threshold" -m "These city paths crossed their size thresholds (daily notice). Investigate the growth or raise the threshold in roster.conf:$breaches" >/dev/null 2>&1
touch "$MARKER" 2>/dev/null
exit 0
