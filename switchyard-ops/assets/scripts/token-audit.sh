#!/bin/sh
# token-audit: start the city's token auditor — but only when there is new spend
# to attribute.
#
# WHY THIS LANE NEEDS THE GATE MOST. The auditor's job is to attribute token
# spend to the agents and rigs that caused it. On a quiet city its own session
# is a measurable share of the spend it reports, so a pass over a ledger that has
# not grown does not merely waste tokens — it manufactures the very cost it
# exists to find, and then reports it.
#
# The order's header already makes this argument for its 168h cadence: "a daily
# audit would re-derive the same findings against a city nobody has touched."
# What the cadence cannot do is enforce it. The reconciler's revive loop spawns
# lanes without consulting an interval — measured on the refactor-scout lane,
# the order fired 0 times in 24h while the lane ran 29 passes (switchyard issue
# 163). A guard belongs where every scheduled pass must cross it, and for the
# scheduled path that is here, before `gc session new`.
#
# THE SIGNAL: new lines in the city's append-only usage sink since the last
# audit. That is the honest measure of "is there anything new to attribute?" —
# the auditor reads that sink, so its growth is precisely the auditor's input.
#
# A MISSING SINK IS NO DEMAND, NOT A FAILURE, and this is where the auditor's
# predicate deliberately parts company with the scanners'. An absent
# usage.jsonl is a READABLE fact — nothing has been recorded — rather than a
# state we failed to read, and token-report.sh already treats it as a clean exit
# rather than an incident. A sink we cannot COUNT is a different thing and fails
# open. See lib/demand.sh, which holds both rules.
#
# A gated skip is a LOGGED no-op: it says the reason on stdout and starts
# nothing. Zero tokens.
set -u

. "$(dirname "$0")/../lib/roster.sh"
. "$(dirname "$0")/../lib/demand.sh"
sy_load_conf

# Named once and used at the exec below, rather than assigned and then repeated
# as a literal: the sibling gates derive a QUALIFIED name from this, so leaving
# it dead here reads as copied-and-unfinished and invites the two drifting apart.
AGENT="token-auditor"

# The sink token-report.sh reads, named the same way it names it. Keeping the
# two in agreement matters: a gate watching a different file than the auditor
# reads would answer a question nobody asked.
LEDGER="$(sy_city)/.gc/usage.jsonl"

if lines="$(sy_demand_ledger_grew "token-audit" "$LEDGER")"; then
  : # New spend on record — fall through and let the city spawner decide.
else
  case "$lines" in
  absent)
    echo "token-audit: no usage sink at $LEDGER — no new spend to attribute, no session started."
    ;;
  *)
    echo "token-audit: usage ledger unchanged at $lines lines since the last audit — no new spend to attribute, no session started."
    ;;
  esac
  exit 0
fi

exec "$(dirname "$0")/city-lane-ensure.sh" "$AGENT" "token auditor"
