#!/bin/sh
# token-report: attribute token usage to the thing that spent it.
#
# gc records every model call in .gc/usage.jsonl and `gc costs` aggregates it —
# but ONLY by run id, which is an opaque session id. This script performs the
# join gc does not: run id -> session bead -> agent template, provider, rig, and
# the work bead that triggered the session. That turns "gf-c1q burned 436k cache
# reads" into "faultline's implementation-worker on claude-opus-5 did".
#
# WHY NO DOLLARS. This city runs on Claude Max subscriptions, which are flat-rate
# rather than metered, so a per-token USD figure would be a fabricated number
# dressed up as a bill. gc's own EST_USD reads 0.0000 here anyway: its pricing
# registry is compiled in (pricing.PricingRegistry) with no config knob, and it
# does not know claude-opus-5, so every invocation is flagged "unpriced" and
# excluded. TOKENS BY MODEL are the honest unit — that is what this reports.
#
# THE NUMBER THAT MATTERS. Observed here: 681,270 cache-read tokens against 20
# input and 8,213 output. Spend is dominated by RE-READING CONTEXT, not by
# generating text. The report therefore breaks out all four meters separately and
# derives a `context_pct` — the share of tokens spent re-reading rather than
# producing. Optimising output length is optimising the wrong term by orders of
# magnitude; see TOKEN-HARDENING.md for the levers that actually move this.
#
# Usage:
#   token-report.sh                    # by model (default), all history
#   token-report.sh --by agent         # by agent template
#   token-report.sh --by rig           # by rig
#   token-report.sh --by session       # by session, with its work bead
#   token-report.sh --days 7           # window to the last 7 days
#   token-report.sh --json             # machine-readable
#   token-report.sh --spikes           # spike check only; mails mayor on breach
#
# Env (roster.conf-tunable):
#   TOKEN_REPORT_SPIKE_FACTOR   day-over-median multiple that counts as a spike (default 3)
#   TOKEN_REPORT_SPIKE_FLOOR    ignore days under this many tokens (default 200000)
set -u

. "$(dirname "$0")/../lib/roster.sh"
sy_load_conf

CITY="$(sy_city)"
USAGE="$CITY/.gc/usage.jsonl"
MARKER="$(sy_state_dir)/token-report.alerted"

SPIKE_FACTOR="${TOKEN_REPORT_SPIKE_FACTOR:-3}"
SPIKE_FLOOR="${TOKEN_REPORT_SPIKE_FLOOR:-200000}"

BY="model"; DAYS=""; OUT="text"; MODE="report"
while [ $# -gt 0 ]; do
  case "$1" in
    --by)     BY="${2:-model}"; shift 2 ;;
    --days)   DAYS="${2:-}"; shift 2 ;;
    --json)   OUT="json"; shift ;;
    --spikes) MODE="spikes"; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

[ -f "$USAGE" ] || { echo "token-report: no usage sink at $USAGE" >&2; exit 0; }

# Usage facts land only under the default "local" usage provider. Under an
# "exec:" or "discard" provider they are forwarded out of process or dropped, and
# this file stays empty — which looks identical to "nothing ran". Say so rather
# than reporting a confident zero.
if [ ! -s "$USAGE" ]; then
  echo "token-report: usage sink is EMPTY. Either nothing has run, or this city's"
  echo "  usage provider is not \"local\" (an exec:/discard provider forwards or drops"
  echo "  facts). An empty sink is not evidence of zero spend."
  exit 0
fi

SINCE_MS=0
if [ -n "$DAYS" ]; then
  SINCE_MS=$(( ($(date +%s) - (DAYS * 86400)) * 1000 ))
fi

