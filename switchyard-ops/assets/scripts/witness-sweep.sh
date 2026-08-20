#!/bin/sh
# witness-sweep: the pack half of the witness (switchyard PRD #357 P1).
#
# THE SERVER HALF ALREADY EXISTS (PRD #357 P0, internal/db/witness_decisions.go):
# `list_pending_decisions` serves `stuck_work` and `ready_to_merge` entries whose
# `id` is a STABLE EPISODE HASH — the same episode keeps the same id across
# reads, and a fresh lease / new head / delivery mints a new one. The decision
# inbox is therefore always current with no help from this order. What the
# server cannot do is survive a dead mayor mailbox or see gc-side state, and
# that is this order's whole duty, in three parts:
#
#   1. THE MAIL HALF OF THE DUAL-WRITE. For every witness entry the server
#      projects, mail the lane ONCE PER EPISODE, keyed on the entry's
#      (type, id) — the publish-gate pattern (a SEEN ledger, marked only after
#      the mail is DELIVERED, so a failed send retries next cycle rather than
#      dropping the one alert). The server id IS the episode fingerprint, so
#      this order never re-derives a stall predicate: a lapsed lease the
#      reclaim sweep already returned to the pool simply never appears on the
#      surface, and so files nothing here — by construction, not by filtering.
#
#   2. THE WEDGED-SESSION CHECK, which only gc can see. A worker session can
#      wedge with its turn ended and input still QUEUED — the state a transient
#      API error strands a session in. The session may hold no lease, and a
#      held one heartbeats nothing, so no server read can see it; the only
#      evidence is the pane. The signature is BOTH of: `gc session list` shows
#      the session ACTIVE with a stale last_active, AND the pane tail shows a
#      queued, unsubmitted prompt (pane-stall.sh's exact markers — not busy,
#      prompt-glyph line non-empty, placeholders excluded). The response is a
#      LADDER, one rung per cycle, keyed per session: first sighting nudges
#      once via `gc session nudge --delivery immediate` (which submits the
#      queued text AND clears the line — the complete observed fix; the default
#      wait-idle delivery submits nothing on a wedged pane, see the call site);
#      the same session still wedged on the NEXT
#      cycle is escalated by mail instead of nudged again, so a nudge-immune
#      session becomes a decision rather than a nudge loop. A session seen
#      healthy clears its marker, so the next wedge is a new episode starting
#      at nudge. Never kill, never reset — hands_off says the response is one
#      nudge then mail.
#
#   3. THE STALLED-DISPATCH-LOOP CHECK, also pack-observable only. The server's
#      stuck_work covers bead-level stalls; the DISPATCH LOOP itself wedging
#      (issue 358: pool-spawn exceeding its exec deadline every cycle while an
#      idle factory grew a 114-bead pool) is visible only in the supervisor
#      log's order-failure lines, which nothing else consumes. The signature is
#      ALL THREE of: the rig's cloud claim pool holds claimable beads (`total`
#      from `?limit=1`, a confident read), NO live worker session exists for
#      the rig (the same .template join pool-spawn counts capacity with), and
#      the dispatch order's last cycle did not complete — a recent
#      `gc: order exec <order> failed:` (deadline exceeded, a timeout exit) or
#      a circuit-breaker `skipped` line in the supervisor log. One mail per
#      continuous episode (a marker, cleared on the first confidently-healthy
#      read), naming the manual unstick: `gc order run pool-spawn`. A loop
#      merely between cycles (no recent failure) or a rig whose pool is empty
#      files NOTHING — silence is the success case.
#
# EVERY UNCERTAIN READ DECLINES TO ACT. An unreadable decisions surface, session
# roster, pane, pool or log neither mails nor clears an episode marker: the
# witness must not alarm on noise (a false stall report is how an escalation
# channel gets filtered) and must not forget an episode because one read
# blipped (forgetting is how a nudge ladder becomes a nudge loop). The one
# exception is the decisions surface itself going unreadable, which is mailed
# once per outage — a dead credential would otherwise disable the witness with
# no signal, the exact failure class this pack exists to end.
#
# OPT-IN, PER RIG. WITNESS_RIGS in the city's roster.conf names the rigs swept
# (the CLOUD_POOL_RIGS / VALIDATE_RIGS precedent). Unset means this order exits
# without reading anything: a city that never enables it never notices it.
set -u

