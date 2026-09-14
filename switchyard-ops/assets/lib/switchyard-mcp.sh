# switchyard-mcp.sh — call ONE switchyard MCP tool from an ORDER, headlessly,
# over the binary's own stdio JSON-RPC transport. Sourced, not executed.
#
# WHY THIS EXISTS AT ALL. lib/switchyard-api.sh reaches switchyard over REST,
# which is the right seam for a queue probe: the server owns the answer. Some
# answers are NOT the server's. The per-skill staleness verdict list_skills
# returns is graded CLIENT-SIDE, inside switchyard-mcp (cmd/switchyard-mcp/
# skills_verdict.go), because the installed set belongs to the machine and the
# server is deliberately never told it. A headless loop that wants that verdict
# has two choices: re-implement the grading in shell — a second copy of an
# eight-reason table that drifts the first time one side is fixed alone — or
# ask the binary that owns it. This is the second choice. The MCP server speaks
# newline-delimited JSON-RPC on stdin/stdout, so a tool call is three lines in
# and one line out (switchyard PRD #375, crit:1f1d1c093760).
#
# EVERYTHING HERE FAILS OPEN TO EMPTY, as switchyard-api.sh does. No binary, no
# jq, no answer inside the deadline, a JSON-RPC error, a tool result flagged
# isError — every one is an EMPTY string on stdout, and SY_MCP_LAST_ERROR names
# the reason for a caller that wants to log it. A caller must treat empty as
# "unknown", never as "the tool returned nothing", and must never act on it.
#
# ONE CALL PER PROCESS, by design. Each sy_mcp_call starts a fresh server,
# handshakes, calls, and lets the server exit on stdin EOF. That is a few
# hundred milliseconds per call and buys the property an order actually needs:
# no long-lived child to supervise, no half-open session to leak when the order
# is killed mid-cycle. Callers that need N tool calls make N calls.
#
# THE CREDENTIAL IS THE BINARY'S OWN. switchyard-mcp resolves its token exactly
# as an interactive session would (SWITCHYARD_API_TOKEN, then its token file),
# so an order inheriting the city's environment speaks as the same identity the
# rig's agents do, and no second credential site is introduced.

# The binary to drive. Overridable so a self-test can put a stub on PATH under
# another name, and so a city can pin a specific build.
SY_MCP_BIN="${SY_MCP_BIN:-switchyard-mcp}"

# How long ONE call may wait for its answer, in seconds. Bounds the loop that
# holds stdin open below; on expiry stdin is closed, the server exits on EOF,
# and the call answers empty. Longer than switchyard-api.sh's per-call bound
# because a manifest read fans out to the source host per registered repo.
SY_MCP_MAX_TIME="${SY_MCP_MAX_TIME:-60}"

# Why the last call answered empty, for the caller's log line. Empty after a
# successful call.
SY_MCP_LAST_ERROR=""

# The protocol revision requested at the handshake. The go-sdk server
# negotiates down from a newer one and refuses none of the released
# revisions, so this pin only needs to be one it knows.
SY_MCP_PROTOCOL_VERSION="2025-03-26"

# _sy_mcp_fail REASON — record why the current call answered empty, in the
# variable for a direct caller and in the reason file for a subshell one.
_sy_mcp_fail() {
  SY_MCP_LAST_ERROR="$1"
  [ -z "$_smc_reason" ] || printf '%s' "$1" >"$_smc_reason" 2>/dev/null
}

