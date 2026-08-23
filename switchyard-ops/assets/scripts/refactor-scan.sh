#!/bin/sh
# refactor-scan: start one refactor-scout per rig — but only for a rig whose
# repo has actually moved since that rig was last scanned.
#
# WHY THIS SCRIPT EXISTS AT ALL, given refactor-scan-gate.sh already gates this
# same predicate. That gate runs INSIDE the session, as the scout's own first
# action, and that placement is right for the reason its header gives: the lane
# is also started by the reconciler's revive loop, which never reads this order,
# so a gate only this order evaluated would miss most spawns. What it cannot do
# is make a no-demand pass free. The session still starts, loads a prompt, reads
# the gate and exits — a full session's tokens spent to answer "nothing changed".
#
# So the two gates are complements, not duplicates, and they are deliberately
# keyed on separate markers:
#
#   HERE (pre-spawn)   "has this rig moved since I last SPAWNED for it?"
#                      Decides whether a session is worth starting. Costs a
#                      marker read.
#   refactor-scan-gate "has this rig moved since I last SCANNED it?"
#                      Decides whether a session that already exists — however
#                      it was started — should do the work. Costs a session.
#
# A shared marker would make the second gate unreachable through this path (the
# first stamps it, so the scout would always see its own sha and skip), which
# would silently disable the revive-loop coverage that is the whole reason the
# in-session gate was put there. Separate markers keep each gate answering the
# question it was written for.
#
# The demand predicate itself is sy_demand_sha_moved — shared with security-scan
# so the two scanners cannot drift apart. It FAILS OPEN: a repo whose HEAD
# cannot be read is scanned rather than skipped. See lib/demand.sh.
#
# A skipped rig is a LOGGED no-op: it says which rig and why on stdout, and
# starts nothing. Zero tokens.
set -u

. "$(dirname "$0")/../lib/roster.sh"
. "$(dirname "$0")/../lib/demand.sh"
sy_load_conf

AGENT="refactor-scout"
QUALIFIED="$SY_NS.$AGENT"

# The lane's own rig set, derived exactly as lane-ensure.sh derives it — same
# helper, so the gate cannot judge a different set of rigs than the spawner
# visits. An empty set is not an error: a city that never imported this lane has
# nothing to gate and nothing to spawn.
rigs="$(sy_lane_rigs "$QUALIFIED")"
[ -n "$rigs" ] || exit 0

# Partition the rig set on demand. The survivors reach lane-ensure through
# LANE_RIGS_FILTER — the *_RIGS allowlist idiom every sibling lane switch uses,
# and the same mechanism security-scan.sh uses to scope its own walk. A rig not
# on the filter is out of the lane's scope for this cycle entirely: no spawn, no
# reap, no escalation.
wanted=""
for rig in $rigs; do
  repo="$(sy_rig_root "$rig")"
  if sha="$(sy_demand_sha_moved "refactor-scan.$rig" "$repo")"; then
    wanted="$wanted $rig"
  else
    echo "refactor-scan: $rig unchanged at $sha since its last scan — skipping, no session started."
  fi
done

# Every rig quiet: the whole cycle is a no-op, said out loud. This line is the
# difference between a lane that is deliberately idle and a lane that is broken,
# and those look identical in a log that prints nothing.
if [ -z "$wanted" ]; then
  echo "refactor-scan: no rig has moved since its last scan — no session started."
  exit 0
fi

LANE_RIGS_FILTER="$(printf '%s' "$wanted" | sed 's/^ *//')"
export LANE_RIGS_FILTER

exec "$(dirname "$0")/lane-ensure.sh" refactor-scout "refactor scout"
