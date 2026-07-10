# Claude Code

Claude Code (CLI or desktop) driving switchyard through the `switchyard-mcp`
server, plus the optional `plugins/switchyard` slash commands.

## 1 · Token + MCP server

```sh
switchyard-mcp login     # browser flow: writes the machine-local token AND
                         # registers the MCP server with Claude Code
switchyard-mcp doctor    # verify the token resolves
```

`login` usually registers the server for you. If `claude mcp list` doesn't show
`switchyard` as connected, add it explicitly:

```sh
claude mcp add switchyard -- switchyard-mcp
```

…or per-project, in `.mcp.json` at the repo root:

```json
{ "mcpServers": { "switchyard": { "command": "switchyard-mcp" } } }
```

Confirm: `claude mcp list` → `switchyard` connected, or `/mcp` inside a session.

## 2 · Instructions

Copy [`AGENTS.md`](AGENTS.md) into your project root. Claude Code reads both
`AGENTS.md` and `CLAUDE.md` — keep switchyard behavior in `AGENTS.md` so it stays
portable to the other surfaces; use `CLAUDE.md` only for repo-specific notes.

## 3 · Slash commands (optional, recommended)

The switchyard repo ships a Claude Code plugin, **`plugins/switchyard`**, exposing
`/switchyard:*` commands for driving switchyard *by hand*. Add it through
`/plugin` (point Claude Code at the plugin's marketplace/repo, then install
`switchyard`). It complements the MCP server — the plugin is for a human driving
switchyard interactively; the MCP tools are for the agent's autonomous loop. You
can run either or both.

## 4 · Verify

In a session, run `/mcp` (or ask the agent to list its switchyard tools), then
have it call `whoami` and `get_project_briefing`. Account + briefing = wired.

## Scale up

A Claude Code session is one agent. To run a *fleet* of them on a heartbeat
(coordinators + `brakeman` workers), that's a **Gas City** — the pack layer wraps
this same `switchyard-mcp` server. See [`../examples/city/`](../examples/city/README.md)
and [`../docs/TOKEN-HARDENING.md`](../docs/TOKEN-HARDENING.md).
