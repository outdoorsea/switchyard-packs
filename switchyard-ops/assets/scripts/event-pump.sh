#!/bin/sh
# event-pump: the pack-native event bridge (see orders/event-pump.toml for the
# why and the kind→order map; this header covers the mechanics).
#
# THE PUMP ROUTES, IT NEVER WORKS. Each cycle drains the project's SSE event
# stream for a bounded window, maps every new event's kind onto the pack order
# that owns that class, and runs each mapped order AT MOST ONCE per cycle
# (three questions in one window wake answer-sweep once — the sweep drains its
# own queue). The work, the judgment and the spawning all stay in the orders it
# triggers.
#
# CURSOR SEMANTICS. `Last-Event-ID` resumes the stream strictly after the last
# event this pump processed; the cursor file advances after a drain whether or
# not the triggered orders succeeded, because every mapped order is ALSO on its
# own cooldown — the sweep cadence is the delivery guarantee, the pump is only
# the latency cut. A cursor that refused to advance on a failed `gc order run`
# would re-trigger the same failing order every minute forever, which is a
# tight loop on a fault the cooldown would have retried anyway.
#
# THE DRAIN WINDOW IS A TIMEOUT, NOT AN ERROR. SSE is an endless stream, so the
# curl is ALWAYS cut by --max-time on a healthy read (curl exit 28) — output
# plus exit 28 is the normal shape of a successful drain. A refused stream
# (HTTP error under -f, or connect failure) yields no output and a different
# exit, which mails ONCE per standing fault: silence would read as a quiet
# feed, and the difference between "no events" and "nobody subscribed" is
# exactly what the companion-required row this replaces was about.
set -u

. "$(dirname "$0")/../lib/roster.sh"
. "$(dirname "$0")/../lib/switchyard-api.sh"

sy_load_conf

# Opt-in rig list; unset = the bridge is off everywhere.
EVENT_PUMP_RIGS="${EVENT_PUMP_RIGS:-}"
# Seconds each cycle spends draining the stream. The floor of the wake latency
# win, and the ceiling of the cycle's cost; the stream flushes its backlog
# immediately on connect, so a short window still drains a long queue.
EVENT_PUMP_DRAIN_SECONDS="${EVENT_PUMP_DRAIN_SECONDS:-8}"

command -v jq >/dev/null 2>&1 || exit 0
[ -n "$EVENT_PUMP_RIGS" ] || exit 0

token="$(sy_api_token)"
[ -n "$token" ] || exit 0
projects="$(sy_api_projects "$token")"
[ -n "$projects" ] || exit 0

state="$(sy_state_dir)"
mkdir -p "$state" 2>/dev/null || exit 0

ep_mail_once() { # KEY SUBJECT BODY
  _mk="$state/event-pump.alert.$1"
  [ -f "$_mk" ] && return 0
  gc mail send mayor --subject "$2" --body "$3" >/dev/null 2>&1 && : >"$_mk" 2>/dev/null || true
}

# ep_order_for KIND — the order owning an event kind, or empty. ONE mapping,
# mirrored from the companion watcher's classifier (classifyEvent in
# internal/companion/watch_hooks.go); keep the two in sync when a class is
# added.
ep_order_for() {
  case "$1" in
    prd.dispatched|prd.approved) printf 'pool-spawn' ;;
    prd.question_asked)          printf 'answer-sweep' ;;
    idea.imported)               printf 'intake-triage-sweep' ;;
    prd.build_ready)             printf 'validate-sweep' ;;
    deploy.reported)             printf 'golden-journey-sweep' ;;
    *) printf '' ;;
  esac
}

for rig in $EVENT_PUMP_RIGS; do
  project="$(sy_project_for_rig "$rig" "$projects")"
  if [ -z "$project" ]; then
    ep_mail_once "scope-$rig" \
      "event-pump: rig $rig resolves to no project" \
      "EVENT_PUMP_RIGS names '$rig' but sy_project_for_rig resolved nothing. Check RIG_PROJECTS in roster.conf. The bridge is dark for it; the cooldown sweeps still run."
    continue
  fi

  cursor_file="$state/event-pump.cursor.$rig"
  cursor="$(cat "$cursor_file" 2>/dev/null | tr -cd '0-9')"

  # Drain. The token rides a curl config on stdin (never argv); Last-Event-ID
  # is not a credential and may be a plain header. A healthy drain is output +
  # exit 28 (the window closing); see header.
  raw_file="$state/event-pump.raw.$$"
  {
    printf 'header = "Authorization: Bearer %s"\n' "$token"
    [ -n "$cursor" ] && printf 'header = "Last-Event-ID: %s"\n' "$cursor"
  } | curl -fsS --no-buffer --config - \
        --connect-timeout "$SY_API_CONNECT_TIMEOUT" \
        --max-time "$EVENT_PUMP_DRAIN_SECONDS" \
        "$(sy_api_base)/api/v1/projects/$project/events" >"$raw_file" 2>/dev/null
  rc=$?
  if [ ! -s "$raw_file" ] && [ "$rc" -ne 28 ] && [ "$rc" -ne 0 ]; then
    rm -f "$raw_file" 2>/dev/null
    ep_mail_once "stream-$rig" \
      "event-pump: event stream unreadable for $rig" \
      "GET /projects/$project/events failed (curl exit $rc) with no output — a refused subscription, not a quiet feed. The bridge is dark for $rig; the cooldown sweeps still run. Check the token and the base URL."
    continue
  fi
  rm -f "$state/event-pump.alert.stream-$rig" "$state/event-pump.alert.scope-$rig" 2>/dev/null

  # Parse the SSE frames: remember the last `id:`, collect each `data:` line's
  # kind. Comment lines (`: …`) and anything malformed fall out at the jq step.
  last_id="$(awk '/^id: /{v=$2} END{if (v != "") print v}' "$raw_file" | tr -cd '0-9')"
  kinds="$(sed -n 's/^data: //p' "$raw_file" | jq -r '.kind // empty' 2>/dev/null | sort -u)"
  rm -f "$raw_file" 2>/dev/null

  # Map kinds → orders, dedup, run each once. `gc order run` executes the
  # order's own script under the city, exactly as its cooldown tick would.
  orders=""
  for kind in $kinds; do
    o="$(ep_order_for "$kind")"
    [ -n "$o" ] || continue
    case " $orders " in *" $o "*) ;; *) orders="$orders $o" ;; esac
  done
  for o in $orders; do
    if gc order run "$o" >/dev/null 2>&1; then
      echo "event-pump: $rig -> ran $o early"
    else
      echo "event-pump: $rig -> $o refused (its cooldown remains the safety net)"
    fi
  done

  # Advance the cursor past everything drained (see header for why this is
  # unconditional once the drain itself succeeded).
  [ -n "$last_id" ] && printf '%s' "$last_id" >"$cursor_file" 2>/dev/null
done
exit 0
