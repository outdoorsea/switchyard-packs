#!/bin/sh
# scratch-reaper: report orphaned gc-scratch directories at the CITY ROOT. When a
# formula runs `gc` from the wrong cwd, gc creates a stunted .gc/ there (seen:
# mol-dog-* leaving gff-<bead>[-<formula>]/ dirs, each holding only .gc/). They are
# not worktrees and hold no data (no Dolt store) — just session scratch — but they
# pile up as clutter. stray-reaper reports stray SESSIONS; this reports stray
# gc-SCRATCH dirs. Same invariant: a leftover becomes mail to the mayor.
#
# Signature (city-agnostic): a root dir with a .gc/ but no .git/ — rig checkouts
# have .git and are excluded; config/compiled dirs have no .gc/.
#
# Report-only by default. SCRATCH_REAPER_PRUNE=1 also removes the ones whose ONLY
# top-level entry is .gc/ (guaranteed no build/work artifacts); anything with
# extra content is reported, never deleted.
set -u

. "$(dirname "$0")/../lib/roster.sh"

CITY="$(sy_city)"
PRUNE="${SCRATCH_REAPER_PRUNE:-0}"

cd "$CITY" 2>/dev/null || exit 0

found=""
pruned=""
kept=""

for entry in */; do
  d="${entry%/}"
  [ -d "$d" ] || continue
  [ -d "$d/.gc" ] || continue      # gc-scratch present
  [ -e "$d/.git" ] && continue     # rig checkout — never touch

  # Is .gc/ the ONLY top-level entry? Then it holds no work/build artifacts.
  others=$(ls -A "$d" 2>/dev/null | grep -vxF '.gc')
  if [ -z "$others" ]; then
    if [ "$PRUNE" = "1" ] && rm -rf -- "$d" 2>/dev/null; then
      pruned="$pruned $d"
    else
      found="$found $d"
    fi
  else
    kept="$kept
- $d (also contains: $(printf '%s' "$others" | tr '\n' ' '))"
  fi
done

[ -z "$found$pruned$kept" ] && exit 0

body="Orphaned gc-scratch directories at the city root — a formula ran gc from the wrong cwd and left a stray .gc/. They hold session scratch, not data."
[ -n "$pruned" ] && body="$body

PRUNED (contained only .gc/):$pruned"
[ -n "$found" ] && body="$body

SAFE TO REMOVE (only .gc/, no artifacts) — set SCRATCH_REAPER_PRUNE=1 to auto-remove, or:
  rm -rf$found"
[ -n "$kept" ] && body="$body

KEPT (have other content — review before removing):$kept"

gc mail send mayor -s "scratch-reaper: orphaned gc-scratch dirs at the city root" -m "$body" >/dev/null 2>&1
exit 0
