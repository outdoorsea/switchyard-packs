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
  if command -v sy_timeout >/dev/null 2>&1; then
    _sat_path="$(sy_timeout "$SY_API_CONNECT_TIMEOUT" switchyard-mcp token-path 2>/dev/null)" || return 0
  else
    _sat_path="$(switchyard-mcp token-path 2>/dev/null)" || return 0
  fi
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

# sy_api_post PATH TOKEN JSON — POST a JSON body to an API path, echoing the
# response body. Same conventions as sy_api_get: empty on ANY failure including
# a non-2xx (`-f`), and the token travels over a curl config on stdin, never
# argv. The JSON body IS argv — it never carries a credential, only claim and
# verdict fields — and callers must treat an empty answer as "refused or
# unreachable", never as success: every consumer of this helper fails CLOSED
# (skips the write's follow-up, releases the claim it holds) on empty.
sy_api_post() {
  [ -n "${2:-}" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  printf 'header = "Authorization: Bearer %s"\n' "$2" \
    | curl -fsS --config - \
        --connect-timeout "$SY_API_CONNECT_TIMEOUT" \
        --max-time "$SY_API_MAX_TIME" \
        -H 'Content-Type: application/json' \
        --data "${3:-{\}}" \
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

# --- THE PR-REVIEW LANE'S LIVE-WORK PROBE (switchyard PRD #360 P2) -----------
#
# One question, asked from an ORDER: is a worker already on this pull request?
# switchyard mints a claimable `pr-review` bead per (PR, head sha) once a PR has
# aged past the review grace window, and a brakeman drains it from the cloud
# pool. A reporting order that does not know this escalates the very PR the
# working lane is holding, so the mayor is mailed about work that is already
# moving — the double-report pr-gate's tier exclusion exists to prevent.
#
# NO NEW SERVER SURFACE. The probe is built from two things switchyard already
# publishes: the bead id is a PURE FUNCTION of (repo, number, head sha)
# (db.PRReviewBeadID — that determinism is what makes the mint exactly-once), and
# GET /beads/{id}/delivery-evidence is a documented, project-scoped, 404-over-403
# read that reports the bead's `status`. Deriving the id here rather than
# listing the pool is what lets the probe see a CLAIMED bead: the pool read only
# ever returns unclaimed work, so it answers "nobody has started" — the opposite
# of the question. The one cost is that the derivation is stated twice, in Go and
# here; TestPRReviewBeadIDShellDerivationMatches (internal/db) executes THIS
# function and compares, so a change to either side reds a test instead of
# silently switching the probe off.
#
# FAILS OPEN, in the reporting direction. Every one of these answers "not live"
# when it cannot be sure — no token, no digest tool, an unreachable switchyard, a
# 404, a body it cannot parse — so an unreadable switchyard leaves the caller
# reporting exactly as it did before the probe existed. The inverse default would
# let one bad read silence a whole gate, which is the failure class this pack
# exists to catch.

# sy_sha256_hex — the hex sha256 of STDIN, or empty when no digest tool exists.
#
# Three spellings because the pack runs on macOS controllers (shasum, from perl)
# and Linux runners (sha256sum) alike, with openssl as the last resort. Each
# prints the digest first except openssl, which prints it last.
sy_sha256_hex() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 2>/dev/null | awk '{print $1}'; return 0; fi
  if command -v sha256sum >/dev/null 2>&1; then sha256sum 2>/dev/null | awk '{print $1}'; return 0; fi
  if command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 2>/dev/null | awk '{print $NF}'; return 0; fi
  return 0
}

# sy_pr_review_bead_id REPO NUMBER HEAD_SHA — the pool bead id switchyard mints
# to review that pull request at that head, or EMPTY when it cannot be derived.
#
# Mirrors db.PRReviewBeadID exactly: sha256 over `repo\0number\0head_sha`, the
# first 12 hex digits, prefixed `prreview-<number>-`. The NUL separators are what
# stop two different tuples colliding by concatenation, so they are not cosmetic.
# Arguments are used verbatim — the Go side only trims surrounding whitespace and
# does not case-fold, so the repo slug must be the canonical `owner/name` the PR
# URL carries.
sy_pr_review_bead_id() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] || return 0
  _sprbi_hash="$(printf '%s\000%s\000%s' "$1" "$2" "$3" | sy_sha256_hex | cut -c1-12)"
  [ -n "$_sprbi_hash" ] || return 0
  printf 'prreview-%s-%s' "$2" "$_sprbi_hash"
}

# sy_pr_review_live PROJECT REPO NUMBER HEAD_SHA TOKEN — exit 0 ONLY when
# switchyard confirms an OPEN or CLAIMED pr-review bead for that pull request at
# that head sha. Any other answer, including every failure, exits non-zero.
#
# `status <> closed` IS the criterion's "open or claimed": beads_mirror moves
# open -> claimed -> in_progress -> closed, so the live states are exactly the
# ones the working lane can still act on. A CLOSED bead is deliberately not live
# — a review that landed a `request_changes` verdict leaves the PR unmerged and
# nobody holding it, which is precisely when the reporting lane should speak
# again.
#
# The head sha matters: switchyard retires a bead whose sha has been superseded,
# so the bead for the PR's CURRENT head is the only one anybody is working.
sy_pr_review_live() {
  [ -n "${1:-}" ] || return 1   # no project resolved for this rig
  [ -n "${5:-}" ] || return 1   # no token
  command -v jq >/dev/null 2>&1 || return 1

  _sprl_bead="$(sy_pr_review_bead_id "${2:-}" "${3:-}" "${4:-}")"
  [ -n "$_sprl_bead" ] || return 1

  _sprl_body="$(sy_api_get "/api/v1/projects/$1/beads/$_sprl_bead/delivery-evidence" "$5")"
  [ -n "$_sprl_body" ] || return 1   # 404 (no such bead), or unreachable

  _sprl_status="$(printf '%s' "$_sprl_body" | jq -r '.status // ""' 2>/dev/null)"
  case "$_sprl_status" in
    "" | closed) return 1 ;;
    *) return 0 ;;
  esac
}
