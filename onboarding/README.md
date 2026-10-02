# Onboarding: drive switchyard from your surface

switchyard is the backlog authority; an **agent** does the work. This directory
gets any agent client connected and operating — from a single terminal to a full
Gas City fleet.

> **Standing up a whole Gas City on a fresh machine?** Don't read — delegate.
> Open a coding-agent session there and paste [`new-machine.md`](new-machine.md);
> it drives the [`gas-city.md`](gas-city.md) runbook end-to-end and stops to ask
> you at the three human gates.

## The model: one core, many front doors

Every surface below is the same two things:

1. **Reach switchyard** — register the **`switchyard-mcp`** MCP server. It's the
   universal adapter: every client here speaks MCP, so "connect to switchyard" is
   one move per client — add the server, drop in the token.
2. **Know the loop** — [`AGENTS.md`](AGENTS.md) is the shared operating manual
   (orient → triage → author → deliver → validate, over the MCP tools). Copy it
   into your project root or point your client's system prompt at it.

That's it. A **single terminal** runs one such agent; a **Gas City** runs a
*crew* of them — a pinned coordinator per rig, with the `switchyard-mcp` overlay
projected into every agent's working directory — but the brain (`AGENTS.md`)
and the connection (`switchyard-mcp`) are identical. (The `brakeman` worker
pool and the 24-hour heartbeat of timed orders shipped in the retired
`switchyard-ops` pack; those lanes run under switchyard-conductor now, outside
any city — see [`../README.md`](../README.md).)

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
| **ChatGPT** | chatgpt.com Apps & Connectors over the remote MCP connector — a URL and a browser consent, nothing installed | [`chatgpt.md`](chatgpt.md) |
| **Hermes** | Nous Research self-improving terminal agent + gateway; MCP-native, with per-server tool filtering | [`hermes.md`](hermes.md) |
| **openclaw** | cross-platform personal assistant; MCP-capable, reads workspace `AGENTS.md` | [`openclaw.md`](openclaw.md) |
| **Gas City** | the crew: a pinned coordinator per rig, every agent carrying the `switchyard-mcp` overlay — **agent-executable setup runbook** | [`gas-city.md`](gas-city.md) |

**Every light surface is the same three steps:** install the client, register
`switchyard-mcp`, add `AGENTS.md`. The per-surface page only spells out *where*
that client keeps its MCP config. **Gas City** is the heavy path — it projects
the same MCP overlay (the `switchyard-mcp` pack) into a whole rig's crew under
`gc`; start from `examples/city/`. It adds no timed orders and no worker pool
any more — those retired with `switchyard-ops`.

## Keep the fleet honest (Gas City only)

Once you're running a fleet, read [`../docs/TOKEN-HARDENING.md`](../docs/TOKEN-HARDENING.md):
`wake_mode=fresh` agents re-bill their prompt on every respawn, so an idle city
can pay for nothing unless you tune the pinned crew. Single-terminal and desktop
surfaces don't have this problem — they run one agent, on demand.
