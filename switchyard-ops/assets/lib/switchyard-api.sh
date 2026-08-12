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

# RIG_PROJECTS — optional explicit `<rig>=<tenant-slug>/<project-slug>` bindings,
# space-separated, from the city's roster.conf.
#
# Defaulted HERE rather than in sy_load_conf because the consumer is
# sy_project_for_rig, which is shared by all three orders that source this lib
# (lane-ensure, pool-spawn, repair-sweep). CLOUD_POOL_RIGS is defaulted in
# pool-spawn.sh instead, for the stated reason that roster.sh is shared by a
# dozen orders whose hermetic tests should not absorb a global they ignore —
# that reasoning points here, not there, when the reader is the shared lib. Keep
# the default beside the code that reads it.
RIG_PROJECTS="${RIG_PROJECTS:-}"

# sy_rig_project_override RIG — the operator-declared `<tenant>/<project>` for
# RIG, or empty when RIG is not named in RIG_PROJECTS.
#
# First exact match wins; a repeated rig is an operator typo, and taking the
# first is at least deterministic across a cycle.
sy_rig_project_override() {
  [ -n "${RIG_PROJECTS:-}" ] || return 0
  for _srpo_entry in $RIG_PROJECTS; do
    case "$_srpo_entry" in
      "$1"=?*) printf '%s' "${_srpo_entry#*=}"; return 0 ;;
    esac
  done
  return 0
}

# sy_project_for_rig RIG PROJECTS_JSON — the `<tenant-slug>/<project-slug>` a rig
# drives, or EMPTY when that cannot be answered confidently.
#
# TWO LAYERS, override first:
#
#   1. DECLARED — RIG_PROJECTS in roster.conf, when it names RIG.
#   2. DERIVED  — the rig name matched against the project SLUG.
#
# The slug convention holds in practice (rig `switchyard` drives project
# `switchyard`) and remains the default, so this pack still ships LIVE on a city
# that has never written a roster.conf. That was the original objection to a
# city-local mapping — "the guard would ship inert until a human installed one" —
# and it is answered by making the map an OVERRIDE rather than the only path: with
# no RIG_PROJECTS set, every line below behaves exactly as it did before.
#
# What forced the override: slug equality is not a convention an operator can
# always satisfy. Measured 2026-08-11 on this city — rig `switchyard-forge` drives
# project 25, whose slug is `forge`. No project in any workspace this token reaches
# carries the slug `switchyard-forge`, so FIVE lanes (answerer, dupe-scout,
# golden-journey, judge, intake-triage) resolved to nothing at once. The sibling rig
# `switchyard` bound correctly only because project 2 happens to be slugged
# `switchyard` — coincidence, not design. Renaming the cloud slug to match would fix
# it, but makes a cloud-side identifier permanently load-bearing for a local rig
# name and leaves the same trap armed for the next rig anyone adds.
#
# EXACTLY ONE MATCH, or nothing (derived layer). A duplicate slug across workspaces
# is real and present (`ideapop` exists in two of this token's three tenants), and a
# token reaching both cannot tell which one a rig means. Guessing there would answer
# the queue question about the WRONG project — and a wrong "empty" silently
# unstaffs a lane that has work, which is the one failure this whole path must
# not produce. Ambiguity is therefore not-found, and not-found fails open.
# Naming that rig in RIG_PROJECTS is now the way to resolve such an ambiguity.
sy_project_for_rig() {
  # An unreadable project list stays UNREACHABLE, ahead of any mapping. Callers
  # classify that fault separately from a scope fault (lane_reach_fault reports
  # 'unreachable' vs 'scope'), and a map cannot repair a network that is down.
  [ -n "${2:-}" ] || return 0

  _spfr_mapped="$(sy_rig_project_override "$1")"
  if [ -n "$_spfr_mapped" ]; then
    # Confirm the declared target is actually reachable by this token before
    # handing it to a caller. An unvalidated map turns an operator typo into a
    # 404 on every probe, which downstream reads as "unreadable" — and in
    # lane-ensure that fails OPEN, i.e. the exact silent-idle failure this
    # mapping exists to remove.
    _spfr_ok="$(printf '%s' "$2" | jq -r --arg m "$_spfr_mapped" '
        (if type=="array" then . else (.projects // []) end)
        | [ .[] | select((((.tenant_slug // "") + "/" + (.slug // "")) == $m)) ]
        | if length == 1 then $m else empty end' 2>/dev/null | awk 'NF' | head -n1)"
    if [ -n "$_spfr_ok" ]; then printf '%s\n' "$_spfr_ok"; return 0; fi

    # DECLARED BUT UNREACHABLE — rc=3. RIG_PROJECTS names this rig, but the
    # target it names is not reachable by this token: a typo, a revoked grant,
    # or the wrong tenant.
    #
    # This is a THIRD answer, and it does not share an exit code with either of
    # the other two. "No binding" and "the binding is wrong" demand opposite
    # actions from an operator — write an entry, versus correct the entry that is
    # already there — and collapsing them is how the caller ends up advising a
    # fix for a problem nobody has. Same contract, and the same reason, as
    # sy_live_session_for (lib/roster.sh): different answers must not share an
    # exit code.
    #
    # NO FALLBACK TO THE SLUG RULE. A declared binding is an assertion; if it is
    # false, resolving to some OTHER project that happens to match by slug would
    # honour neither the map nor the convention, and would drive work into a
    # project the operator never named. The lane stays down until the entry is
    # corrected, which is what the 'binding' fault mail promises.
    #
    # EMITS NOTHING on this path, deliberately. Callers that only test for empty
    # output (pool-spawn, repair-sweep) therefore keep working untouched: they
    # take their existing cannot-answer branch, so pool-spawn still fails CLOSED
    # and repair-sweep still skips the rig. Only lane-ensure reads the rc, to
    # separate 'binding' from 'scope' in what it mails the mayor.
    return 3
  fi

  printf '%s' "$2" | jq -r --arg r "$1" '
      (if type=="array" then . else (.projects // []) end)
      | [ .[] | select((.slug // "") == $r) ]
      | if length == 1 and ((.[0].tenant_slug // "") != "")
        then "\(.[0].tenant_slug)/\(.[0].slug)"
        else empty end' 2>/dev/null | awk 'NF' | head -n1
}
