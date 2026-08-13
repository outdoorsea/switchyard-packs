#!/bin/sh
# judge-sweep: keep one judging-validator alive per rig, but first verify the
# lane's provider can actually spawn the CLI it will be passed.
#
# The judge pins a non-default provider (kimi) for runtime-diversity (switchyard
# PRD #271). If that provider's CLI rejects the flags gc's builtin provider
# passes, lane-ensure.sh sees only "spawn returned no identity" and classifies it
# as a load-induced handshake failure — which mails the mayor a false remedy and
# leaves the awaiting-validation backlog unowned. This wrapper probes the
# provider BEFORE asking lane-ensure to spend sessions, so a provider/cli skew
# is reported loudly and specifically.
#
# Override the provider via roster.conf / environment when running the lane on
# the default provider (see agents/judge/agent.toml):
#   JUDGE_PROVIDER="claude"
set -u

. "$(dirname "$0")/../lib/roster.sh"
sy_load_conf

PROVIDER="${JUDGE_PROVIDER:-kimi}"
UNCONFIGURED_MARKER="$(sy_state_dir)/judge-sweep.unconfigured"
SKEW_MARKER="$(sy_state_dir)/judge-sweep.provider-skew"

# The default provider is always usable — skip the readiness gate entirely.
if [ "$PROVIDER" != "claude" ]; then

  missing=""
  skew=""

  # 1. registered in the RESOLVED config (not merely present in some pack file).
  #    `gc config show` prints "[providers.<name>]" for each registered provider.
  if ! gc config show 2>/dev/null | grep -q "^\[providers\.$PROVIDER\]"; then
    missing="$missing
  - [providers.$PROVIDER] is not registered in city.toml"
  fi

  # 2. CLI on PATH.
  if ! command -v "$PROVIDER" >/dev/null 2>&1; then
    missing="$missing
  - the '$PROVIDER' CLI is not on PATH"
  fi

  # 3. an API key. Name is conventional: KIMI_API_KEY, CURSOR_API_KEY, etc.
  keyvar="$(printf '%s' "$PROVIDER" | tr '[:lower:]' '[:upper:]')_API_KEY"
  eval "keyval=\${$keyvar:-}"
  if [ -z "${keyval:-}" ]; then
    missing="$missing
  - \$$keyvar is not set"
  fi

  # 4. PROVIDER-SPAWN READINESS PROBE: the CLI must accept the flags gc's
  # builtin provider will pass it. For builtin:kimi that includes --no-thinking.
  # The probe mimics the invocation (global option, no subcommand) and checks
  # stderr for "unknown option", because kimi 0.35.0 prints that error even
  # though its exit code is 0.
  if [ "$PROVIDER" = "kimi" ] && command -v kimi >/dev/null 2>&1; then
    _probe_err="$(sy_timeout 10 kimi --no-thinking 2>&1 >/dev/null)"
    if printf '%s' "$_probe_err" | grep -qi "unknown option.*--no-thinking"; then
      skew="kimi CLI rejects --no-thinking (provider/cli version skew): the installed kimi does not accept the flag gc's builtin:kimi provider passes. Judging cannot start until the CLI and provider agree."
    fi
  fi

  # SKEW is reported before missing config because it is the more specific and
  # more urgent failure: the provider LOOKS configured but cannot actually spawn.
  if [ -n "$skew" ]; then
    # Say it once per week, then stay quiet. A persistent skew is one incident,
    # and re-mailing it every 30 minutes is how an operator learns to filter
    # this sender.
    mkdir -p "$(dirname "$SKEW_MARKER")" 2>/dev/null
    if [ -f "$SKEW_MARKER" ] && [ -z "$(find "$SKEW_MARKER" -mmin +10080 2>/dev/null)" ]; then
      exit 0
    fi
    gc mail send mayor -s "judge-sweep: provider/cli skew blocks judge lane" \
      -m "The judging lane is defined but cannot start because its provider ($PROVIDER) fails the spawn-readiness probe:

$skew

No judging sessions are being spawned, so the awaiting-validation backlog is not draining. This is a provider/cli version mismatch, NOT a load-induced startup handshake failure.

To recover:
  - upgrade the kimi CLI to a version accepting --no-thinking, OR
  - downgrade gc to a version whose builtin:kimi provider does not pass --no-thinking, OR
  - run the judge on the default provider by patching city.toml:
      [[patches.agent]]
        name = \"switchyard/switchyard-ops.judge\"
        provider = \"claude\"

This notice repeats at most weekly." >/dev/null 2>&1
    touch "$SKEW_MARKER" 2>/dev/null
    exit 0
  fi

  if [ -n "$missing" ]; then
    # Say it once per week, then stay quiet. This is a configuration gap, not an
    # incident — nagging it every cycle trains the mayor to ignore this lane's mail.
    mkdir -p "$(dirname "$UNCONFIGURED_MARKER")" 2>/dev/null
    if [ -f "$UNCONFIGURED_MARKER" ] && [ -z "$(find "$UNCONFIGURED_MARKER" -mmin +10080 2>/dev/null)" ]; then
      exit 0
    fi
    gc mail send mayor -s "judge-sweep: lane idle — $PROVIDER provider not configured" \
      -m "The judging lane is defined but cannot start, because its provider ($PROVIDER) is not usable yet:
$missing

No judging sessions are being spawned, and this notice repeats at most weekly.

To enable the lane, in city.toml:
  [providers.$PROVIDER]
  base = \"builtin:$PROVIDER\"
  args = [\"--model\", \"kimi-k2.6\"]

...install the CLI, export \$$keyvar in the session environment, then 'gc reload'.

To run the judge on the default provider instead (accepting that builder and validator share a runtime brain, which is the whole point of pinning it), see agents/judge/agent.toml for the [[patches.agent]] provider override." >/dev/null 2>&1
    touch "$UNCONFIGURED_MARKER" 2>/dev/null
    exit 0
  fi

  # All checks passed — clear the markers so a future regression re-notifies.
  rm -f "$UNCONFIGURED_MARKER" "$SKEW_MARKER" 2>/dev/null
fi

exec "$(dirname "$0")/lane-ensure.sh" judge "judging-validator"
