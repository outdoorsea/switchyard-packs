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
#          sy_derived_roster, sy_suspended_rigs, sy_drop_suspended_rigs,
#          sy_roster, sy_coordinators, sy_prefix_of, sy_agent_of,
#          sy_session_alias_for, sy_live_session_for, sy_session_names_for,
#          sy_session_snapshot

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
# To keep workers out of a rig, suspend rather than withholding the import.
# BOTH suspension gates are honored by this pack, and they are independent:
#
#   gc rig suspend <rig>          <- the whole rig; the reconciler skips every
#                                    agent in it (see sy_suspended_rigs)
#   [[patches.agent]]             <- one agent in one rig
#     dir = "<rig>"
#     name = "brakeman"
#     suspended = true
#
# An earlier revision of this comment named only the per-AGENT patch, which read
# as "the agent flag is the supported way to quiet a rig". It is not the only
# way, and asserting so was actively harmful: the city's operational tool is
# `gc rig suspend`, rigs are dormant-by-default (--start-suspended), and the
# roster filtered on the agent flag ALONE. Every coordinator on a suspended rig
# therefore passed the filter with suspended=false and pool.min=1, was checked
# for liveness, found (correctly) absent, and escalated to the mayor every 30m
# forever. Filter on both, and let `gc rig suspend` mean what it says.

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
#
# `.suspended` here is the per-AGENT flag ONLY. It says nothing about whether
# the agent's RIG is suspended, and `gc agent list --json` carries no rig or
# effective-suspension field to ask (measured: its keys are name, pool,
# qualified_name, scope, sling_query, suspended, work_dir, work_query). Rig
# suspension is applied separately, in sy_roster, via sy_drop_suspended_rigs.
sy_derived_roster() {
  gc agent list --json 2>/dev/null \
    | jq -r '(if type=="array" then . else (.agents // []) end)
             | .[]
             | select((.suspended // false) | not)
             | select(((.pool.min) // 0) >= 1)
             | .qualified_name' 2>/dev/null
}

# Rigs the mayor has suspended. `gc rig suspend <rig>` tells the reconciler to
# skip that rig's agents, so those sessions are absent BY DESIGN: reporting them
# missing is a false alarm, and respawning them fights the mayor's decision.
#
# The authority is `gc rig list --json`, NOT <city>/.gc/runtime/suspension-
# state.json. Same fact, but one is a published command contract and the other
# is gc's private runtime state; a pack that parses the latter breaks silently
# the day gc reshapes it, and silently is exactly how this pack fails worst.
#
# FAILS OPEN. An unreadable, slow or empty `gc rig list` yields an EMPTY
# suspended set, so nothing is filtered and every agent is still checked. That
# asymmetry is deliberate. This pack exists to notice the loop is down; a
# monitor that quietly drops agents off its own roster because a lookup blipped
# has become the blind-reconciler failure it was written to catch. Over-
# reporting is recoverable by a human reading mail. Under-reporting is not
# noticed at all — and the 24h cooldown in loop-health bounds the noise even
# when this degrades.
sy_suspended_rigs() {
  gc rig list --json 2>/dev/null \
    | jq -r '(if type=="array" then . else (.rigs // []) end)
             | .[]
             | select(.suspended // false)
             | .name' 2>/dev/null
}

# Filter roster entries on stdin, dropping any whose RIG is suspended.
#
# An entry is "<rig>/<agent>" (optionally with a :tmux-prefix suffix, which is
# irrelevant here). A city-scoped entry has no "<rig>/" segment, hence no rig to
# suspend, and always passes.
# The list reaches awk through the ENVIRONMENT, not `-v`. `-v susp=...` runs
# escape processing on the value, and a literal newline in it makes BSD awk
# (macOS) abort with `awk: newline in string`. It aborts LOUDLY on stderr but
# emits nothing on stdout, and every caller here discards stderr — so the filter
# would have silently dropped the ENTIRE roster, turning loop-health from
# over-reporting into reporting nothing at all. ENVIRON[] is POSIX and takes the
# value verbatim.
sy_drop_suspended_rigs() {
  _sdsr_susp="$(sy_suspended_rigs)"
  [ -n "$_sdsr_susp" ] || { cat; return 0; }
  SY_SUSPENDED_RIGS="$_sdsr_susp" awk '
    BEGIN {
      n = split(ENVIRON["SY_SUSPENDED_RIGS"], a, "\n")
      for (i = 1; i <= n; i++) if (a[i] != "") s[a[i]] = 1
    }
    NF {
      slash = index($0, "/")
      if (slash == 0) { print; next }   # city-scoped: no rig to suspend
      if (!(substr($0, 1, slash - 1) in s)) print
    }'
}

# Full liveness roster = derived pins + declared extras (singleton aliases),
# minus anything on a suspended rig.
# Entries keep their optional :tmux-prefix suffix.
sy_roster() {
  sy_load_conf
  { sy_derived_roster; printf '%s\n' $PINNED_EXTRA; } \
    | awk 'NF' | sy_drop_suspended_rigs | sort -u
}

# Agents to nudge for triage sweeps. Default = the liveness roster (a pinned
# agent is, by construction, a long-lived coordinator). COORDINATORS overrides.
# A suspended rig's coordinator is dropped here too, including when COORDINATORS
# names it explicitly: nudging an agent the reconciler is deliberately skipping
# accomplishes nothing regardless of how it reached the list.
sy_coordinators() {
  sy_load_conf
  if [ -n "$COORDINATORS" ]; then printf '%s\n' $COORDINATORS | sy_drop_suspended_rigs
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
sy_live_session_for() { sy_session_alias_for "$1" active; }

# sy_session_alias_for AGENT [STATE] — the general form. STATE restricts the
# match to sessions in that state ("active"); omitted/empty matches ANY state,
# preferring active sessions and then the most recently active.
#
# Same tri-state contract as sy_live_session_for, which is just this with
# STATE=active.
#
# The ANY-state form exists for revival. A session can be registered `asleep`
# with no pane behind it — dead, but still a resolvable id that `gc session wake`
# can restart. Resolving only ACTIVE sessions would hide it and the caller would
# reach for `gc session new` on an id that already exists. Revival asks "is there
# anything here to restart?", which is a different question from both "who do I
# nudge?" (sy_live_session_for) and "is a process running?" (sy_session_names_for
# plus a tmux check) — three questions, one lookup.
#
# Do NOT use .state as a liveness test. It does not mean what it looks like:
# `asleep` covers BOTH an on_demand session idling with a healthy pane and a
# registered session whose pane is long gone. Measured on one city, the same
# cycle: switchyard/gastown.refinery was asleep WITH pane 26835 alive, while
# switchyard/gastown.polecat-adhoc-8bd7e48cb7 was asleep with no pane at all.
# Liveness has to look at the process. See sy_session_names_for.
#
# A sweep resolving MANY agents should call sy_session_snapshot first (below).
sy_session_alias_for() {
  if [ -n "${SY_SESSION_SNAPSHOT:-}" ]; then
    _ssa_raw="$SY_SESSION_SNAPSHOT"
  else
    _ssa_raw="$(gc session list --json --state all 2>/dev/null)" || return 2
  fi
  [ -n "$_ssa_raw" ] || return 2
  _ssa_out="$(printf '%s\n' "$_ssa_raw" | jq -r --arg q "$1" --arg st "${2:-}" '
        [ (.sessions // [])[]
          | select(((.closed // false) | not))
          | (.agent // .agent_name // .qualified_name // "") as $n
          | select( (.template // "") == $q
                    or $n == $q
                    or ($n | startswith($q + "-adhoc-")) )
          | select($st == "" or (.state // "") == $st)
        ]
        | sort_by(.last_active // "")
        | reverse
        | ( map(select((.state // "") == "active"))
            + map(select((.state // "") != "active")) )
        | (.[0].alias // .[0].name // .[0].id // "")' 2>/dev/null)" || return 2
  printf '%s\n' "$_ssa_out" | awk 'NF' | head -n1
  return 0
}

# sy_session_names_for AGENT — echo the TMUX SESSION NAME of every non-closed
# session for AGENT, one per line. Same tri-state contract (rc=2 = UNKNOWN).
#
# This is the liveness join key. `.session_name` is gc's own record of what it
# called the tmux session — `switchyard/gastown.refinery` runs in a pane named
# `switchyard--gastown__refinery` — so a caller can look up a real pane and a
# real PID without predicting gc's name mangling.
#
# Predicting it is what broke: loop-health used to derive a prefix from the
# agent's BASE NAME (`gastown.refinery` -> match panes starting
# `gastown.refinery-`), which matches nothing, for every agent, on every cycle.
# `/` becomes `--` and `.` becomes `__`, some sessions carry an `-adhoc-<hex>`
# or `-<wisp-id>` suffix and some carry none, and none of that is a contract
# this pack should be re-deriving. Ask gc; it already knows.
sy_session_names_for() {
  if [ -n "${SY_SESSION_SNAPSHOT:-}" ]; then
    _ssn_raw="$SY_SESSION_SNAPSHOT"
  else
    _ssn_raw="$(gc session list --json --state all 2>/dev/null)" || return 2
  fi
  [ -n "$_ssn_raw" ] || return 2
  _ssn_out="$(printf '%s\n' "$_ssn_raw" | jq -r --arg q "$1" '
        (.sessions // [])[]
        | select(((.closed // false) | not))
        | (.agent_name // .agent // .qualified_name // "") as $n
        | select( (.template // "") == $q
                  or $n == $q
                  or ($n | startswith($q + "-adhoc-")) )
        | (.session_name // "")
        | select(. != "")' 2>/dev/null)" || return 2
  printf '%s\n' "$_ssn_out" | awk 'NF'
  return 0
}

# sy_session_snapshot — read the session roster ONCE for a multi-agent sweep.
# While SY_SESSION_SNAPSHOT is set, sy_session_alias_for resolves against it
# instead of re-running `gc session list` per agent.
#
#   rc=0  snapshot taken
#   rc=2  lookup broken — the caller knows NOTHING about any agent's liveness
#         and must report UNKNOWN rather than "everything is missing"
#
# Two reasons, and the second is the load-bearing one:
#   * cost — one `gc session list` per cycle instead of one per agent;
#   * COHERENCE — sessions start and stop while a sweep runs, so per-agent
#     lookups judge different agents against different rosters. One snapshot
#     yields one verdict for the whole cycle, and one rc=2 for the whole cycle
#     instead of an arbitrary half-UNKNOWN split across the roster.
SY_SESSION_SNAPSHOT=""
sy_session_snapshot() {
  SY_SESSION_SNAPSHOT="$(gc session list --json --state all 2>/dev/null)" \
    || { SY_SESSION_SNAPSHOT=""; return 2; }
  [ -n "$SY_SESSION_SNAPSHOT" ] || { SY_SESSION_SNAPSHOT=""; return 2; }
  return 0
}

# entry "rig/agent:prefix" -> "rig/agent"
sy_agent_of() { printf '%s' "${1%%:*}"; }

# entry "rig/agent:prefix" -> "prefix" (default: the agent's base name)
#
# NO LONGER USED FOR LIVENESS, and kept only so an existing roster.conf carrying
# ":prefix" entries stays loadable (sy_agent_of strips the suffix; this reads
# it). Liveness used to grep gc's tmux server for a pane whose session_name
# started with this prefix, which never matched: gc does not name a pane after
# the agent's base name. Agent `switchyard/gastown.witness` runs in a pane named
# `switchyard--gastown__witness`, so a prefix of `gastown.witness-` matched
# nothing, every agent read dead on every cycle, and the order mailed the mayor
# every 30m about a city that was fine. Liveness now joins on `.template` from
# `gc session list --json` — gc's own field, no name-mangling guessed at.
sy_prefix_of() {
  entry="$1"; agent="${entry%%:*}"; prefix="${entry#*:}"
  [ "$prefix" = "$entry" ] && prefix="${agent##*/}"
  printf '%s' "$prefix"
}
