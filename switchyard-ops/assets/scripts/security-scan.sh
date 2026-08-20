#!/bin/sh
# security-scan: start one security-scout per rig — but only once the lane's
# provider is actually usable.
#
# WHY THIS ISN'T JUST lane-ensure.sh. The security-scout runs on a non-default
# provider (kimi). If the provider is unregistered or its CLI is missing, a bare
# lane-ensure would spawn a session every cycle that dies on startup: a spawn-fail
# loop that either burns the pool's name slots silently or mails the mayor a
# false "spawn returned no identity" every 12 hours. Neither is a true report of
# what is wrong, which is simply "kimi is not set up yet".
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
# Override the provider expectation via roster.conf when running the lane on the
# default provider (see agents/security-scout/agent.toml):
#   SECURITY_SCOUT_PROVIDER="claude"
set -u

. "$(dirname "$0")/../lib/roster.sh"
sy_load_conf

# OPT-IN PER RIG, the *_RIGS roster idiom every sibling lane switch uses
# (MERGE_LANE_RIGS, CONDUCTOR_RIGS, REVIEW_LANE_RIGS, ...): unset means off
# for the whole city, silently — no spawn, no marker, no mail. The lane used
# to be on-by-default, which meant a city that never configured kimi received
# a "lane idle" notice every week forever: an error posture for what is
# really an operator choice. The list is honored per rig for real, not as a
# boolean: it reaches lane-ensure's rig walk as LANE_RIGS_FILTER, so a rig
# not named here is out of the lane's scope entirely.
SECURITY_SCAN_RIGS="${SECURITY_SCAN_RIGS:-}"
[ -n "$SECURITY_SCAN_RIGS" ] || exit 0
LANE_RIGS_FILTER="$SECURITY_SCAN_RIGS"
export LANE_RIGS_FILTER

PROVIDER="${SECURITY_SCOUT_PROVIDER:-kimi}"
BIN="$(sy_provider_bin "$PROVIDER")"
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
  #    which no env-var convention can see; a genuinely unauthenticated
  #    wrapper still surfaces at spawn time. Name is conventional:
  #    KIMI_API_KEY, CURSOR_API_KEY, etc.
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
  base = \"builtin:$PROVIDER\"
  args = [\"--model\", \"kimi-k2.6\"]

...install the CLI, export \$$keyvar in the session environment, then 'gc reload'.

To run the lane on the default provider instead (losing the independent-model
property that is the point of it), see agents/security-scout/agent.toml for the
[[patches.agent]] provider override." >/dev/null 2>&1
    touch "$MARKER" 2>/dev/null
    exit 0
  fi

  # Prerequisites met — clear the marker so a future regression re-notifies.
  rm -f "$MARKER" 2>/dev/null
fi

exec "$(dirname "$0")/lane-ensure.sh" security-scout "security scout"
