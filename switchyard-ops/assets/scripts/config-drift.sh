#!/bin/sh
# config-drift: if a city keeps its config as code, keep it honest.
# Mechanical checks over the live city root, mailing the mayor per the loop's
# governing invariant. Never edits, commits, or reverts anything — a human (or
# a directed session) reconciles.
#
# Portable by construction:
#   * The tracked-config surface is whatever the city's git repo already tracks
#     — this pack does not name city.toml, pack.toml, or any agent.
#   * The roster is read from gc, not from a duplicated list, so the old
#     "roster.sh disagrees with city.toml" drift class cannot exist.
#
# Escalation policy mirrors loop-health: a singleton-pin violation mails every
# run (it is a live regression — a twin session is being spawned right now).
# Uncommitted-drift / stray-file conditions mail at most once per 24h: they are
# hygiene, gc rewrites make them transiently expected, and a 6h nag would train
# everyone to ignore mayor mail.
set -u

. "$(dirname "$0")/../lib/roster.sh"

# Orders run once, at city scope. See sy_city_scope_only.
sy_city_scope_only
sy_load_conf

CITY="$(sy_city)"
MARKER="$(sy_state_dir)/config-drift.alerted"

cd "$CITY" 2>/dev/null || exit 0

# ---- check 1: singleton aliases must NOT be reconciler-pinned --------------
# A PINNED_EXTRA agent is declared min=0-on-purpose: its alias is held by a
# manual session. If something re-added a min=1 patch, the reconciler is now
# minting a fighting twin. This is the only check that runs without git.
violations=""
if [ -n "${PINNED_EXTRA:-}" ]; then
  pinned_now="$(sy_derived_roster)"
  for entry in $PINNED_EXTRA; do
    agent="$(sy_agent_of "$entry")"
    if printf '%s\n' "$pinned_now" | grep -qxF "$agent"; then
      violations="$violations
- $agent is declared a singleton alias (PINNED_EXTRA) but the reconciler is pinning it (pool.min >= 1). That spawns a second session which fights the alias. Remove its min_active_sessions=1 patch; loop-health keeps it alive instead."
    fi
  done
fi

if [ -n "$violations" ]; then
  gc mail send mayor -s "ESCALATION config-drift: singleton alias is reconciler-pinned" -m "A singleton-alias agent is being pinned by the reconciler:$violations

This repeats every cycle until they agree." >/dev/null 2>&1
fi

# ---- git-backed checks (skip cleanly when the city is not a repo) ----------
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# check 2: uncommitted drift on the TRACKED surface only. The city root also
# holds runtime state (worktrees, Dolt data, rig checkouts) that is legitimately
# untracked, so --untracked-files=no is what makes this portable.
dirty=$(git status --porcelain --untracked-files=no 2>/dev/null)

# check 3: stray config dupes at the city root. Space-named dupes ("city 2.toml",
# the macOS copy pattern) and *.bak-* leftovers have silently shadowed real
# config before.
strays=$(find . -maxdepth 1 \( \
    \( -name 'city*.toml' ! -name 'city.toml' \) -o \
    -name '*.toml.bak*' -o -name '* [0-9].toml' \
  \) 2>/dev/null | sed 's|^\./||')

if [ -n "$dirty" ] || [ -n "$strays" ]; then
  mkdir -p "$(dirname "$MARKER")" 2>/dev/null
  recently_alerted=0
  if [ -f "$MARKER" ] && [ -z "$(find "$MARKER" -mmin +1440 2>/dev/null)" ]; then
    recently_alerted=1
  fi
  if [ "$recently_alerted" -eq 0 ]; then
    body="This city's config-as-code has diverged from git HEAD (daily notice)."
    [ -n "$dirty" ] && body="$body

Uncommitted changes to tracked files:
$dirty

If a gc command rewrote config intentionally, commit the result. If the rewrite ate comments or patches, restore from HEAD and re-apply deliberately — gc rewrites drop comments."
    [ -n "$strays" ] && body="$body

Stray config files at the city root (archive or delete):
$strays"
    gc mail send mayor -s "config-drift: uncommitted config / stray files (daily notice)" -m "$body" >/dev/null 2>&1
    touch "$MARKER" 2>/dev/null
  fi
fi

exit 0
