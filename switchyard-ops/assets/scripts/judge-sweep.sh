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
# The provider's NAME is not its BINARY: a wrapped provider (deepseek ->
# builtin:opencode) spawns a CLI named differently from itself, and probing the
# name false-fails the gate on a host where the lane spawns fine. Every check
# below that touches the filesystem or execs uses $BIN; $PROVIDER remains the
# config identity being validated.
BIN="$(sy_provider_bin "$PROVIDER")"
UNCONFIGURED_MARKER="$(sy_state_dir)/judge-sweep.unconfigured"
SKEW_MARKER="$(sy_state_dir)/judge-sweep.provider-skew"

# sy_provider_args PROVIDER — print the resolved provider args from
# `gc config show`, one per line. Empty output means the provider has no args.
sy_provider_args() {
  _pa_provider="$1"
  gc config show 2>/dev/null | awk -v p="$_pa_provider" '
    BEGIN { in_section = 0; in_args = 0; buf = "" }
    /^\[providers\./ {
      if (in_section) exit
      in_section = (match($0, "^\\[providers\\." p "\\]") != 0)
      next
    }
    in_section && /^[[:space:]]*args[[:space:]]*=/ {
      in_args = 1
      buf = $0
      if (buf ~ /\][[:space:]]*$/) { emit(buf); exit }
      next
    }
    in_args {
      buf = buf $0
      if (buf ~ /\][[:space:]]*$/) { emit(buf); exit }
      next
    }
    # No END clause: `exit` inside a pattern-action still runs END, and any
    # guard true after emit() has run would emit every arg a second time.

    function emit(line,    n, i, s) {
      sub(/^[[:space:]]*args[[:space:]]*=[[:space:]]*\[/, "", line)
      sub(/\][[:space:]]*$/, "", line)
      n = split(line, parts, ",")
      for (i = 1; i <= n; i++) {
        s = parts[i]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
        if (s ~ /^".*"$/) {
          gsub(/^"|"$/, "", s)
          print s
        }
      }
    }
  '
}

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

  # 2. CLI on PATH — the resolved BINARY, not the provider name.
  if ! command -v "$BIN" >/dev/null 2>&1; then
    missing="$missing
  - the '$BIN' CLI (provider '$PROVIDER') is not on PATH"
  fi

  # 3. Auth credentials — only for a provider that IS its own binary. A wrapped
  #    provider ($BIN != $PROVIDER, e.g. deepseek via opencode) authenticates
  #    through the wrapper CLI's own credential store, which no env-var
  #    convention can see; demanding $DEEPSEEK_API_KEY there false-idles a lane
  #    whose credential is installed and working. The spawn probe below still
  #    exercises the real CLI, so a genuinely unauthenticated wrapper surfaces
  #    at lane-ensure as a spawn failure rather than being silently passed.
  #    Name is conventional: KIMI_API_KEY, CURSOR_API_KEY, etc. For kimi we
  #    also accept OAuth credentials: either a populated ~/.kimi-code/oauth
  #    directory or a successful `kimi -p` probe.
  keyvar="$(printf '%s' "$PROVIDER" | tr '[:lower:]' '[:upper:]')_API_KEY"
  eval "keyval=\${$keyvar:-}"
  _has_oauth=0
  if [ "$PROVIDER" = "kimi" ]; then
    _oauth_dir="${KIMI_CODE_OAUTH_DIR:-$HOME/.kimi-code/oauth}"
    # The directory must be non-empty: a bare mkdir left behind by an aborted
    # login is not a credential.
    if [ -d "$_oauth_dir" ] && [ -n "$(ls -A "$_oauth_dir" 2>/dev/null)" ]; then
      _has_oauth=1
    elif command -v kimi >/dev/null 2>&1; then
      if sy_timeout 10 kimi -p </dev/null >/dev/null 2>&1; then
        _has_oauth=1
      fi
    fi
  fi
  if [ "$BIN" = "$PROVIDER" ] && [ -z "${keyval:-}" ] && [ "$_has_oauth" -eq 0 ]; then
    missing="$missing
  - \$$keyvar is not set and no OAuth credentials found"
  fi

  # 4. PROVIDER-SPAWN READINESS PROBE: the CLI must accept the args gc's
  # builtin provider will pass it. We extract those args from the resolved
  # config and run the CLI with them. Skew is judged by the CLI's rejection
  # MESSAGE, never by exit code alone — older kimi prints "unknown option"
  # yet exits 0, and other CLIs exit nonzero for reasons that are not skew.
  if command -v "$BIN" >/dev/null 2>&1; then
    _provider_args="$(mktemp)"
    sy_provider_args "$PROVIDER" >"$_provider_args"
    _probe_err="$(
      set --
      while IFS= read -r _arg; do
        set -- "$@" "$_arg"
      done <"$_provider_args"
      sy_timeout 10 "$BIN" "$@" </dev/null 2>&1 >/dev/null
    )"
    _probe_rc=$?
    rm -f "$_provider_args"

    if [ "$PROVIDER" = "kimi" ]; then
      if printf '%s' "$_probe_err" | grep -qi "unknown option"; then
        skew="kimi CLI rejects resolved provider args: the installed kimi does not accept the flags gc's builtin:kimi provider passes. Judging cannot start until the CLI and provider agree."
      fi
    else
      # A nonzero exit alone is NOT skew: an installed-but-unauthenticated CLI
      # exits nonzero for lack of credentials, and a healthy CLI given flags
      # but no work may print usage and exit nonzero. Both must fall through to
      # the unconfigured notice (or to lane-ensure), so — like the kimi path —
      # only an explicit option rejection in the CLI's own words is skew.
      if printf '%s' "$_probe_err" | grep -Eqi 'unknown (option|flag)|unrecognized (option|flag)|invalid (option|flag)|no such (option|flag)'; then
        skew="$PROVIDER CLI rejects resolved provider args (probe exit $_probe_rc): the installed CLI does not accept the flags gc's builtin:$PROVIDER provider passes. Judging cannot start until the CLI and provider agree."
      fi
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
  - upgrade the $PROVIDER CLI to a version accepting the resolved args, OR
  - downgrade gc to a version whose builtin:$PROVIDER provider does not pass those args, OR
  - run the judge on the default provider by patching city.toml:
      [[patches.agent]]
        name = \"<rig>/$SY_NS.judge\"
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

...install the CLI, export \$$keyvar in the session environment or configure OAuth, then 'gc reload'.

To run the judge on the default provider instead (accepting that builder and validator share a runtime brain, which is the whole point of pinning it), see agents/judge/agent.toml for the [[patches.agent]] provider override." >/dev/null 2>&1
    touch "$UNCONFIGURED_MARKER" 2>/dev/null
    exit 0
  fi

  # All checks passed — clear the markers so a future regression re-notifies.
  rm -f "$UNCONFIGURED_MARKER" "$SKEW_MARKER" 2>/dev/null
fi

exec "$(dirname "$0")/lane-ensure.sh" judge "judging-validator"
