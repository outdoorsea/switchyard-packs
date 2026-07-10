# Onboarding: drive switchyard from your surface

switchyard is the backlog authority; an **agent** does the work. This directory
gets any agent client connected and operating — from a single terminal to a full
Gas City fleet.

## The model: one core, many front doors

Every surface below is the same two things:

1. **Reach switchyard** — register the **`switchyard-mcp`** MCP server. It's the
   universal adapter: every client here speaks MCP, so "connect to switchyard" is
   one move per client — add the server, drop in the token.
2. **Know the loop** — [`AGENTS.md`](AGENTS.md) is the shared operating manual
   (orient → triage → author → deliver → validate, over the MCP tools). Copy it
   into your project root or point your client's system prompt at it.

That's it. A **single terminal** runs one such agent; a **Gas City** runs a
*fleet* of them — coordinators and `brakeman` workers on a 24-hour heartbeat —
but the brain (`AGENTS.md`) and the connection (`switchyard-mcp`) are identical.

## Shared prerequisites (once per machine)

1. **A switchyard token, kept machine-local** (never in a repo or client config):
   - `switchyard-mcp login` — browser flow; writes the token file every session
     reads, and registers the server with Claude Code. **Or**
   - `switchyard-gt link <CODE>` — a connect code from
     switchyard.work → *Settings → Connect a Gas Town*.
2. **The `switchyard-mcp` server on `PATH`.** Verify token resolution:
   ```sh
   switchyard-mcp doctor        # exit 0 = token resolves and switchyard.work accepts it
   ```

The MCP server resolves its token from `$SWITCHYARD_API_TOKEN` or a `chmod 600`
machine-local file — **never** hardcode it into a client's settings.

## Pick your surface

| Surface | What it is | Guide |
|---|---|---|
| **Single terminal** | one agent + `switchyard-mcp` + `AGENTS.md` — the minimal setup | [`single-terminal.md`](single-terminal.md) |
| **Claude Code desktop** | the above, plus the `plugins/switchyard` slash commands | [`claude-code.md`](claude-code.md) |
| **OpenAI desktop / Codex** | Codex or ChatGPT desktop with the MCP server; `AGENTS.md` is native | [`openai-desktop.md`](openai-desktop.md) |
| **Hermes** | Nous Research self-improving terminal agent + gateway; MCP-native, with per-server tool filtering | [`hermes.md`](hermes.md) |
| **openclaw** | cross-platform personal assistant; MCP-capable, reads workspace `AGENTS.md` | [`openclaw.md`](openclaw.md) |
| **Gas City** | the fleet: coordinators + `brakeman` workers on a heartbeat — **agent-executable setup runbook** | [`gas-city.md`](gas-city.md) |

**Every light surface is the same three steps:** install the client, register
`switchyard-mcp`, add `AGENTS.md`. The per-surface page only spells out *where*
that client keeps its MCP config. **Gas City** is the heavy path — it wraps the
same MCP overlay (`switchyard-mcp` pack) and adds the timed orders and worker
pool; start from `examples/city/`.

## Keep the fleet honest (Gas City only)

Once you're running a fleet, read [`../docs/TOKEN-HARDENING.md`](../docs/TOKEN-HARDENING.md):
`wake_mode=fresh` agents re-bill their prompt on every respawn, so an idle city
can pay for nothing unless you tune the pinned crew. Single-terminal and desktop
surfaces don't have this problem — they run one agent, on demand.