. "$(dirname "$0")/../lib/roster.sh"
. "$(dirname "$0")/../lib/switchyard-api.sh"

# roster.conf is the ONLY source of WITNESS_RIGS; see the repair-sweep header
# for the measured cost of omitting this call.
sy_load_conf

# Opt-in rig list. Unset = witness off everywhere.
WITNESS_RIGS="${WITNESS_RIGS:-}"
# The dispatch order whose last-cycle outcome part 3 reads.
WITNESS_DISPATCH_ORDER="${WITNESS_DISPATCH_ORDER:-pool-spawn}"
# Where gc's supervisor logs order outcomes. The failure lines land in the
# operator's home-scoped log, not under the city, so the default is $HOME.
WITNESS_SUPERVISOR_LOG="${WITNESS_SUPERVISOR_LOG:-$HOME/.gc/supervisor.log}"
# How recent a dispatch failure must be to count as "the last cycle did not
# complete". A wedged loop re-fails every cycle (1-2m cadence), so any live
# episode always has a failure far younger than this; a recovered loop's
# failures age out within the window. Comfortably wider than this order's own
# 30m cadence so a failure can never fall between two sweeps.
WITNESS_DISPATCH_FAIL_WINDOW="${WITNESS_DISPATCH_FAIL_WINDOW:-2700}"
# How stale an ACTIVE session's last_active must be before the pane is even
# read. A session mid-turn updates this; a wedged one stopped when its turn
# ended with the input still queued.
WITNESS_WEDGE_IDLE_SECONDS="${WITNESS_WEDGE_IDLE_SECONDS:-900}"
case "$WITNESS_DISPATCH_FAIL_WINDOW" in ''|*[!0-9]*) WITNESS_DISPATCH_FAIL_WINDOW=2700 ;; esac
case "$WITNESS_WEDGE_IDLE_SECONDS" in ''|*[!0-9]*) WITNESS_WEDGE_IDLE_SECONDS=900 ;; esac

