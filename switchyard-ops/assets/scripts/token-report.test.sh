#!/usr/bin/env bash
#
# Minimal self-test for token-report.sh issue #320 fallback + guard.
#
# Hermetic: mocks gc, pins GC_CITY/GC_PACK_STATE_DIR to a scratch city, and
# asserts that:
#   - session-bead attribution is preserved (no ~ prefix)
#   - missing-bead facts fall back to the worker string with a ~ prefix
#   - the unknown-share guard fires when unknown tokens exceed ~10%.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOKEN_REPORT="$HERE/token-report.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP — token-report self-test needs jq (not on PATH)"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CITY="$WORK/city"
STATE="$WORK/state"
mkdir -p "$CITY/.gc" "$STATE" "$WORK/bin"

# --- mock gc -----------------------------------------------------------------
# token-report only needs `gc bd -C <city> list --status=all --json` in report
# mode. Return one session bead so we can prove bead attribution is unchanged.
cat >"$WORK/bin/gc" <<'EOF'
#!/bin/sh
if [ "$1" = "bd" ]; then
  cat <<'JSON'
[
  {
    "id": "sess-1",
    "metadata": {
      "session_name": "sess-1",
      "template": "onbelay/gc.implementation-worker",
      "agent_name": "gc.implementation-worker-2",
      "provider": "claude",
      "work_dir": "/city/.gc/worktrees/onbelay/gc.implementation-worker",
      "gc.trigger_bead_id": "bead-1"
    }
  }
]
JSON
  exit 0
fi
echo "mock gc: unexpected invocation: $*" >&2
exit 1
EOF
chmod +x "$WORK/bin/gc"

export PATH="$WORK/bin:$PATH"
export GC_CITY="$CITY"
export GC_PACK_STATE_DIR="$STATE"

# --- usage fixture ------------------------------------------------------------
cat >"$CITY/.gc/usage.jsonl" <<'EOF'
{"kind":"model","run_id":"sess-1","worker":"onbelay__gc.implementation-worker-sess-1","model":"claude-opus-5","provider":"claude","input_tokens":1000,"output_tokens":100,"cache_read_tokens":0,"cache_creation_tokens":0,"at":1785363125325}
{"kind":"model","run_id":"wisp-1","worker":"token-auditor-adhoc-deadbeef","model":"claude-opus-5","provider":"claude","input_tokens":5000,"output_tokens":0,"cache_read_tokens":0,"cache_creation_tokens":0,"at":1785363125326}
{"kind":"model","run_id":"wisp-2","worker":null,"model":"claude-opus-5","provider":"claude","input_tokens":2000,"output_tokens":0,"cache_read_tokens":0,"cache_creation_tokens":0,"at":1785363125327}
EOF

pass=0
fail=0

report() {
  if [ "$1" = "ok" ]; then
    echo "ok   — $2"
    pass=$((pass + 1))
  else
    echo "FAIL — $2${3:+: $3}"
    fail=$((fail + 1))
  fi
}

# --- 1) syntax ---------------------------------------------------------------
if bash -n "$TOKEN_REPORT"; then
  report ok "script parses"
else
  report FAIL "script parses"
fi

# --- 2) text report ----------------------------------------------------------
STDOUT="$WORK/report.out"
STDERR="$WORK/report.err"
bash "$TOKEN_REPORT" --by agent >"$STDOUT" 2>"$STDERR"

# The text table truncates long keys to 30 characters.
if grep -q 'onbelay/gc.implementation-' "$STDOUT" && ! grep -q '~onbelay' "$STDOUT"; then
  report ok "bead-attributed row keeps its name (no ~ prefix)"
else
  report FAIL "bead-attributed row keeps its name" "see $STDOUT"
fi

if grep -q '~switchyard-ops.token-auditor' "$STDOUT"; then
  report ok "fallback worker row is prefixed with ~"
else
  report FAIL "fallback worker row is prefixed with ~" "see $STDOUT"
