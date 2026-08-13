#!/bin/sh
# roster-seed.test.sh — hermetic tests for sy_load_conf's first-use seeding of
# roster.conf. No network, no city, no gc.
#
# THE FAULT THIS EXISTS TO CATCH. The seeding shipped keyed on $PACK_DIR alone.
# gc exports GC_PACK_DIR; $PACK_DIR is only the token gc substitutes into an
# order's `exec =` line, so it is unset inside the running process. The seed
# therefore never fired once, in any order, and nothing was red — there was no
# test on sy_load_conf at all. Case A below is that exact environment, and it is
# the leg that fails against the pre-fix function. A suite that only proved the
# post-fix code passes would not distinguish the two.
#
# Every case runs a REAL caller: a stub in assets/scripts/ that sources
# ../lib/roster.sh, because the resolver's last leg is relative to $0 and $0 for
# a sourced library is the CALLING script. Sourcing roster.sh directly from this
# test would give $0 a different directory and prove nothing about production.
set -u

# The lib is sourced into a CHILD (the stub caller below), so — as in the
# repair-sweep and integration-lane suites — the shell under test is the child's,
# named here rather than by running this file under a different shell. Defaults
# to sh; CI runs it a second time as dash, because the pack ships to cities whose
# /bin/sh is not Ubuntu's.
ROSTER_TEST_SH="${ROSTER_TEST_SH:-sh}"

LIB="$(cd "$(dirname "$0")/../lib" && pwd)/roster.sh"
EXAMPLE="$(cd "$(dirname "$0")/.." && pwd)/roster.conf.example"

RC=0
check() { # LABEL EXPECTED ACTUAL
	if [ "$2" = "$3" ]; then printf 'ok       %s\n' "$1"
	else printf 'NOT OK   %s — expected [%s] got [%s]\n' "$1" "$2" "$3"; RC=1; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# Build a pack tree of the real shape. `with_example` controls whether the
# example is present, which is how the "nothing to seed from" case is made.
new_pack() { # DIR with_example|no_example
	rm -rf "$1"
	mkdir -p "$1/assets/lib" "$1/assets/scripts"
	cp "$LIB" "$1/assets/lib/roster.sh"
	[ "$2" = with_example ] && cp "$EXAMPLE" "$1/assets/roster.conf.example"
	# The stub is the production shape: source the lib relative to $0, then call.
	printf '%s\n' \
		'#!/bin/sh' \
		'set -u' \
		'. "$(dirname "$0")/../lib/roster.sh"' \
		'sy_load_conf' \
		'printf "RETRO_AGENT=[%s]\n" "${RETRO_AGENT:-}"' \
		> "$1/assets/scripts/caller.sh"
	chmod +x "$1/assets/scripts/caller.sh"
}

seeded() { [ -f "$1/roster.conf" ] && echo yes || echo no; }

# --- A: the real order environment. GC_PACK_DIR is what gc exports; PACK_DIR is
# NOT set in the process. This is the case the shipped code got wrong.
PACK="$TMP/a"; STATE="$TMP/a-state"
new_pack "$PACK" with_example
( unset PACK_DIR; GC_PACK_DIR="$PACK" GC_PACK_STATE_DIR="$STATE" \
	"$ROSTER_TEST_SH" "$PACK/assets/scripts/caller.sh" >/dev/null 2>&1 )
check "order env (GC_PACK_DIR, no PACK_DIR) seeds" "yes" "$(seeded "$STATE")"

# --- B: a caller that does export PACK_DIR is still honoured.
PACK="$TMP/b"; STATE="$TMP/b-state"
new_pack "$PACK" with_example
( unset GC_PACK_DIR; PACK_DIR="$PACK" GC_PACK_STATE_DIR="$STATE" \
	"$ROSTER_TEST_SH" "$PACK/assets/scripts/caller.sh" >/dev/null 2>&1 )
check "PACK_DIR alone still seeds" "yes" "$(seeded "$STATE")"

# --- C: a hand-run with NEITHER variable set. This is the manual-vs-order
# divergence sy_state_dir warns about; the $0-relative leg is what closes it.
PACK="$TMP/c"; STATE="$TMP/c-state"
new_pack "$PACK" with_example
( unset GC_PACK_DIR PACK_DIR; GC_PACK_STATE_DIR="$STATE" \
	"$ROSTER_TEST_SH" "$PACK/assets/scripts/caller.sh" >/dev/null 2>&1 )
check "hand-run with no env vars still seeds" "yes" "$(seeded "$STATE")"

# --- D: seeding must be BEHAVIOUR-NEUTRAL. The example is entirely commented
# out, so a freshly seeded city must set nothing — a seeded file and a missing
# one have to be indistinguishable to every caller. This is the invariant that
# lets the seed ship to cities that never asked for one.
PACK="$TMP/d"; STATE="$TMP/d-state"
new_pack "$PACK" with_example
out="$( unset PACK_DIR; GC_PACK_DIR="$PACK" GC_PACK_STATE_DIR="$STATE" \
	"$ROSTER_TEST_SH" "$PACK/assets/scripts/caller.sh" 2>/dev/null )"
check "seeded file sets no settings" "RETRO_AGENT=[]" "$out"
# Phrased so a MISSING file reads as failure. The obvious spelling — grep the
# file and expect no output — passes when the file does not exist at all, because
# grep's error goes to stderr and its stdout is empty either way. That green
# would survive seeding breaking completely, which is the one thing this case is
# here to notice.
check "the example really is all comments" "clean" "$(
	if [ ! -f "$STATE/roster.conf" ]; then echo "missing"
	elif [ -n "$(grep -vE '^[[:space:]]*#' "$STATE/roster.conf" 2>/dev/null |
		grep -vE '^[[:space:]]*$')" ]; then echo "has-live-settings"
	else echo "clean"; fi
)"

