# OpenClaw

[OpenClaw](https://openclaw.ai) — a cross-platform personal AI assistant —
driving switchyard through the `switchyard-mcp` server. OpenClaw is MCP-capable
and reads a workspace **`AGENTS.md`** natively, so both halves map cleanly.

*(Moving to Hermes? `hermes claw migrate` imports an OpenClaw setup — including
`workspace/AGENTS.md` and `SOUL.md` — see [`hermes.md`](hermes.md).)*

## 1 · Install + token

```sh
npm install -g openclaw@latest
openclaw onboard --install-daemon      # installs the Gateway daemon
switchyard-mcp login && switchyard-mcp doctor   # machine-local switchyard token
```

## 2 · Register the MCP server

OpenClaw keeps a client-side registry of outbound MCP servers and projects them
into agent runs. Add `switchyard-mcp` (a stdio server):

```sh
openclaw mcp add            # register command=switchyard-mcp (stdio); see --help for exact flags,
                            # or use the Control UI at /settings/mcp
openclaw mcp probe          # opens a live connection and lists the tools it exposes
```

Inspect without starting an agent turn: `openclaw mcp status --verbose`,
`openclaw mcp doctor`. After config changes: `openclaw mcp reload`.

## 3 · Instructions

OpenClaw reads **`workspace/AGENTS.md`** natively — copy [`AGENTS.md`](AGENTS.md)
into your OpenClaw workspace. (Persona, if you use one, goes in `SOUL.md`.)

## 4 · Verify

`openclaw mcp probe` should list the `switchyard` tools; then have the agent run
`whoami` and `get_project_briefing`.

## Scope the surface

switchyard-mcp exposes a large tool set. Use OpenClaw's per-server tool controls
(`openclaw mcp tools` / the `/settings/mcp` filter) to expose just the loop tools
in [`AGENTS.md`](AGENTS.md)'s phase table — smallest useful surface.
