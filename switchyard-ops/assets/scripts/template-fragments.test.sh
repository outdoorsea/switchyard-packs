#!/bin/sh
# template-fragments.test.sh — every {{ template "..." }} action in an agent
# prompt must resolve to a {{ define }} that this pack actually ships. No
# network, no city, no gc.
#
# WHY THIS EXISTS. A template action naming a template that is not defined does
# not degrade to a missing section: renderPrompt's Execute fails and returns the
# RAW template body, so the agent is handed a prompt with `{{ .RigRoot }}` and
# every other action still in braces. Nothing reports an error — the lane just
# starts with an unrendered prompt. A rename, a typo, or dropping the `sy-`
# prefix all land there, and no other test in this pack looks.
#
# BOTH STATES ARE EXERCISED. A pass over the shipped tree proves nothing on its
# own — a check that cannot fail reports green against a broken tree too. State
# B injects a reference to a fragment that does not exist and requires the same
# check to catch it; if State B ever reports ok, this test is vacuous.
set -u

PACK="$(cd "$(dirname "$0")/../.." && pwd)"
RC=0
check() { # LABEL EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then printf 'ok       %s\n' "$1"
  else printf 'NOT OK   %s — expected [%s] got [%s]\n' "$1" "$2" "$3"; RC=1; fi
}

# Every name referenced by a {{ template "x" . }} action in any agent prompt.
refs() { # ROOT
  grep -ho '{{ *template *"[^"]*"' "$1"/agents/*/prompt.template.md 2>/dev/null |
    sed 's/.*"\([^"]*\)".*/\1/' | sort -u
}
# Every name this pack defines.
defs() { # ROOT
  grep -ho '{{ *define *"[^"]*"' "$1"/template-fragments/*.template.md 2>/dev/null |
    sed 's/.*"\([^"]*\)".*/\1/' | sort -u
}
# Referenced but never defined — the failure this test exists to catch.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
dangling() { # ROOT
  refs "$1" > "$WORK/refs"
  defs "$1" > "$WORK/defs"
  comm -23 "$WORK/refs" "$WORK/defs"
}

# ---- State A: the shipped tree resolves completely --------------------------
check "shipped tree has no dangling fragment reference" "" "$(dangling "$PACK")"
check "sy-session-close is defined"       "sy-session-close" \
      "$(defs "$PACK" | grep -x 'sy-session-close' || true)"
check "every shipped fragment name is sy- or vendored" "" \
      "$(defs "$PACK" | grep -v '^sy-' | grep -v '^tdd-discipline$' || true)"

# The warning must live in the fragment and NOWHERE else: a prompt that
# re-inlines it has silently reintroduced the drift the fragment removed.
INLINE=$(grep -l 'Nobody is watching your pane\.' "$PACK"/agents/*/prompt.template.md 2>/dev/null | wc -l | tr -d ' ')
check "unattended warning is inlined in 0 prompts" "0" "$INLINE"

# ---- State B: an undefined reference is caught (negative control) -----------
TMP=$(mktemp -d)
cp -R "$PACK"/agents "$PACK"/template-fragments "$TMP"/ 2>/dev/null
VICTIM=$(ls "$TMP"/agents | head -1)
printf '\n{{ template "sy-does-not-exist" . }}\n' >> "$TMP/agents/$VICTIM/prompt.template.md"
check "injected undefined reference is caught" "sy-does-not-exist" "$(dangling "$TMP")"
rm -rf "$TMP"

exit $RC