[ -n "$WITNESS_RIGS" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

state="$(sy_state_dir)"
mkdir -p "$state" 2>/dev/null || exit 0

# The once-per-episode SEEN ledger for the dual-write's mail half, keyed
# "<rig> <type>/<id>" — the server entry's identity IS the episode fingerprint.
SEEN="$state/witness-sweep.reported"
[ -f "$SEEN" ] || : > "$SEEN"

# w_mail SUBJECT BODY — the lane mail. Returns the send's own status so callers
# can mark AFTER delivery (publish-gate's safety-net ordering: nothing is
# marked unless the mail went out, and the next cycle retries).
w_mail() {
  gc mail send mayor -s "$1" -m "$2" >/dev/null 2>&1
}

# w_mail_once KEY SUBJECT BODY — one mail per distinct standing fault, cleared
# by w_clear_fault when the fault stops being observed (validate-sweep's
# vs_mail_once pattern).
w_mail_once() {
  _mk="$state/witness-sweep.alert.$1"
  [ -f "$_mk" ] && return 0
  w_mail "$2" "$3" && : >"$_mk" 2>/dev/null || true
}
w_clear_fault() { rm -f "$state/witness-sweep.alert.$1" 2>/dev/null || true; }

# w_safe NAME — sanitize an arbitrary identifier into a state-file suffix. A
# session ref or rig name reaches this script from gc, and one `/` in it would
# otherwise write outside the state directory (the lane_rung_file rule).
w_safe() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

w_now() { date +%s 2>/dev/null || printf '0'; }

# w_epoch_iso TS — RFC3339 (with Z or ±HH:MM offset) to epoch; empty when it
# cannot be parsed. BSD `date -j -f` is tried first (macOS is where cities
# run; on GNU `-j` fails cleanly), then GNU `date -d`. An unparseable stamp
# yields empty and the caller DECLINES — never a guessed zero that would read
# as infinitely stale.
w_epoch_iso() {
  _wei_t="$(printf '%s' "$1" | sed 's/Z$/+0000/; s/\([+-][0-9][0-9]\):\([0-9][0-9]\)$/\1\2/')"
  date -j -f '%Y-%m-%dT%H:%M:%S%z' "$_wei_t" +%s 2>/dev/null && return 0
  date -d "$1" +%s 2>/dev/null
}

# w_epoch_log TS — the supervisor log's local-time "YYYY/MM/DD HH:MM:SS" to
# epoch; empty when unparseable, same decline rule.
w_epoch_log() {
  date -j -f '%Y/%m/%d %H:%M:%S' "$1" +%s 2>/dev/null && return 0
  date -d "$(printf '%s' "$1" | tr '/' '-')" +%s 2>/dev/null
}

# The tmux socket for the pane reads — same resolution ladder, same reasons, as
# lane-ensure's lane_tmux_socket: GC_TMUX_SOCKET (gc's own knob), then $TMUX's
# socket-path basename, then the city name (what gc names the socket after,
# and the case that applies to an order).
w_tmux_socket() {
  if [ -n "${GC_TMUX_SOCKET:-}" ]; then printf '%s' "$GC_TMUX_SOCKET"; return 0; fi
  if [ -n "${TMUX:-}" ]; then
    _wts="${TMUX%%,*}"; _wts="${_wts##*/}"
    if [ -n "$_wts" ]; then printf '%s' "$_wts"; return 0; fi
  fi
  printf '%s' "$(sy_city_name)"
}
W_SOCKET="$(w_tmux_socket)"

# Pane markers — pane-stall.sh's, verbatim, because they are the measured
# signature: `esc to interrupt` is present for the whole of a turn and gone the
# moment it ends, and the prompt glyph marks the input line whose non-empty
# remainder is text that never became a turn.
W_BUSY_MARKER='esc to interrupt'
W_PROMPT_GLYPH='❯'

# w_pane_queued SESSION_NAME — echo the queued, unsubmitted prompt text on
# SESSION_NAME's pane, `__BUSY__`/`__CLEAR__` for a confirmed-healthy pane, or
# NOTHING when the pane could not be read (a session we cannot see is never one
# we nudge, and never one whose episode we forget).
w_pane_queued() {
  _wpq_cap="$(tmux -L "$W_SOCKET" capture-pane -p -t "$1" 2>/dev/null)" || return 0
  [ -n "$_wpq_cap" ] || return 0
  if printf '%s' "$_wpq_cap" | grep -qF "$W_BUSY_MARKER"; then
    printf '__BUSY__'
    return 0
  fi
  _wpq_pending="$(printf '%s\n' "$_wpq_cap" \
    | grep -E "^[[:space:]]*$W_PROMPT_GLYPH" \
    | tail -1 \
    | sed "s/^[[:space:]]*$W_PROMPT_GLYPH//" \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [ -z "$_wpq_pending" ]; then
    printf '__CLEAR__'
    return 0
  fi
  # Placeholders and hints are not pending input (pane-stall's exclusions).
  case "$_wpq_pending" in
    "Press up"*|"Try "*|"/"*|"Chat about"*) printf '__CLEAR__'; return 0 ;;
  esac
  printf '%s' "$_wpq_pending"
}

# Session states that count as a live WORKER for the dispatch-stall check —
# pool-spawn's POOL_LIVE_STATES, so "does anyone hold this rig's WIP slot" is
# answered the same way pack-wide.
W_LIVE_STATES="active start-pending start_pending creating draining"

# ---------------------------------------------------------------------------
# Part 1 + 3 need the switchyard credential; part 2 does not. A missing
# credential therefore degrades the sweep rather than aborting it — the wedge
# check is gc-only and keeps running — but the degradation is SAID, once,
# because a silently-dead credential would disable the dual-write's mail half
# with every surface reading healthy.
# ---------------------------------------------------------------------------
token="$(sy_api_token)"
projects=""
if [ -n "$token" ]; then
  projects="$(sy_api_projects "$token")"
