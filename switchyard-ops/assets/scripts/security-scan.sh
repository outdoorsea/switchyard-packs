#!/bin/sh
# security-scan: start one security-scout per rig — but only once the lane's
# provider is actually usable.
#
# WHY THIS ISN'T JUST lane-ensure.sh. The security-scout runs on a non-default
# provider (deepseek). If the provider is unregistered or its CLI is missing, a bare
# lane-ensure would spawn a session every cycle that dies on startup: a spawn-fail
# loop that either burns the pool's name slots silently or mails the mayor a
# false "spawn returned no identity" every 12 hours. Neither is a true report of
# what is wrong, which is simply "deepseek is not set up yet".
#
# So: check the three prerequisites, and when they are unmet, say so ONCE (a
# 7-day marker) and stay quiet. An unconfigured lane is a known posture, not an
# incident. When they are met, hand off to the normal rig spawner.
#
# Prerequisites checked:
#   1. the provider is registered in the resolved city config
#   2. its CLI is on PATH (the resolved BINARY — a wrapped provider like
#      deepseek -> builtin:opencode spawns `opencode`, not `deepseek`)
#   3. an API key is present in the environment (skipped for wrapped
#      providers, whose wrapper CLI holds its own credential store)
#
# KNOWN GAP, stated rather than implied: this lane has NO spawn-readiness probe
# (that lives in judge-sweep.sh, which also tests the CLI's answer for an auth
# refusal). So for a WRAPPED provider — the shipped default, deepseek via
# opencode — check 3 is skipped and nothing here notices an installed-but-
# unauthenticated wrapper: it passes the gate, lane-ensure spawns, the session
# dies at startup and the mayor gets the generic "did not come up" load notice.
# The lane is opt-in (SECURITY_SCAN_RIGS), so this is bounded to cities that
# switch it on; closing it means giving this script the same probe.
#
# Override the provider expectation via roster.conf when running the lane on the
# default provider (see agents/security-scout/agent.toml):
#   SECURITY_SCOUT_PROVIDER="claude"
set -u

. "$(dirname "$0")/../lib/roster.sh"
. "$(dirname "$0")/../lib/demand.sh"
sy_load_conf

# OPT-IN PER RIG, the *_RIGS roster idiom every sibling lane switch uses
# (MERGE_LANE_RIGS, CONDUCTOR_RIGS, REVIEW_LANE_RIGS, ...): unset means off
# for the whole city, silently — no spawn, no marker, no mail. The lane used
# to be on-by-default, which meant a city that never configured the provider received
# a "lane idle" notice every week forever: an error posture for what is
# really an operator choice. The list is honored per rig for real, not as a
# boolean: it reaches lane-ensure's rig walk as LANE_RIGS_FILTER, so a rig
# not named here is out of the lane's scope entirely.
SECURITY_SCAN_RIGS="${SECURITY_SCAN_RIGS:-}"
[ -n "$SECURITY_SCAN_RIGS" ] || exit 0
LANE_RIGS_FILTER="$SECURITY_SCAN_RIGS"
export LANE_RIGS_FILTER

PROVIDER="${SECURITY_SCOUT_PROVIDER:-deepseek}"
BIN="$(sy_provider_bin "$PROVIDER")"
# An UNREGISTERED provider has no base chain to follow, so sy_provider_bin falls
# back to the provider's own NAME and every message built from $BIN then names a
# binary that cannot exist (see the same guard in judge-sweep.sh). The pack's own
# default wrap is spelled here so the unregistered case reads like the registered
# one; a city that wraps deepseek differently still wins on its resolved config.
if [ "$PROVIDER" = "deepseek" ] && [ "$BIN" = "$PROVIDER" ]; then
  BIN="opencode"
fi
MARKER="$(sy_state_dir)/security-scan.unconfigured"