# --- session bead lookup -----------------------------------------------------
# Session beads carry the join keys in metadata: template, provider, work_dir,
# session_name, and gc.trigger_bead_id (the work bead that caused the session).
# One bulk read beats one `bd show` per run.
#
# `gc bd list` without -C resolves to whatever ledger the cwd implies; orders run
# at the city root but a manual invocation may not, so pin it explicitly.
SESSIONS="$(gc bd -C "$CITY" list --status=all --json 2>/dev/null \
  | jq -c '[ .[]? | select(.metadata.session_name != null) | {
        id,
        # template = the agent DEFINITION (e.g. "gc.implementation-worker",
        # "bd.dog"). agent_name = the running INSTANCE (e.g.
        # "gc.implementation-worker-2"), which is what you peek/nudge and what
        # `gc agent list` shows. Keep both: the template tells you which lane
        # burned tokens, the instance tells you which pane to go look at.
        template:   (.metadata.template // "unknown"),
        agent_name: (.metadata.agent_name
                     // .metadata.canonical_instance_name
                     // .metadata.alias
                     // .metadata.template // "unknown"),
        provider:  (.metadata.provider // "unknown"),
        work_dir:  (.metadata.work_dir // ""),
        trigger:   (.metadata["gc.trigger_bead_id"] // null),
        sy_prd:    (.metadata["gc.switchyard_prd"]  // null),
        sy_bead:   (.metadata["gc.switchyard_bead"] // null)
      } ]' 2>/dev/null)"
[ -n "$SESSIONS" ] || SESSIONS='[]'

# A join whose lookup table is silently empty attributes EVERYTHING to "unknown"
# and still prints a confident table. Say it out loud instead.
if [ "$(printf '%s' "$SESSIONS" | jq 'length')" -eq 0 ] && [ "$OUT" = "text" ]; then
  echo "token-report: WARNING — session-bead lookup returned 0 rows."
  echo "  Every fact will attribute to 'unknown'. This is a broken join, not a quiet city."
  echo
fi

# --- the join ----------------------------------------------------------------
ENRICHED="$(jq -c -n \
    --slurpfile facts "$USAGE" \
    --argjson sessions "$SESSIONS" \
    --argjson since "$SINCE_MS" '
  ($sessions | map({key: .id, value: .}) | from_entries) as $byid
  | [ $facts[]
      | select(.kind == "model")
      | select(.at >= $since)
      | . as $f
      | ($byid[$f.run_id] // {}) as $s
      # rig, resolved from two independent signals because either alone is
      # incomplete:
      #   1. work_dir — .gc/worktrees/<rig>/... is a rig agent, .gc/agents/... is
      #      city-scoped. But a rig-scoped agent that needs no build worktree
      #      (judge, answerer, auditors) has a city-shaped work_dir, so this
      #      signal alone reports "unknown" for a session whose rig is obvious.
      #   2. the qualified agent name — a rig agent is "<rig>/<name>". This
      #      catches exactly the case work_dir misses.
      # Prefer the name when it is qualified; fall back to the path.
      | ($s.work_dir // "") as $wd
      | ($s.template // "") as $tpl
      | (if   ($tpl | test("/"))
         then ($tpl | split("/") | .[0])
         elif ($wd | test("/\\.gc/worktrees/"))
         then ($wd | capture("/\\.gc/worktrees/(?<r>[^/]+)/").r)
         elif ($wd | test("/\\.gc/agents/"))
         then "city"
         else "unknown" end) as $rig
      | {
          at:        $f.at,
          day:       ($f.at / 1000 | floor | gmtime | strftime("%Y-%m-%d")),
          run:       $f.run_id,
          model:     ($f.model    // "unknown"),
          provider:  ($f.provider // $s.provider // "unknown"),
          agent:      ($s.template   // "unknown"),
          agent_name: ($s.agent_name // "unknown"),
          rig:       $rig,
          bead:      ($s.trigger  // null),
          prd:       ($s.sy_prd   // null),
          input:     ($f.input_tokens          // 0),
          output:    ($f.output_tokens         // 0),
          cache_r:   ($f.cache_read_tokens     // 0),
          cache_c:   ($f.cache_creation_tokens // 0)
        }
    ]' 2>/dev/null)"
[ -n "$ENRICHED" ] || ENRICHED='[]'

TOTAL_FACTS="$(printf '%s' "$ENRICHED" | jq 'length')"
if [ "$TOTAL_FACTS" -eq 0 ]; then
  echo "token-report: no model facts in window (kind==\"model\"${DAYS:+, last $DAYS days})."
  exit 0
fi

# --- spike detection ---------------------------------------------------------
# Compare the newest day against the MEDIAN of the preceding days, not the mean:
# one prior spike would inflate a mean and mask the next one. A city with fewer
# than 3 days of history has no baseline — say so rather than inventing one.
if [ "$MODE" = "spikes" ]; then
  SPIKE="$(printf '%s' "$ENRICHED" | jq -c \
      --argjson factor "$SPIKE_FACTOR" --argjson floor "$SPIKE_FLOOR" '
    ( group_by(.day)
      | map({day: .[0].day, tokens: (map(.input + .output + .cache_r + .cache_c) | add)})
      | sort_by(.day) ) as $days
    | if ($days | length) < 3 then {verdict: "no-baseline", days: ($days|length)}
      else
        ($days[-1])              as $latest
      | ($days[0:-1] | map(.tokens) | sort) as $prior
      | ($prior[(($prior|length-1)/2|floor)]) as $median
      | { verdict: (if $median > 0 and $latest.tokens > $floor
                      and ($latest.tokens / $median) >= $factor
                    then "spike" else "ok" end),
          day: $latest.day, tokens: $latest.tokens,
          median: $median,
          ratio: (if $median > 0 then (($latest.tokens / $median) * 100 | round / 100) else null end) }
      end')"
  VERDICT="$(printf '%s' "$SPIKE" | jq -r '.verdict')"
  [ "$OUT" = "json" ] && { printf '%s\n' "$SPIKE"; exit 0; }

  case "$VERDICT" in
    no-baseline) echo "token-report: no baseline yet ($(printf '%s' "$SPIKE" | jq -r '.days') day(s) of history; need 3)."; exit 0 ;;
    ok)          echo "token-report: no spike ($(printf '%s' "$SPIKE" | jq -r '.day'): $(printf '%s' "$SPIKE" | jq -r '.tokens') tokens vs median $(printf '%s' "$SPIKE" | jq -r '.median'))."; exit 0 ;;
  esac

  # Breach: name the top spenders so the mail is actionable, not just an alarm.
  DAY="$(printf '%s' "$SPIKE" | jq -r '.day')"
  TOP="$(printf '%s' "$ENRICHED" | jq -r --arg d "$DAY" '
      [ .[] | select(.day == $d) ]
      | group_by(.model + " | " + .agent + " | " + .rig)
      | map({k: (.[0].model + "  agent=" + .[0].agent + "  rig=" + .[0].rig),
             t: (map(.input + .output + .cache_r + .cache_c) | add)})
      | sort_by(-.t) | .[0:5][]
      | "  - \(.k): \(.t) tokens"')"

  # once-per-24h gate, matching disk-watch/config-drift: a chronic-but-known
  # spike should not nag every cycle.
  mkdir -p "$(dirname "$MARKER")" 2>/dev/null
  if [ -f "$MARKER" ] && [ -z "$(find "$MARKER" -mmin +1440 2>/dev/null)" ]; then exit 0; fi

  gc mail send mayor -s "token-report: usage spike on $DAY" -m "Token usage on $DAY was $(printf '%s' "$SPIKE" | jq -r '.tokens') tokens — $(printf '%s' "$SPIKE" | jq -r '.ratio')x the median of prior days ($(printf '%s' "$SPIKE" | jq -r '.median')).

Top spenders that day:
$TOP

This is token volume, not dollars — this city is on Max (flat-rate), so the cost
of a spike is quota and rate-limit headroom, not a bill.

Investigate with:
  token-report.sh --by session --days 2
  token-report.sh --by agent --days 7

Most spikes are wake/respawn frequency x prompt size, not long outputs — see
packs/docs/TOKEN-HARDENING.md for the ranked levers." >/dev/null 2>&1
  touch "$MARKER" 2>/dev/null
  echo "token-report: SPIKE on $DAY — mailed mayor."
  exit 0
fi

# --- grouped report ----------------------------------------------------------
case "$BY" in
  model)      KEY='.model' ;;
  agent)      KEY='.agent' ;;
  agent-name|agent_name|instance)
              KEY='.agent_name' ;;
  rig)        KEY='.rig' ;;
  provider)   KEY='.provider' ;;
  day)        KEY='.day' ;;
  session)    KEY='.run' ;;
  prd)        KEY='(.prd // "unattributed")' ;;
  *)          KEY='.model' ;;
esac

GROUPED="$(printf '%s' "$ENRICHED" | jq -c "
  group_by($KEY)
  | map({
      key:      (.[0] | $KEY | tostring),
      calls:    length,
      input:    (map(.input)   | add),
      output:   (map(.output)  | add),
      cache_r:  (map(.cache_r) | add),
      cache_c:  (map(.cache_c) | add),
      models:   ([.[].model] | unique | join(\",\")),
      agents:   ([.[].agent] | unique | join(\",\")),
      instances: ([.[].agent_name] | unique | join(\",\")),
      beads:    ([.[].bead | select(. != null)] | unique)
    })
  | map(. + {
      total: (.input + .output + .cache_r + .cache_c),
      context_pct: ( ((.input + .cache_r + .cache_c) * 100)
                     / (if (.input + .output + .cache_r + .cache_c) > 0
                        then (.input + .output + .cache_r + .cache_c) else 1 end)
                     | round )
    })
  | sort_by(-.total)")"

if [ "$OUT" = "json" ]; then
  printf '%s\n' "$GROUPED" | jq .
  exit 0
fi

# NOTE: build the window label separately. Inlining it as
# "${DAYS:+ (last $DAYS days)}" is a PARSE ERROR in sh — an unquoted "(" inside a
# ${...:+...} word — and the shell reports it on the FOLLOWING line, which sends
# you hunting in the wrong place.
WINDOW=""
[ -n "$DAYS" ] && WINDOW=" (last $DAYS days)"

echo "Token usage by $BY$WINDOW — $TOTAL_FACTS model calls"
echo "unit: TOKENS. No USD: this city is on Max (flat-rate), so the real cost of a"
echo "spike is quota and rate-limit headroom, not a bill."
echo
printf '%-30s %6s %10s %10s %12s %11s %12s %5s\n' \
  "$(echo "$BY" | tr '[:lower:]' '[:upper:]')" "CALLS" "INPUT" "OUTPUT" "CACHE_R" "CACHE_C" "TOTAL" "CTX%"
printf '%s' "$GROUPED" | jq -r '.[] |
  [ (.key|.[0:30]), .calls, .input, .output, .cache_r, .cache_c, .total, .context_pct ]
  | @tsv' \
  | awk -F'\t' '{printf "%-30s %6s %10s %10s %12s %11s %12s %4s%%\n",$1,$2,$3,$4,$5,$6,$7,$8}'

# When grouping by something other than the agent itself, name the agents behind
# each row — a model total is not actionable until you know which lane spent it.
if [ "$BY" = "model" ] || [ "$BY" = "provider" ] || [ "$BY" = "day" ]; then
  echo
  echo "agents behind each row (definition -> running instances):"
  printf '%s' "$GROUPED" | jq -r '.[] | "  \(.key): \(.agents)  [\(.instances)]"'
fi

echo
printf '%s' "$GROUPED" | jq -r '
  (map(.total) | add) as $t
  | (map(.cache_r + .cache_c + .input) | add) as $ctx
  | "TOTAL: \($t) tokens, of which \($ctx) (\(($ctx*100/(if $t>0 then $t else 1 end))|round)%) went to re-reading context rather than producing output."'
echo "Lever for that share is wake/respawn frequency x prompt size — packs/docs/TOKEN-HARDENING.md."
exit 0
