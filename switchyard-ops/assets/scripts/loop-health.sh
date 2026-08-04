#!/bin/sh
# loop-health: pinned sessions are actually running AND the runtime probe answers.
# Escalates to the mayor via gc mail; never kills anything.
#
# Roster is RESOLVED, never hardcoded: reconciler pins (pool.min>=1) plus any
# singleton aliases the city declares in roster.conf, minus anything on a
# suspended rig. See assets/lib/roster.sh.
#
# Escalation policy: the two CHRONIC conditions — a slow probe, and a coordinator
# that stays absent — are each rate-limited to one mail per 24h. A 30m nag about
# a standing condition trains everyone to ignore mayor mail, at which point this
# order is worse than not existing. Probe failure + missing session still mails
# immediately, every cycle: that is the blind-reconciler-plus-down-agent
# combination that takes the loop out, and nothing else is left to notice it.
set -u

. "$(dirname "$0")/../lib/roster.sh"

MARKER="$(sy_state_dir)/loop-health.probe-alerted"
MISSING_MARKER="$(sy_state_dir)/loop-health.missing-alerted"

# Liveness is a LIVE PROCESS, checked against gc's dedicated tmux server (socket
# = city basename) at the session name gc itself recorded.
#
# It is NOT an argv grep, it is NOT a guessed pane-name prefix, and it is NOT
# `.state`. All three have been tried and all three are wrong:
#   * `ps ax` argv-grep — freshly spawned sessions embed the prompt in claude's
#     argv, but RESUMED/WOKEN sessions restart with only --session-id and no
#     marker, so an argv grep flags every once-woken coordinator as dead forever.
#   * guessed pane-name prefix — gc does not name a pane after the agent's base
#     name. `switchyard/gastown.witness` runs in a pane called
#     `switchyard--gastown__witness`, so matching `gastown.witness-` matched
#     NOTHING, for every agent, on every cycle. That is what produced 113 open
#     "nudged stopped coordinators" beads naming the same coordinators for 16
#     days while the city was healthy. Fixed by asking gc for `.session_name`
#     (sy_session_names_for) instead of predicting it, and matching it EXACTLY.
#   * `.state` — `asleep` is not "dead". It covers both an on_demand coordinator
#     idling with a healthy pane and a session whose pane is gone. Treating it as
#     dead would just trade a false-alarm storm for a respawn storm.
#
# One snapshot for the whole sweep, so every agent is judged against the same
# roster and a broken lookup is UNKNOWN for all of them rather than "missing"
# for all of them. Mass-respawning a healthy city because `gc session list`
# blipped is the one outcome worse than staying quiet.
roster_ok=1
sy_session_snapshot || roster_ok=0

roster="$(sy_roster)"
panes=$(tmux -L "$(sy_city_name)" list-panes -a -F '#{session_name} #{pane_pid}' 2>/dev/null)
# Same fail-safe as above, for the other half of the join: if the roster expects
# agents but tmux hands back nothing at all, that is a broken tmux lookup, not a
# city where every single coordinator died between two cycles. Report UNKNOWN.
[ -n "$roster" ] && [ -z "$panes" ] && roster_ok=0

missing=""
unknown=""
if [ "$roster_ok" -eq 1 ]; then
  for entry in $roster; do
    agent="$(sy_agent_of "$entry")"
    names="$(sy_session_names_for "$agent")"; rc=$?
    if [ "$rc" -ne 0 ]; then
      unknown="$unknown $agent"
      continue
    fi
    alive=0
    for sname in $names; do
      pid=$(printf '%s\n' "$panes" | awk -v s="$sname" '$1 == s { print $2; exit }')
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then alive=1; break; fi
    done
    [ "$alive" -eq 1 ] || missing="$missing $agent"
  done
fi

# Debounce mailing (NOT reviving): a coordinator missing for a SINGLE cycle is
# usually a transient reconcile blip — a restart respawns ~all pinned sessions at
# once and they return within a cycle. Revive every miss immediately (below), but
# only MAIL for agents missing across TWO consecutive checks, or a known reconcile
# trains the mayor to ignore loop-health. State: last cycle's misses.
#
# Debounce alone is NOT enough, and must not be mistaken for the fix to chronic
# noise: it suppresses a TRANSIENT miss, while a permanently-absent agent is in
# prev_missing every cycle and satisfies persist every cycle. That is why the
# suspended-rig filter (roster.sh) removes by-design absences from the roster
# outright, and why the mail below is additionally on a 24h cooldown.
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
# Only record a cycle we could actually measure. Writing an empty file after a
# failed lookup would clear prev_missing and reset the debounce, so a genuinely
# dead coordinator would need two more good cycles to be reported after every
# blip — and with a flapping lookup, never.
[ "$roster_ok" -eq 1 ] && printf '%s' "$missing" > "$LAST_MISSING" 2>/dev/null