# The default provider is always usable — skip the readiness gate entirely.
if [ "$PROVIDER" != "claude" ]; then

  missing=""

  # 1. registered in the RESOLVED config (not merely present in some pack file).
  #    `gc config show` prints "[providers.<name>]" for each registered provider.
  if ! gc config show 2>/dev/null | grep -q "^\[providers\.$PROVIDER\]"; then
    missing="$missing
  - [providers.$PROVIDER] is not registered in city.toml"
  fi

  # 2. CLI on PATH — the resolved binary, not the provider name.
  if ! command -v "$BIN" >/dev/null 2>&1; then
    missing="$missing
  - the '$BIN' CLI (provider '$PROVIDER') is not on PATH"
  fi

  # 3. an API key — only for a provider that IS its own binary. A wrapped
  #    provider authenticates through the wrapper CLI's credential store,
  #    which no env-var convention can see. Unlike judge-sweep.sh there is no
  #    probe here to test that store, so an unauthenticated wrapper reaches
  #    lane-ensure and surfaces only as a spawn failure — the KNOWN GAP in the
  #    header. Name is conventional: KIMI_API_KEY, CURSOR_API_KEY, etc.
  keyvar="$(printf '%s' "$PROVIDER" | tr '[:lower:]' '[:upper:]')_API_KEY"
  eval "keyval=\${$keyvar:-}"
  if [ "$BIN" = "$PROVIDER" ] && [ -z "${keyval:-}" ]; then
    missing="$missing
  - \$$keyvar is not set"
  fi

  if [ -n "$missing" ]; then
    # Say it once per week, then stay quiet. This is a configuration gap, not a
    # failure — nagging it every cycle trains the mayor to ignore this lane's mail.
    mkdir -p "$(dirname "$MARKER")" 2>/dev/null
    if [ -f "$MARKER" ] && [ -z "$(find "$MARKER" -mmin +10080 2>/dev/null)" ]; then
      exit 0
    fi
    gc mail send mayor -s "security-scan: lane idle — $PROVIDER provider not configured" \
      -m "The security-scout lane is defined but cannot start, because its provider ($PROVIDER) is not usable yet:
$missing

No sessions are being spawned, and this notice repeats at most weekly.

To enable the lane, in city.toml:
  [providers.$PROVIDER]
  base = \"builtin:$BIN\"

(a WRAPPED provider like deepseek spawns another CLI — its base is
builtin:opencode, so the binary that must be on PATH and authenticated is
'opencode', through opencode's own credential store. An un-wrapped provider
uses builtin:$PROVIDER and \$$keyvar.)

...install the '$BIN' CLI, authenticate it, then 'gc reload'.

To run the lane on the default provider instead (losing the independent-model
property that is the point of it), see agents/security-scout/agent.toml for the
[[patches.agent]] provider override." >/dev/null 2>&1
    touch "$MARKER" 2>/dev/null
    exit 0
  fi

  # Prerequisites met — clear the marker so a future regression re-notifies.
  rm -f "$MARKER" 2>/dev/null
fi

# PRE-SPAWN DEMAND GATE — the second of this script's two questions, and it
# runs SECOND on purpose. The readiness gate above asks "can this lane run at
# all?"; this one asks "need it run this cycle?". Reversing them would let a
# quiet cycle return before the readiness check, so a city that never configured
# its provider would stop receiving the notice telling it so — the lane would
# read as idle-by-choice rather than idle-because-broken.
#
# THE SIGNAL: the scout scopes its review to the diff since its last pass, so a
# rig whose HEAD has not moved offers it nothing to review. Before this gate that
# still cost a session twice a day per opted-in rig: start up, read an empty
# diff, exit IDLE. Cheap next to a real review, but paid on every quiet rig on
# every cycle forever.
#
# The predicate is shared with refactor-scan (lib/demand.sh) so the two scanners
# cannot drift apart, and it FAILS OPEN: a repo whose HEAD cannot be read is
# scanned rather than skipped. A gate that failed closed would silently retire
# the lane, and a lane that never runs can never report that it isn't running.
#
# Narrows the allowlist rather than replacing the walk: survivors reach
# lane-ensure through LANE_RIGS_FILTER, so a rig with no demand is out of the
# lane's scope for this cycle entirely — no spawn, no reap, no escalation.
wanted=""
for rig in $SECURITY_SCAN_RIGS; do
  repo="$(sy_rig_root "$rig")"
  if sha="$(sy_demand_sha_moved "security-scan.$rig" "$repo")"; then
    wanted="$wanted $rig"
  else
    echo "security-scan: $rig unchanged at $sha since its last scan — skipping, no session started."
  fi
done

# Every opted-in rig quiet: the whole cycle is a no-op, said out loud. This line
# is the difference between a lane that is deliberately idle and one that is
# broken, and those look identical in a log that prints nothing.
if [ -z "$wanted" ]; then
  echo "security-scan: no opted-in rig has moved since its last scan — no session started."
  exit 0
fi

LANE_RIGS_FILTER="$(printf '%s' "$wanted" | sed 's/^ *//')"
export LANE_RIGS_FILTER

exec "$(dirname "$0")/lane-ensure.sh" security-scout "security scout"
