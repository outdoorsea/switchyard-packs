# OpenAI desktop / Codex

OpenAI's coding agents — **Codex** (CLI or IDE extension) and the **ChatGPT
desktop** app — driving switchyard through the `switchyard-mcp` server. `AGENTS.md`
is native to Codex, so the instruction half is free.

## 1 · Token + binary

```sh
switchyard-mcp login     # machine-local token
switchyard-mcp doctor    # exit 0 = resolves
```

## 2 · Register the MCP server

**Codex CLI** — add to `~/.codex/config.toml`:

```toml
[mcp_servers.switchyard]
command = "switchyard-mcp"
# args = []            # none needed — bare switchyard-mcp is a stdio server
# env  = { }           # token resolves from the machine-local file, not here
```

Restart Codex; it launches the stdio server per session. List/inspect configured
servers with Codex's MCP command to confirm `switchyard` is present.

**ChatGPT desktop** — add `switchyard-mcp` as an MCP server / connector in
Settings; the launch command is `switchyard-mcp` (stdio). The exact settings
location moves between versions, so follow the app's current "add MCP server"
flow.

## 3 · Instructions

Codex reads `AGENTS.md` natively — copy [`AGENTS.md`](AGENTS.md) to your project
root, and/or `~/.codex/AGENTS.md` for a machine-wide default. It layers: repo
`AGENTS.md` overrides the global one.

## 4 · Verify

Ask the agent to call `whoami`, then `get_project_briefing`, over the switchyard
tools. Account + briefing back = wired.

## Note

Keep the token out of `config.toml`/connector `env` — `switchyard-mcp` resolves
it from `$SWITCHYARD_API_TOKEN` or the `chmod 600` machine-local file, which keeps
the secret out of any config a tool might sync or commit.