probe_ok=1
sy_timeout 90 gc status >/dev/null 2>&1 || probe_ok=0
# A roster we cannot read is the same blindness the probe branch reports: we
# cannot tell live from dead. Fold it in rather than inventing a third alert
# with its own cooldown to tune.
{ [ "$roster_ok" -eq 0 ] || [ -n "$unknown" ]; } && probe_ok=0

# Revive what is genuinely absent.
#
# Do NOT nudge here. `gc session nudge` returns 0 for a session that is
# registered but dead — measured: it prints "Queued nudge for <id>" and exits 0
# with no pane behind it. So the old `nudge || wake || new` ladder stopped at
# the first rung and never reached `gc session new`, the only rung that can
# RECREATE a dead session. The ladder's own comment said `new` was the fallback
# for exactly this case; the `||` chain just never got there.
#
# Nudging is pointless anyway: we only reach this loop because the agent has no
# ACTIVE session, so there is nothing awake to read the prompt.
#
# Passing the agent's qualified name to nudge/wake was a second bug in the same
# three lines — those resolve a SESSION id-or-alias, a different namespace
# (roster.sh documents this). `gc session wake switchyard/gastown.polecat` exits
# 1 "session not found" even with that agent running, because its session is
# aliased `switchyard/gastown.furiosa`. Resolve the alias, then wake it.
for agent in $missing; do
  # Any state, not just active: a registered-but-asleep session has no pane (so
  # it is correctly missing) yet is still a real id that `wake` can restart.
  # `new` on an agent that already has one would be the wrong verb.
  target="$(sy_session_alias_for "$agent")"; rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$target" ]; then
    gc session wake "$target" >/dev/null 2>&1 \
      || gc session new "$agent" --no-attach >/dev/null 2>&1
  else
    # pool.min=0 singletons have no reconciler respawn, so on death they stay
    # dead and nothing but `new` brings them back. max_active_sessions=1
    # prevents duplicates, and `new` can take >30s (non-zero on attach timeout
    # even when it ultimately starts) — fine, the next cycle sees it alive.
    gc session new "$agent" --no-attach >/dev/null 2>&1
  fi
done

mkdir -p "$(dirname "$MARKER")" 2>/dev/null

# sy_recently_alerted MARKER — true when MARKER was touched within 24h.
sy_recently_alerted() {
  [ -f "$1" ] && [ -z "$(find "$1" -mmin +1440 2>/dev/null)" ]
}

recently_alerted=0
sy_recently_alerted "$MARKER" && recently_alerted=1
missing_recently_alerted=0
sy_recently_alerted "$MISSING_MARKER" && missing_recently_alerted=1

unknown_note=""
[ -n "$unknown" ] && unknown_note="

Liveness could not be resolved for:$unknown — treated as UNKNOWN, not missing, and not respawned."
[ "$roster_ok" -eq 0 ] && unknown_note="

The session roster could not be read at all this cycle, so NO agent's liveness was checked and nothing was respawned."

# This branch alone still mails EVERY cycle, deliberately and unchanged: probe
# down AND a coordinator down is the combination that takes the loop out, and
# nothing in the city is left to notice it. It is safe to leave uncapped now
# that the roster no longer manufactures phantom absences — reaching it takes a
# real failed probe AND a real agent missing twice running.
if [ "$probe_ok" -eq 0 ] && [ -n "$persist" ]; then
  gc mail send mayor -s "ESCALATION loop-health: probe down AND pinned sessions missing" -m "The runtime status probe did not answer within 90s AND these pinned sessions had no live session for two consecutive checks:$persist. This is the blind-reconciler failure mode: nothing can wake anything, because everything reads the probe. Sessions were woken or recreated; verify, and consider a supervisor bounce if the reconciler does not converge. Agents on suspended rigs are excluded from this roster.$unknown_note" >/dev/null 2>&1
  touch "$MARKER" 2>/dev/null
  touch "$MISSING_MARKER" 2>/dev/null
elif [ "$probe_ok" -eq 0 ] && [ "$recently_alerted" -eq 0 ]; then
  gc mail send mayor -s "loop-health: runtime status probe slow/failing (daily notice)" -m "gc status did not answer within 90s, or the session roster could not be read. No pinned session was found missing, so this is the chronic slow-probe condition, not an outage. This notice repeats at most once per 24h.$unknown_note" >/dev/null 2>&1
  touch "$MARKER" 2>/dev/null
elif [ -n "$persist" ] && [ "$missing_recently_alerted" -eq 0 ]; then
  # Same 24h cooldown the probe branch has always had. A chronically absent
  # coordinator is exactly as fatiguing as a chronically slow probe, and the
  # marker mechanism was already sitting in this file unused by this branch.
  gc mail send mayor -s "loop-health: revived stopped coordinators" -m "These pinned sessions had no live session across two consecutive checks and were woken or recreated:$persist. Agents on suspended rigs are excluded from this roster, so these are genuine absences. This notice repeats at most once per 24h.$unknown_note" >/dev/null 2>&1
  touch "$MISSING_MARKER" 2>/dev/null
fi

exit 0
