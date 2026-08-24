#!/bin/sh
# zombie-sweep: close sessions that registered but never started.
#
# THE FAILURE
#
# gc creates a session, writes it to the registry as state="active", and the
# runtime never comes up. The session never executes a single turn, so
# `last_active` is never stamped and keeps Go's zero time (0001-01-01). Every
# health surface reads it as a healthy active session: `gc status` counts it,
# the reconciler sees the lane staffed and does not respawn, and the scaler
# counts it against max_active_sessions. A scaled lane at max=1 is then sealed
# by one zombie; at max=4 it fills with four of them.
#
# This is the fifth member of the silent-stall family, after publish-gate (work
# closed with no PR), pr-gate (PR opened and never merged), pane-stall (input
# never submitted) and frozen-session-sweep (turn died at a terminal API
# error). Same signature as all four: a condition every existing surface reads
# as fine.
#
# WHY IT IS A CLOSE, NOT A NUDGE — the distinction from frozen-session-sweep
#
# A FROZEN session holds recoverable context and a live runtime: it resumes
# where it stopped when re-prompted, so its remedy is a nudge and killing it
# would destroy work. A ZOMBIE has neither. There is no runtime listening, so
# a nudge types into nothing; there is no context, because no turn ever ran.
# Nothing is lost by closing it, and until it IS closed the lane stays
# unstaffed. This is also why no prompt-side instruction can fix this class:
# an agent told to "close your session when finished" never reaches its
# prompt, so the instruction never executes.
#
# Observed 2026-08-23 on this city: 8 of 8 sessions on the acp transport were
# zombies while 0 of 33 on the default transport were, one per judge and
# security-scout lane across four rigs, regenerating within 90 seconds of
# being closed by hand. The judging lane had been sealed since 08-20 and the
# callboard's delivered criteria sat unvalidated behind it. The provider
# itself was healthy in isolation (binary on PATH, credential loaded, protocol
# handshake correct, a live completion returned) — the fault was in the
# session wiring, which is exactly the kind of cause no single lane can see
# and a recurrence count across lanes makes obvious.
#
# THE GRACE PERIOD IS LOAD-BEARING
#
# A healthy session is briefly indistinguishable from a zombie: between
# registration and its first stamped activity it also reads active with a zero
# last_active. Closing on that window would reap healthy newborns and look
# exactly like flapping. So a session is only a zombie once it has held the
# zero stamp for ZOMBIE_GRACE_SECONDS (default 600 — generous; observed
# healthy sessions stamp within seconds, observed zombies held it for hours).
#
# JURISDICTION — what this sweep deliberately does NOT touch:
#
#   * ASLEEP/drained sessions with a zero last_active. Those are sessions that
#     were never used and then drained normally; they hold no slot and count
#     as zero WIP, so closing them buys nothing and would churn the registry.
#   * Any session that has EVER stamped last_active. A session that ran and
#     then stalled is frozen-session-sweep's or pane-stall's finding, and its
#     remedy is a nudge, not a close.
#
# RECURRENCE IS THE REAL SIGNAL
#
# Closing zombies is janitorial: it frees the slot but does not fix whatever
# prevents the runtime from starting, and a broken lane simply respawns one
# next cycle. So the sweep counts closures per agent TEMPLATE across passes and
# mails the mayor ONCE when a template crosses ZOMBIE_RECUR_CAP (default 10).
# A single zombie is noise; one template producing ten is a misconfigured lane,
# and that mail is the only place that pattern is visible — no per-session
# surface can show it.
set -u

. "$(dirname "$0")/../lib/roster.sh"

sy_load_conf

STATE="$(sy_state_dir)/zombie-sweep.counts"
STATE_DIR="$(dirname "$STATE")"
GRACE="${ZOMBIE_GRACE_SECONDS:-600}"
RECUR_CAP="${ZOMBIE_RECUR_CAP:-10}"

# Fail closed if we cannot read or persist state: a sweep that cannot record
# its counts must not erase existing counters or re-fire escalations that
# already went out.
if ! mkdir -p "$STATE_DIR" 2>/dev/null || [ ! -w "$STATE_DIR" ]; then
  exit 0
fi
if [ ! -f "$STATE" ]; then
  : > "$STATE" 2>/dev/null || exit 0
fi
[ -r "$STATE" ] && [ -w "$STATE" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

ZOMBIES="$(mktemp "${TMPDIR:-/tmp}/sy-zombie-list.XXXXXX" 2>/dev/null)" || exit 0

# One read of the registry. A failed or unparseable read exits without
# touching state — an unobserved pass must never be mistaken for "no zombies",
# which would reset counters and re-arm escalations.
if ! gc session list --json --state all 2>/dev/null \
  | jq -r --argjson grace "$GRACE" '
      .sessions[]
      | select(.state == "active")
      | select((.last_active | tostring) | startswith("0001-01-01"))
      | select(.created_at != null
               and ((now - (.created_at | fromdateiso8601)) > $grace))
      | "\(.id)\t\(.template // "unknown")\t\(.name)"' >"$ZOMBIES" 2>/dev/null
then
  rm -f "$ZOMBIES"
  exit 0
fi

closed=0
closed_list=""
while IFS="$(printf '\t')" read -r id template name; do
  [ -n "$id" ] || continue
  if gc session close "$id" >/dev/null 2>&1; then
    closed=$((closed + 1))
    closed_list="$closed_list
  $name [$template]"
    # Count this closure against its template.
    prev="$(awk -F'\t' -v k="$template" '$1 == k { print $2 }' "$STATE" 2>/dev/null | head -1)"
    case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
    new=$((prev + 1))
    tmp="$(mktemp "$STATE_DIR/.sy-zombie-state.XXXXXX" 2>/dev/null)" || continue
    awk -F'\t' -v k="$template" '$1 != k' "$STATE" > "$tmp" 2>/dev/null
    printf '%s\t%s\n' "$template" "$new" >> "$tmp"
    mv -f "$tmp" "$STATE" 2>/dev/null || rm -f "$tmp"

    # Escalate exactly once, on the pass that crosses the cap.
    if [ "$new" -eq "$RECUR_CAP" ]; then
      gc mail send mayor \
        -s "zombie-sweep: $template keeps spawning sessions that never start" \
        -m "The agent template $template has now produced $RECUR_CAP sessions that registered as active and never executed a single turn. Each was closed by this sweep, but closing is janitorial — something is preventing this lane's runtime from starting, and it will keep respawning.

A zombie reads healthy on every surface (gc status counts it, the reconciler sees the lane staffed, the scaler counts it against max_active_sessions), so this lane may have been effectively unstaffed the entire time.

Check, in this order:
  1. The provider this template resolves to, in city.toml's [[patches.agent]] blocks — NOT roster.conf's *_PROVIDER keys, which only drive readiness gates and do not set the spawned provider.
  2. Whether that provider's runtime actually starts by hand outside gc. A provider can be entirely healthy in isolation (binary present, credential loaded, protocol handshake fine) and still fail through the session wiring.
  3. The transport. Zombies clustering on one transport while other lanes on the same host are fine points at the transport, not the model.

This is reported once per template. The counter keeps rising and is visible in $STATE." >/dev/null 2>&1
    fi
  fi
done < "$ZOMBIES"
rm -f "$ZOMBIES"

exit 0