# sy_mcp_call TOOL ARGS_JSON [REASON_FILE] — the tool's first text content on
# stdout, or EMPTY on any failure. ARGS_JSON must be a JSON object (default
# `{}`). When REASON_FILE is given, why an empty answer was empty is written
# there (and the file is emptied on success): a caller captures this function
# with `$(...)`, which is a subshell, so SY_MCP_LAST_ERROR cannot reach it.
#
# The three requests are written and then stdin is HELD OPEN until the answer
# to request id 2 has landed in the output file. That wait is not optional:
# the server treats stdin EOF as "the client left" and exits, dropping any
# in-flight call — a plain `printf ... | switchyard-mcp` closes stdin before
# the tool has run and reads nothing at all (measured, 2026-08-26). The writer
# polls the output file rather than the server's state because the pipeline
# gives it nothing else to poll, and the poll is cheap.
#
# Only the FIRST text content is returned. The server's update-signal
# middleware appends a second text block to every result while the binary is
# stale (PRD #186); that is advice for a human, not part of the tool's answer,
# and a consumer parsing the answer as JSON must not see it.
sy_mcp_call() {
  SY_MCP_LAST_ERROR=""
  _smc_tool="$1"
  _smc_args="${2:-}"
  _smc_reason="${3:-}"
  [ -n "$_smc_args" ] || _smc_args='{}'
  [ -z "$_smc_reason" ] || : >"$_smc_reason" 2>/dev/null
  command -v "$SY_MCP_BIN" >/dev/null 2>&1 || { _sy_mcp_fail "$SY_MCP_BIN is not on PATH"; return 0; }
  command -v jq >/dev/null 2>&1 || { _sy_mcp_fail "jq is not on PATH"; return 0; }
  case "$SY_MCP_MAX_TIME" in ''|*[!0-9]*) SY_MCP_MAX_TIME=60 ;; esac

  _smc_dir="$(mktemp -d "${TMPDIR:-/tmp}/sy-mcp.XXXXXX" 2>/dev/null)" || { _sy_mcp_fail "mktemp failed"; return 0; }
  _smc_out="$_smc_dir/out"
  : >"$_smc_out"

  # Build the call through jq so the arguments are validated as JSON here,
  # with a named error, rather than by the server as an opaque parse failure.
  _smc_req="$(jq -cn --arg t "$_smc_tool" --argjson a "$_smc_args" \
      '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:$t,arguments:$a}}' 2>/dev/null)"
  if [ -z "$_smc_req" ]; then
    _sy_mcp_fail "arguments for $_smc_tool are not a JSON object"
    rm -rf "$_smc_dir"
    return 0
  fi

  {
    printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"%s","capabilities":{},"clientInfo":{"name":"switchyard-ops","version":"1"}}}\n' "$SY_MCP_PROTOCOL_VERSION"
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    printf '%s\n' "$_smc_req"
    # Hold stdin open until the answer lands (or the deadline passes). Five
    # ticks a second: fine enough that a fast answer is not made slow, coarse
    # enough that the poll is not the cost.
    _smc_ticks=0
    _smc_limit=$((SY_MCP_MAX_TIME * 5))
    while [ "$_smc_ticks" -lt "$_smc_limit" ]; do
      grep -q '^{"jsonrpc":"2.0","id":2,' "$_smc_out" 2>/dev/null && break
      sleep 0.2
      _smc_ticks=$((_smc_ticks + 1))
    done
  } | "$SY_MCP_BIN" >"$_smc_out" 2>/dev/null

  # One answer line, three shapes: a JSON-RPC error, a result flagged isError
  # (the tool refused — a scope it cannot reach, a 4xx from the server), or a
  # real result. Only the last yields output; the others name themselves.
  _smc_text="$(jq -r 'select(.id == 2)
      | select(has("error") | not)
      | .result
      | select((.isError // false) | not)
      | .content[0].text // empty' "$_smc_out" 2>/dev/null)"
  if [ -z "$_smc_text" ]; then
    _smc_why="$(jq -r 'select(.id == 2)
        | (.error.message // (select(.result.isError == true) | .result.content[0].text) // empty)' "$_smc_out" 2>/dev/null | head -n1)"
    [ -n "$_smc_why" ] || _smc_why="no answer from $SY_MCP_BIN within ${SY_MCP_MAX_TIME}s"
    _sy_mcp_fail "$_smc_why"
  fi
  rm -rf "$_smc_dir"
  printf '%s' "$_smc_text"
}
