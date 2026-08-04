#!/bin/sh
# roster.sh — shared roster resolution for switchyard-ops. Sourced, not executed.
#
# The pack names NO rigs and NO agents. A roster is resolved in two layers:
#
#   1. DERIVED (always available): every agent the reconciler is asked to keep
#      alive — `pool.min >= 1` and not suspended — read from `gc agent list --json`.
#      This is the reconciler's own intent, so it can never drift from config.
#
#   2. DECLARED (optional, city-local): $GC_PACK_STATE_DIR/roster.conf, which the
#      city owns and git never sees. It exists for what gc cannot express:
#        * singleton-alias agents that are deliberately pool.min=0 because a
#          manual session holds their alias — pinning them min=1 spawns a
#          fighting twin. They still need liveness checks, so they are listed
#          in PINNED_EXTRA and asserted absent from the reconciler's pins.
#        * a tmux session-name prefix override, when the pane is not named
#          after the agent's base name.
#        * which agent runs the nightly retro.
#
# Config format (all optional) — see roster.conf.example:
#   PINNED_EXTRA="rig/agent[:tmux-prefix] ..."   # keep alive, must NOT be min=1
#   RETRO_AGENT="rig/agent"                      # nightly-retro target
#   COORDINATORS="rig/agent ..."                 # override the derived sweep set
#
# Exposes: sy_city, sy_city_name, sy_state_dir, sy_load_conf, sy_timeout,
#          sy_derived_roster, sy_roster, sy_coordinators, sy_prefix_of, sy_agent_of

set -u

# sy_timeout SECS CMD... — run CMD with a wall-clock limit, portably.
#
# macOS ships NO `timeout` (and no `gtimeout` without coreutils). A bare
# `timeout 90 gc status` there exits 127 "command not found", which reads as
# "the probe failed" — so loop-health would mail a false probe-down notice on
# every single run. Fall back to a watchdog subshell.
sy_timeout() {
  _secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$_secs" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$_secs" "$@"; return $?; fi
  "$@" &
  _cmd=$!
  ( sleep "$_secs"; kill -TERM "$_cmd" 2>/dev/null ) &
  _watch=$!
  wait "$_cmd" 2>/dev/null; _rc=$?
  kill -TERM "$_watch" 2>/dev/null
  wait "$_watch" 2>/dev/null
  return "$_rc"
}

sy_city() { printf '%s' "${GC_CITY:?switchyard-ops: GC_CITY is not set — orders must run under gc}"; }
sy_city_name() { basename "$(sy_city)"; }

# IMPORT THIS PACK AT CITY SCOPE ONLY.
#
#   [imports.switchyard-ops]        in pack.toml     <- correct
#   [rigs.imports.switchyard-ops]   in city.toml     <- redundant, and harmful
#
# A city import alone yields BOTH: the orders (registered once) and a brakeman
# pool in every rig — gc expands a pack's rig-scoped agents into each rig from
# the city import. Adding the rig import as well registers every order a second
# time under that rig, so loop-health and intake-sweep nudge twice per cycle and
# mail the mayor twice per escalation.
#
# Measured on a 14-rig city:
#   city only -> 14 brakemen, 1 publish-gate registration
#   rig only  ->  1 brakeman,  1 publish-gate registration (that rig)
#   both      -> 14 brakemen, 2 publish-gate registrations
#
# To keep workers out of a rig, suspend the agent there rather than withholding
# the import:
#   [[patches.agent]]
#     dir = "<rig>"
#     name = "brakeman"
#     suspended = true

# gc gives every pack a per-city, per-pack state dir. Fall back to the city's
# runtime dir when a caller is invoked outside an order (e.g. a manual test).
#
# The fallback MUST mirror what gc actually sets GC_PACK_STATE_DIR to, which is
# <city>/.gc/runtime/packs/<pack-name> — note the `packs/` segment. gc's own
# core packs spell the same fallback (".../runtime/packs/core"). An earlier
# version of this function omitted `packs/`, which was invisible in an order
# (GC_PACK_STATE_DIR is set there, so the fallback never ran) but silently
# diverged for anything invoked by hand: a roster.conf installed by following a
# manual run's idea of the state dir landed one directory up from where every
# order looks, and sy_load_conf then read NOTHING with no error. That failure is
# indistinguishable from having no roster.conf at all — an empty roster means
# intake-sweep nudges nobody and exits 0, so the whole dispatch lane goes quiet
# without a single alarm. Keep these two paths identical.
sy_state_dir() {
  if [ -n "${GC_PACK_STATE_DIR:-}" ]; then printf '%s' "$GC_PACK_STATE_DIR"
  else printf '%s/.gc/runtime/packs/switchyard-ops' "$(sy_city)"; fi
}