fi
if [ -z "$token" ] || [ -z "$projects" ]; then
  w_mail_once "credential" \
    "witness-sweep: switchyard unreadable — the stuck-work dual-write is down" \
    "The witness sweep could not resolve a usable switchyard credential or project list (no sy_ token, or the instance did not answer). The wedged-session check still runs, but NO stuck_work / ready_to_merge decision is being mailed and the dispatch-stall check cannot read pool depth. Install SWITCHYARD_API_TOKEN (or the switchyard-mcp CLI token) for the order's environment."
else
  w_clear_fault "credential"
fi

# ONE session-roster read per cycle (roster.sh's own remedy — cost and
# COHERENCE: every rig is judged against the same snapshot). Empty/unreadable
# is UNKNOWN: parts 2 and 3 decline for the cycle, clearing nothing.
roster="$(sy_timeout 120 gc session list --json --state all 2>/dev/null)" || roster=""
now="$(w_now)"

# The wedge refs CONFIRMED healthy this cycle, and those observed at all —
# written to files because the observation loop runs in a pipe subshell.
W_WEDGE_CLEARED="$(mktemp "${TMPDIR:-/tmp}/witness-cleared.XXXXXX" 2>/dev/null)" || exit 0
trap 'rm -f "$W_WEDGE_CLEARED" "$W_WEDGE_CLEARED.pending"' EXIT

