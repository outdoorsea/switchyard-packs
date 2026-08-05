# switchyard-api.sh — read-only access to a switchyard project's queues from an
# ORDER, i.e. from outside any agent session. Sourced, not executed.
#
# WHY THIS EXISTS AT ALL. The self-directed lanes (judge, answerer) take their
# work from switchyard, not from the gc bead ledger, and until now only the
# SESSION could see that queue — it reads it over the switchyard MCP once it is
# already running. So the sweep that decides whether to start one had no way to
# ask "is there anything to do?", and paid a whole session per rig per cycle to
# discover the answer was "no" (switchyard PRD #299, crit:61754b5dbdb9).
#
# EVERYTHING HERE IS ADVISORY AND FAILS OPEN. Every function answers with an
# EMPTY string when it cannot get a confident answer — no token, no network, a
# non-200, a malformed body, an ambiguous name. Callers must treat empty as
# "unknown" and proceed as if the check did not exist. That direction is not a
# convenience: withholding a spawn on a bad read would stop a lane city-wide with
# no signal, which lane-ensure.sh's own teardown notes call strictly worse than
# the over-spawn it would be preventing. An extra session is visible in
# `gc session list`; a lane that quietly stopped working is not.
#
# NO WRITES LIVE HERE, and none should be added. A sweep order decides whether to
# start a session; the session itself owns every claim, verdict and mutation.

# The switchyard instance to ask. The rig's own MCP overlay sets this same
# variable (`.claude/settings.json` -> mcpServers.switchyard.env), so an order
# inheriting a rig's environment targets the instance that rig's agents use.
SY_API_BASE_DEFAULT="https://switchyard.work"

# How long any single call may take. A sweep walks every rig in the city, so this
# is a per-call bound on a loop, not a one-off: keep it short enough that an
# unreachable switchyard costs the cycle seconds rather than minutes. Exceeding
# it is a normal fail-open outcome, not an error worth reporting.
SY_API_MAX_TIME="${SY_API_MAX_TIME:-8}"
SY_API_CONNECT_TIMEOUT="${SY_API_CONNECT_TIMEOUT:-4}"

sy_api_base() {
  if [ -n "${SWITCHYARD_BASE_URL:-}" ]; then printf '%s' "${SWITCHYARD_BASE_URL%/}"; return 0; fi
  printf '%s' "$SY_API_BASE_DEFAULT"
}

# sy_api_token — the `sy_` bearer token, or empty when none resolves.
#
# Resolution order runs from most explicit to most derived, and deliberately
# reuses the CLI's OWN token file rather than introducing a second credential
# site for an operator to install and keep in sync:
#   1. SWITCHYARD_API_TOKEN — an explicit override for a city that wants the
#      sweep on a different identity than the interactive CLI.
#   2. `switchyard-mcp token-path` — the CLI's published resolver. Asking the
#      binary where its token lives, rather than hardcoding the path, keeps this
#      working when that precedence changes (it already differs per platform).
#
# The token is printed to stdout for the caller to capture, and never logged,
# echoed into a URL, or passed as a command-line argument — a bearer token in an
# argv is readable by every process on the box via `ps`.
sy_api_token() {
  if [ -n "${SWITCHYARD_API_TOKEN:-}" ]; then printf '%s' "$SWITCHYARD_API_TOKEN"; return 0; fi

  command -v switchyard-mcp >/dev/null 2>&1 || return 0
  _sat_path="$(switchyard-mcp token-path 2>/dev/null)" || return 0
  [ -n "$_sat_path" ] && [ -r "$_sat_path" ] || return 0

  # `..|.token?` rather than a fixed key path: tokens.json is keyed by instance
  # and its envelope has changed shape before. Take the first token it holds.
  jq -r '[.. | .token? // empty] | .[0] // empty' "$_sat_path" 2>/dev/null | awk 'NF' | head -n1
}

# sy_api_get PATH TOKEN — GET an API path, echoing the body. Empty on ANY
# failure, including a non-2xx status (`-f`), so a caller never has to tell an
# error page apart from a payload.
#
# The token arrives as an argument rather than being re-resolved per call so a
# cycle pays the resolver once, and is passed to curl over a HEADER FILE on
# stdin (`-H @-` is not portable; `--config -` is). Writing it as `-H
# "Authorization: Bearer $tok"` on the command line would publish the credential
# in argv to every `ps` on the host.
sy_api_get() {
  [ -n "${2:-}" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  printf 'header = "Authorization: Bearer %s"\n' "$2" \
    | curl -fsS --config - \
        --connect-timeout "$SY_API_CONNECT_TIMEOUT" \
        --max-time "$SY_API_MAX_TIME" \
        "$(sy_api_base)$1" 2>/dev/null
}

# sy_api_projects TOKEN — the project list this token can reach, as JSON. Empty
# when unreadable. Fetch it ONCE per cycle and pass it to sy_project_for_rig:
# it is a network call, and re-reading it per rig would also let a mid-cycle blip
# answer differently for two rigs in the same sweep.
sy_api_projects() {
  sy_api_get "/api/v1/projects" "$1"
}

# sy_project_for_rig RIG PROJECTS_JSON — the `<tenant-slug>/<project-slug>` a rig
# drives, or EMPTY when that cannot be answered confidently.
#
# The rig name is matched against the project SLUG. That convention is what
# already holds in practice (rig `switchyard` drives project `switchyard`), and
# it is the only mapping available: the pack is deliberately city-agnostic and
# names no rig, the rig's MCP overlay binds only a base URL, and an agent's
# project comes from a `set_scope` call in its PROMPT, which an order cannot
# read. Inventing a city-local mapping file was the alternative and is worse —
# the guard would ship inert on every city until a human installed one.
#
# EXACTLY ONE MATCH, or nothing. A duplicate slug across workspaces is real and
# present (`ideapop` exists in two of this token's three tenants), and a token
# reaching both cannot tell which one a rig means. Guessing there would answer
# the queue question about the WRONG project — and a wrong "empty" silently
# unstaffs a lane that has work, which is the one failure this whole path must
# not produce. Ambiguity is therefore not-found, and not-found fails open.
sy_project_for_rig() {
  [ -n "${2:-}" ] || return 0
  printf '%s' "$2" | jq -r --arg r "$1" '
      (if type=="array" then . else (.projects // []) end)
      | [ .[] | select((.slug // "") == $r) ]
      | if length == 1 and ((.[0].tenant_slug // "") != "")
        then "\(.[0].tenant_slug)/\(.[0].slug)"
        else empty end' 2>/dev/null | awk 'NF' | head -n1
}
