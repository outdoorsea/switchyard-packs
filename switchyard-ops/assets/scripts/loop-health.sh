#!/bin/sh
# loop-health: pinned sessions have live processes AND the runtime probe answers.
# Escalates to the mayor via gc mail; never kills anything.
#
# Roster is RESOLVED, never hardcoded: reconciler pins (pool.min>=1) plus any
# singleton aliases the city declares in roster.conf. See assets/lib/roster.sh.
#
# Escalation policy: a missing pinned session always mails. A slow/failing probe
# alone mails at most once per 24h — a chronically slow probe plus a 30m nag
# trains everyone to ignore mayor mail. Probe failure + missing session mails
# immediately: that is the blind-reconciler-plus-down-agent combination that
# takes the loop out.
set -u

. "$(dirname "$0")/../lib/roster.sh"

CITY_NAME="$(sy_city_name)"
MARKER="$(sy_state_dir)/loop-health.probe-alerted"

# Liveness is checked against gc's dedicated tmux server (socket = city
# basename), NOT `ps ax` argv-grep: freshly spawned sessions embed the prompt in
# claude's argv, but RESUMED/WOKEN sessions restart with only --session-id and no
# marker — so an argv grep flags every once-woken coordinator as dead forever.
panes=$(tmux -L "$CITY_NAME" list-panes -a -F '#{session_name} #{pane_pid}' 2>/dev/null)

missing=""
for entry in $(sy_roster); do
  agent="$(sy_agent_of "$entry")"
  prefix="$(sy_prefix_of "$entry")"
  pid=$(printf '%s\n' "$panes" | awk -v p="$prefix-" 'index($1, p) == 1 { print $2; exit }')
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    missing="$missing $agent"
  fi
done

# Debounce mailing (NOT nudging): a coordinator missing for a SINGLE cycle is
# usually a transient reconcile blip — a restart respawns ~all pinned sessions at
# once and they return within a cycle. Nudge every miss immediately (below), but
# only MAIL for agents missing across TWO consecutive checks, or a known reconcile
# trains the mayor to ignore loop-health. State: last cycle's misses.
LAST_MISSING="$(sy_state_dir)/loop-health.missing-last"
prev_missing=""
[ -f "$LAST_MISSING" ] && prev_missing="$(cat "$LAST_MISSING" 2>/dev/null)"
persist=""
for a in $missing; do
  for b in $prev_missing; do
    [ "$a" = "$b" ] && persist="$persist $a" && break
  done
done
mkdir -p "$(dirname "$LAST_MISSING")" 2>/dev/null
printf '%s' "$missing" > "$LAST_MISSING" 2>/dev/null

probe_ok=1
sy_timeout 90 gc status >/dev/null 2>&1 || probe_ok=0

if [ -n "$missing" ]; then
  for agent in $missing; do
    # nudge/wake revive an existing-but-asleep session; neither can RECREATE a
    # fully-dead one (they error "session not found"). pool.min=0 singletons have
    # no reconciler respawn, so on death they stay dead and this check escalates
    # forever. Fall back to `gc session new` to actually recreate them.
    # max_active_sessions=1 prevents duplicates, and `new` can take >30s
    # (non-zero on attach timeout even when it ultimately starts) — fine, the
    # next cycle sees it alive.
    gc session nudge "$agent" "loop-health: your session was not running; resuming the loop. Run gc prime, check mail, continue your coordinator loop." >/dev/null 2>&1 \
      || gc session wake "$agent" >/dev/null 2>&1 \
      || gc session new "$agent" --no-attach >/dev/null 2>&1
  done
fi

mkdir -p "$(dirname "$MARKER")" 2>/dev/null

recently_alerted=0
if [ -f "$MARKER" ] && [ -z "$(find "$MARKER" -mmin +1440 2>/dev/null)" ]; then
  recently_alerted=1
fi

if [ "$probe_ok" -eq 0 ] && [ -n "$persist" ]; then
  gc mail send mayor -s "ESCALATION loop-health: probe down AND pinned sessions missing" -m "The runtime status probe did not answer within 90s AND these pinned sessions had no live process for two consecutive checks:$persist. This is the blind-reconciler failure mode: nothing can wake anything, because everything reads the probe. Sessions were nudged/woken; verify, and consider a supervisor bounce if the reconciler does not converge." >/dev/null 2>&1
  touch "$MARKER" 2>/dev/null
elif [ "$probe_ok" -eq 0 ] && [ "$recently_alerted" -eq 0 ]; then
  gc mail send mayor -s "loop-health: runtime status probe slow/failing (daily notice)" -m "gc status did not answer within 90s. All pinned sessions have live processes, so this is the chronic slow-probe condition, not an outage. This notice repeats at most once per 24h." >/dev/null 2>&1
  touch "$MARKER" 2>/dev/null
elif [ -n "$persist" ]; then
  gc mail send mayor -s "loop-health: nudged stopped coordinators" -m "These pinned sessions had no live process across two consecutive checks and were nudged awake:$persist" >/dev/null 2>&1
fi

exit 0