sy_load_conf() {
  PINNED_EXTRA=""; RETRO_AGENT=""; COORDINATORS=""
  conf="$(sy_state_dir)/roster.conf"
  # shellcheck disable=SC1090
  [ -f "$conf" ] && . "$conf"
  return 0
}

# Agents the reconciler is pinning: pool.min >= 1 and not suspended.
sy_derived_roster() {
  gc agent list --json 2>/dev/null \
    | jq -r '(if type=="array" then . else (.agents // []) end)
             | .[]
             | select((.suspended // false) | not)
             | select(((.pool.min) // 0) >= 1)
             | .qualified_name' 2>/dev/null
}

# Full liveness roster = derived pins + declared extras (singleton aliases).
# Entries keep their optional :tmux-prefix suffix.
sy_roster() {
  sy_load_conf
  { sy_derived_roster; printf '%s\n' $PINNED_EXTRA; } | awk 'NF' | sort -u
}

# Agents to nudge for triage sweeps. Default = the liveness roster (a pinned
# agent is, by construction, a long-lived coordinator). COORDINATORS overrides.
sy_coordinators() {
  sy_load_conf
  if [ -n "$COORDINATORS" ]; then printf '%s\n' $COORDINATORS
  else sy_roster | sed 's/:.*$//'; fi
}

# sy_live_session_for AGENT — echo the SESSION ALIAS of one live session running
# AGENT.
#
# CONTRACT, and the point of having one: "none live" and "the lookup broke" are
# different answers and must not share an exit code.
#   rc=0, alias on stdout : that session is live
#   rc=0, empty stdout    : roster read fine, AGENT has no live session
#   rc=2                  : roster could not be read or parsed — UNKNOWN
#
# An earlier version returned empty at rc=0 for both, which is the very
# conflation this function exists to remove: the caller then reports "no live
# session, go spawn one" when the truth is "`gc session list` failed and nobody
# knows", sending an operator to fix the wrong thing. `2>/dev/null` stays on both
# stages so orders keep quiet, which leaves the exit STATUS as the only channel
# able to carry the difference — so it has to be honest.
#
# WHY THIS EXISTS. `gc session nudge` resolves a SESSION id-or-alias; the roster
# holds AGENT QUALIFIED NAMES. Those are different namespaces, and every spawned
# session carries an instance suffix — the agent `switchyard/switchyard-ops.answerer`
# runs as session `switchyard/switchyard-ops.answerer-adhoc-81606b05c1`. Passing the
# bare agent name therefore fails to resolve (`nudge` exits 1; `peek` reports
# "session not found" AT rc=0), so callers that only counted successes could not
# tell EVERY-NUDGE-FAILED from IDLE-CITY. Resolve the alias here, once, and let
# callers distinguish the two.
#
# `.template` is the unsuffixed agent name and is the honest join key — the same
# predicate lane-ensure, city-lane-ensure and pool-spawn use. The agent_name
# clauses are a fallback for builds that might omit it. Returns `.alias`, which
# is what `gc session nudge` resolves. Prefers the most recently active session
# so a nudge lands on the warmest pane.
# Each stage is run and checked separately rather than as one pipeline: a shell
# pipeline reports only the LAST command's status, so `gc ... | jq ... | awk`
# would mask a failure in either of the first two behind awk's cheerful 0.
sy_live_session_for() {
  _sls_raw="$(gc session list --json --state all 2>/dev/null)" || return 2
  [ -n "$_sls_raw" ] || return 2
  _sls_out="$(printf '%s\n' "$_sls_raw" | jq -r --arg q "$1" '
        [ (.sessions // [])[]
          | select(((.closed // false) | not))
          | (.agent // .agent_name // .qualified_name // "") as $n
          | select( (.template // "") == $q
                    or $n == $q
                    or ($n | startswith($q + "-adhoc-")) )
          | select((.state // "") == "active")
        ]
        | sort_by(.last_active // "")
        | reverse
        | (.[0].alias // .[0].name // .[0].id // "")' 2>/dev/null)" || return 2
  printf '%s\n' "$_sls_out" | awk 'NF' | head -n1
  return 0
}

# entry "rig/agent:prefix" -> "rig/agent"
sy_agent_of() { printf '%s' "${1%%:*}"; }

# entry "rig/agent:prefix" -> "prefix" (default: the agent's base name)
sy_prefix_of() {
  entry="$1"; agent="${entry%%:*}"; prefix="${entry#*:}"
  [ "$prefix" = "$entry" ] && prefix="${agent##*/}"
  printf '%s' "$prefix"
}
