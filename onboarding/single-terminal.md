# Single terminal

The minimal setup: **one** terminal agent, the `switchyard-mcp` server over
stdio, and [`AGENTS.md`](AGENTS.md). No fleet, no timed orders — the agent runs
on demand when you invoke it, does the switchyard loop serially, and exits.

This is the vendor-neutral pattern. For the exact command your client wants, see
[`claude-code.md`](claude-code.md) or [`openai-desktop.md`](openai-desktop.md).

## 1 · Prereqs (see [`README.md`](README.md))

```sh
switchyard-mcp login     # machine-local token
switchyard-mcp doctor    # exit 0 = token resolves
```

## 2 · Register the MCP server

`switchyard-mcp` with **no arguments** is a stdio MCP server. Every MCP-capable
client reads roughly this shape — only the config file location differs:

```json
{
  "mcpServers": {
    "switchyard": { "command": "switchyard-mcp" }
  }
}
```

Concretely, per client:

| Client | How |
|---|---|
| Claude Code CLI | `claude mcp add switchyard -- switchyard-mcp` (or `switchyard-mcp login` wires it for you) |
| Codex CLI | add `[mcp_servers.switchyard]` to `~/.codex/config.toml` |
| other | drop the JSON above into that client's MCP config |

## 3 · Adopt the instructions

Copy [`AGENTS.md`](AGENTS.md) to your **project root** (or your home dir for a
global default). Codex reads `AGENTS.md` natively; Claude Code reads both
`AGENTS.md` and `CLAUDE.md`.

## 4 · Verify

Start your agent and ask it to run `whoami`, then `get_project_briefing`, over
the switchyard tools. Account + a project briefing back = you're wired.

## Then what

Everything in [`AGENTS.md`](AGENTS.md): triage intake, author a PRD, claim and
deliver a bead, validate. One agent, serially. When one terminal isn't enough,
the same MCP server and manual scale up to a **Gas City** fleet — see
[`../examples/city/`](../examples/city/README.md).