for rig in $WITNESS_RIGS; do
  # ------------------------------------------------------------------ part 1
  # The dual-write's mail half: every witness entry on the server surface that
  # this city has not yet mailed, keyed (type, id). The surface itself is the
  # stall predicate — a reclaimed lease is absent from it and files nothing.
  project=""
  if [ -n "$token" ] && [ -n "$projects" ]; then
    project="$(sy_project_for_rig "$rig" "$projects")"
    if [ -z "$project" ]; then
      w_mail_once "scope-$(w_safe "$rig")" \
        "witness-sweep: rig $rig resolves to no project" \
        "WITNESS_RIGS names '$rig' but sy_project_for_rig resolved nothing. Check RIG_PROJECTS in roster.conf. No decision is dual-written for it until this is fixed (the wedge check still runs)."
    else
      w_clear_fault "scope-$(w_safe "$rig")"
    fi
  fi

  if [ -n "$project" ]; then
    body="$(sy_api_get "/api/v1/projects/$project/pending-decisions" "$token")"
    if [ -z "$body" ]; then
      w_mail_once "decisions-$(w_safe "$rig")" \
        "witness-sweep: pending-decisions unreadable for $rig" \
        "GET /pending-decisions on $project returned nothing. The stuck-work dual-write for $rig is mailing nothing until this clears."
    else
      w_clear_fault "decisions-$(w_safe "$rig")"
      # `.decisions` must be an ARRAY — the lane-ensure strictness rule: a 200
      # without the key must read as unreadable, never as an empty queue.
      entries="$(printf '%s' "$body" | jq -r '
        if (.decisions|type) == "array" then
          .decisions[]
          | select((.type // "") == "stuck_work" or (.type // "") == "ready_to_merge")
          | [(.type // ""), (.id // 0 | tostring), (.title // "")] | @tsv
        else empty end' 2>/dev/null)"
      new_lines=""
      if [ -n "$entries" ]; then
        _tab="$(printf '\t')"
        while IFS="$_tab" read -r _wtype _wid _wtitle; do
          [ -n "${_wtype:-}" ] && [ -n "${_wid:-}" ] || continue
          key="$rig $_wtype/$_wid"
          grep -qxF "$key" "$SEEN" 2>/dev/null && continue
          new_lines="$new_lines
  [$_wtype/$_wid] $_wtitle"
          printf '%s\n' "$key" >> "$W_WEDGE_CLEARED.pending" 2>/dev/null || true
        done <<EOF
$entries
EOF
      fi
      if [ -n "$new_lines" ]; then
        if w_mail "witness-sweep: stuck work / ready-to-merge decisions on $rig" \
          "The witness surface for $project holds decision entries not yet mailed. Each is ONE episode (the id is the server's stable episode hash; a fresh lease, new head or delivery mints a new id and will be mailed again):$new_lines

These same entries are live in the project's decision inbox (list_pending_decisions / the dashboard inbox) and each clears itself the moment its condition clears. The titles above name the action that clears each one. This mail exists so the escalation survives a dead mayor mailbox; each episode is mailed once."; then
          # Delivered — NOW the episodes are reported, never again.
          cat "$W_WEDGE_CLEARED.pending" >> "$SEEN" 2>/dev/null || true
          echo "witness-sweep: $rig mailed $(grep -c . "$W_WEDGE_CLEARED.pending" 2>/dev/null || echo '?') new decision episode(s)"
        else
          echo "witness-sweep: $rig alert delivery FAILED; episodes stay unreported so the next cycle retries" >&2
        fi
      fi
      rm -f "$W_WEDGE_CLEARED.pending" 2>/dev/null
    fi
  fi

  # ------------------------------------------------------------------ part 2
  # The wedged-session ladder. Candidates: this rig's non-closed ACTIVE
  # sessions. The verdict needs the pane, so state alone never acts.
  if [ -n "$roster" ]; then
    printf '%s' "$roster" | jq -r --arg rig "$rig" '
        (.sessions // [])[]
        | select((.closed // false) | not)
        | select((.state // "") == "active")
        | select(((.rig // "") == $rig)
                 or ((.name // .agent_name // "") | startswith($rig + "/")))
        | [(.alias // .id // .name // ""), (.session_name // ""), (.last_active // "")]
        | @tsv' 2>/dev/null \
    | while IFS="$(printf '\t')" read -r w_ref w_pane w_last; do
        [ -n "${w_ref:-}" ] || continue
        w_marker="$state/witness-sweep.wedge.$(w_safe "$w_ref")"
        # Stale-active is half the signature. Unparseable/missing last_active
        # declines (neither acts nor clears): a fresh turn updates it, so a
        # session we cannot age is one we do not touch.
        w_epoch=""
        [ -n "${w_last:-}" ] && w_epoch="$(w_epoch_iso "$w_last")"
        if [ -z "$w_epoch" ] || [ "$now" -le 0 ]; then
          continue
        fi
        if [ "$(( now - w_epoch ))" -lt "$WITNESS_WEDGE_IDLE_SECONDS" ]; then
          # Recently active: confirmed not wedged. The episode (if any) is over.
          printf '%s\n' "$w_ref" >> "$W_WEDGE_CLEARED"
          continue
        fi
        # A session with no pane name cannot be read; decline.
        [ -n "${w_pane:-}" ] || continue
        w_queued="$(w_pane_queued "$w_pane")"
        case "$w_queued" in
          '') continue ;;                       # unreadable pane: decline
          __BUSY__|__CLEAR__)
            printf '%s\n' "$w_ref" >> "$W_WEDGE_CLEARED"
            continue ;;
        esac
        # WEDGED: active, stale, input queued. One rung per cycle.
        if [ ! -f "$w_marker" ]; then
          # Rung 1: one nudge. The nudge must type text + Enter to SUBMIT the
          # queued prompt — that submission is the entire fix, not the message.
          #
          # ⛔ `--delivery immediate` IS LOAD-BEARING, NOT A TUNING KNOB. The
          # default is `wait-idle`, which appends the text and waits for an idle
          # boundary to submit. A wedged pane never reaches that boundary — its
          # turn already ended with input queued — so the default delivers
          # NOTHING and additionally leaves its own text on the dirty line,
          # where the next nudge is appended to the fragment and submitted as
          # one corrupted string. That is the failure this rung was written to
          # cure, so the default made rung 1 a no-op and every wedge fell
          # through to rung 2's mail. `immediate` submits AND clears the line.
          # If this flag is ever dropped, the ladder goes silently dead again.
          #
          # The marker is written whether or not the nudge delivered (a rung
          # TRIED is a rung spent; retrying it forever is the loop this ladder
          # replaces).
          gc session nudge "$w_ref" --delivery immediate "witness-sweep: your last turn ended with input still queued and no activity for $(( now - w_epoch ))s. This nudge submits the queued prompt; continue where you left off." >/dev/null 2>&1 || true
          printf 'nudged\n' > "$w_marker" 2>/dev/null || true
          echo "witness-sweep: $rig session $w_ref is wedged (input queued, idle $(( now - w_epoch ))s) — nudged once"
        elif [ "$(awk 'NF{print;exit}' "$w_marker" 2>/dev/null)" = "nudged" ]; then
          # Rung 2: still wedged a cycle after its nudge — nudge-immune. Mail
          # instead of nudging again; marked only after delivery so a failed
          # send retries.
          if w_mail "witness-sweep: wedged session $w_ref did not recover after a nudge" \
            "Session $w_ref on rig $rig is ACTIVE with a stale last_active and a queued, unsubmitted prompt on its pane — the wedge a transient API error strands a session in, which no server-side read can see. It was nudged once on the previous sweep cycle and is still in the same state, so it is being escalated rather than nudged again.

Queued input (first 72 chars): $(printf '%s' "$w_queued" | cut -c1-72)

Attach and act on it yourself:

  tmux -L $W_SOCKET attach -t $w_pane     # Enter submits the queued prompt; Ctrl-U clears it

The witness never kills or resets a session — one nudge, then this mail. This episode is reported once; a session that recovers and wedges again starts a new episode."; then
            printf 'escalated\n' > "$w_marker" 2>/dev/null || true
            echo "witness-sweep: $rig session $w_ref still wedged after nudge — escalated by mail"
          fi
        fi
        # stage "escalated": the episode is fully reported; silence until it
        # clears (the marker is removed below when the session reads healthy).
      done
  fi

  # ------------------------------------------------------------------ part 3
  # The stalled dispatch loop: pool has work + no live worker + the dispatch
  # order's last cycle did not complete. All three legs must hold CONFIDENTLY;
  # any uncertain read declines, and any confidently-failed leg ends the
  # episode.
  w_dmarker="$state/witness-sweep.dispatch.$(w_safe "$rig")"
  w_depth=""
  if [ -n "$project" ]; then
    _pd_body="$(sy_api_get "/api/v1/projects/$project/pool?limit=1" "$token")"
    if [ -n "$_pd_body" ]; then
      w_depth="$(printf '%s' "$_pd_body" | jq -r '.total // empty' 2>/dev/null | awk 'NF' | head -n1)"
      case "${w_depth:-}" in ''|*[!0-9]*) w_depth="" ;; esac
    fi
  fi

  # Live workers for the rig — the same .template join pool-spawn's capacity
  # census uses, against the cycle snapshot. Empty roster = UNKNOWN.
  w_workers=""
  if [ -n "$roster" ]; then
    _states_json="$(printf '%s' "$W_LIVE_STATES" | jq -Rc 'split(" ")')"
    w_workers="$(printf '%s' "$roster" | jq -r --arg q "$rig/$SY_NS.brakeman" --argjson live "$_states_json" '
      [ (.sessions // [])[]
        | select((.closed // false) | not)
        | (.agent // .agent_name // .qualified_name // "") as $n
        | select( (.template // "") == $q
                  or $n == $q
                  or ($n | startswith($q + "-adhoc-")) )
        | select( (.state // "") as $st | ($live | index($st)) != null )
      ] | length' 2>/dev/null | awk 'NF' | head -n1)"
    case "${w_workers:-}" in ''|*[!0-9]*) w_workers="" ;; esac
  fi

  # The dispatch order's last-cycle outcome, from the supervisor log's
  # timestamped failure lines: `gc: order exec <order> failed: ...` (deadline
  # exceeded, a timeout exit) or a circuit-breaker `skipped` line. The leg
  # holds only when the newest such line is inside the recency window — a
  # wedged loop re-fails every cycle, so a live episode always has a fresh
  # line, while a recovered loop's failures age out. An absent/unreadable log
  # is UNKNOWN (decline, no clear); a readable log with no recent failure is a
  # confident "between cycles" and files nothing.
  w_fail_recent=""
  w_fail_known=""
  if [ -r "$WITNESS_SUPERVISOR_LOG" ]; then
    w_fail_known=1
    _wf_line="$(grep -E "gc: order (exec )?$WITNESS_DISPATCH_ORDER (failed|skipped)[: ]" "$WITNESS_SUPERVISOR_LOG" 2>/dev/null \
      | grep -E '^[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} ' | tail -n1)"
    if [ -n "$_wf_line" ]; then
      _wf_ts="$(printf '%s' "$_wf_line" | cut -d' ' -f1-2)"
      _wf_epoch="$(w_epoch_log "$_wf_ts")"
      if [ -z "$_wf_epoch" ]; then
        w_fail_known=""   # unparseable stamp: UNKNOWN, decline
      elif [ "$now" -gt 0 ] && [ "$(( now - _wf_epoch ))" -le "$WITNESS_DISPATCH_FAIL_WINDOW" ]; then
        w_fail_recent=1
      fi
    fi
  fi

  if [ -n "$w_depth" ] && [ "$w_depth" -gt 0 ] && [ "$w_workers" = "0" ] && [ -n "$w_fail_recent" ]; then
    if [ ! -f "$w_dmarker" ]; then
      if w_mail "witness-sweep: dispatch loop stalled on $rig — $w_depth claimable bead(s), zero workers" \
        "Rig $rig is an idle factory with a full queue: its cloud claim pool holds $w_depth claimable bead(s), NO live worker session exists for it, and the dispatch order's last cycle did not complete ($WITNESS_SUPERVISOR_LOG shows a recent 'order exec $WITNESS_DISPATCH_ORDER' failure/skip). Nothing will claim this work until the loop is unstuck, and the condition self-amplifies: an idle factory grows the pool, which slows the demand read, which makes the next deadline likelier.

Manual unstick:

  gc order run $WITNESS_DISPATCH_ORDER

Then watch one cycle complete (tail $WITNESS_SUPERVISOR_LOG). This episode is reported once; it clears itself when the pool drains, a worker goes live, or the failures stop, and a later stall is a new episode."; then
        : > "$w_dmarker" 2>/dev/null || true
        echo "witness-sweep: $rig dispatch loop stalled ($w_depth beads, 0 workers, recent $WITNESS_DISPATCH_ORDER failure) — escalated"
      fi
    fi
  else
    # End the episode ONLY on a confident healthy leg: an empty pool, a live
    # worker, or a readable log with no recent failure. Uncertainty keeps the
    # marker so a blipped read cannot re-arm the mail.
    if { [ -n "$w_depth" ] && [ "$w_depth" -eq 0 ]; } \
       || { [ -n "$w_workers" ] && [ "$w_workers" -gt 0 ]; } \
       || { [ -n "$w_fail_known" ] && [ -z "$w_fail_recent" ]; }; then
      rm -f "$w_dmarker" 2>/dev/null || true
    fi
  fi
done

# Wedge episodes end when their session is CONFIRMED healthy (recently active,
# busy, or a clear prompt) — collected above, applied here so the next wedge of
# the same session starts a fresh episode at the nudge rung. Sessions that
# merely could not be read keep their markers: forgetting an episode on a
# blipped read is how a ladder becomes a loop.
if [ -s "$W_WEDGE_CLEARED" ]; then
  while read -r w_ref; do
    [ -n "$w_ref" ] || continue
    rm -f "$state/witness-sweep.wedge.$(w_safe "$w_ref")" 2>/dev/null || true
  done < "$W_WEDGE_CLEARED"
fi

# Mail health is not order health (publish-gate's rule): retries are carried by
# the unmarked ledgers above, not by the exit code.
exit 0