fi

# 2000 unknown / 8100 total = ~25%, so the guard should fire.
if grep -q "WARNING.*unknown.*threshold" "$STDERR"; then
  report ok "unknown-share guard fires when >10%"
else
  report FAIL "unknown-share guard fires when >10%" "stderr: $(cat "$STDERR")"
fi


# --- 2b) the guard must not depend on the grouping key -----------------------
# REGRESSION (issue-320 review): the guard was computed from $GROUPED, which is
# keyed by whatever --by asked for, so it only fired in modes whose key can
# literally equal "unknown". The DEFAULT report is --by model, which has no such
# key — the guard read 0% and never fired. Identical facts, identical 86%
# unattributed share; only the --by flag differed.
STDERR_MODEL="$WORK/report-model.err"
bash "$TOKEN_REPORT" --by model >/dev/null 2>"$STDERR_MODEL"

if grep -q "WARNING.*unknown.*threshold" "$STDERR_MODEL"; then
  report ok "unknown-share guard fires in the DEFAULT --by model report"
else
  report FAIL "unknown-share guard fires in the DEFAULT --by model report" "stderr: $(cat "$STDERR_MODEL")"
fi

# "~" rows are heuristic, not authoritative, so they COUNT as unattributed:
# (5000 fallback + 2000 no-worker) / 8100 = 86%. Counting only the no-worker
# row would report 24% and understate a wholly-broken join.
if grep -q "WARNING — 86% " "$STDERR_MODEL"; then
  report ok "guard counts ~fallback rows as unattributed (86%, not 24%)"
else
  report FAIL "guard counts ~fallback rows as unattributed (want 86%)" "stderr: $(cat "$STDERR_MODEL")"
fi

# --- 3) JSON report ----------------------------------------------------------
JSON_OUT="$WORK/report.json"
bash "$TOKEN_REPORT" --by agent --json >"$JSON_OUT"

if jq -e '.[] | select(.key == "onbelay/gc.implementation-worker" and .total == 1100)' "$JSON_OUT" >/dev/null; then
  report ok "JSON preserves bead-attributed total"
else
  report FAIL "JSON preserves bead-attributed total" "see $JSON_OUT"
fi

if jq -e '.[] | select(.key == "~switchyard-ops.token-auditor" and .total == 5000)' "$JSON_OUT" >/dev/null; then
  report ok "JSON fallback row has ~prefixed agent and correct total"
else
  report FAIL "JSON fallback row" "see $JSON_OUT"
fi

# --- 4) worker normalization variants ----------------------------------------
cat >"$CITY/.gc/usage.jsonl" <<'EOF'
{"kind":"model","run_id":"w3","worker":"gc__implementation-worker-gv-qq5","model":"claude-opus-5","provider":"claude","input_tokens":100,"output_tokens":0,"cache_read_tokens":0,"cache_creation_tokens":0,"at":1}
{"kind":"model","run_id":"w4","worker":"switchyard-ops__token-auditor-adhoc-abc123","model":"claude-opus-5","provider":"claude","input_tokens":200,"output_tokens":0,"cache_read_tokens":0,"cache_creation_tokens":0,"at":2}
EOF

JSON2="$WORK/report2.json"
bash "$TOKEN_REPORT" --by agent --json >"$JSON2"

if jq -e '.[] | select(.key == "~gc.implementation-worker")' "$JSON2" >/dev/null; then
  report ok "worker __ -> . normalization"
else
  report FAIL "worker __ -> . normalization" "see $JSON2"
fi

if jq -e '.[] | select(.key == "~switchyard-ops.token-auditor")' "$JSON2" >/dev/null; then
  report ok "worker switchyard-ops__token-auditor-adhoc-<hash> normalization"
else
  report FAIL "worker switchyard-ops__token-auditor normalization" "see $JSON2"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "$pass passed, 0 failed"
  exit 0
else
  echo "$pass passed, $fail failed"
  exit 1
fi