# --- E: idempotence. An operator's edited roster.conf must never be clobbered
# by a later run. Overwriting it would silently revert their configuration.
PACK="$TMP/e"; STATE="$TMP/e-state"
new_pack "$PACK" with_example
mkdir -p "$STATE"; printf 'RETRO_AGENT="sw/mayor"\n' > "$STATE/roster.conf"
out="$( unset PACK_DIR; GC_PACK_DIR="$PACK" GC_PACK_STATE_DIR="$STATE" \
	"$ROSTER_TEST_SH" "$PACK/assets/scripts/caller.sh" 2>/dev/null )"
check "existing roster.conf is not overwritten" 'RETRO_AGENT=[sw/mayor]' "$out"

# --- F: no example anywhere. Must not seed, must not fail — a pack missing its
# example degrades to the pre-seed world rather than breaking all 19 callers.
PACK="$TMP/f"; STATE="$TMP/f-state"
new_pack "$PACK" no_example
( unset GC_PACK_DIR PACK_DIR; GC_PACK_STATE_DIR="$STATE" \
	"$ROSTER_TEST_SH" "$PACK/assets/scripts/caller.sh" >/dev/null 2>&1 )
rc=$?
check "missing example seeds nothing" "no" "$(seeded "$STATE")"
check "missing example is not fatal" "0" "$rc"

# --- G: an unwritable state dir is survivable. sy_load_conf returns 0 no matter
# what; a read-only volume must not take down the order that called it.
PACK="$TMP/g"; STATE="$TMP/g-state/nested"
new_pack "$PACK" with_example
mkdir -p "$TMP/g-state"; chmod 500 "$TMP/g-state"
( unset PACK_DIR; GC_PACK_DIR="$PACK" GC_PACK_STATE_DIR="$STATE" \
	"$ROSTER_TEST_SH" "$PACK/assets/scripts/caller.sh" >/dev/null 2>&1 )
rc=$?
chmod 700 "$TMP/g-state"
check "unwritable state dir is not fatal" "0" "$rc"

if [ "$RC" = 0 ]; then printf 'roster-seed self-test: all cases pass\n'
else printf 'roster-seed self-test: FAILURES\n'; fi
exit "$RC"
