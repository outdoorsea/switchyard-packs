# Example city

A minimal, working starting point for a Gas City driven by switchyard. Copy
these into a fresh city root and edit.

```
<city>/
  pack.toml            <- from examples/city/pack.toml   (which packs, pinned)
  city.toml            <- from examples/city/city.toml   (which rigs, this box)
  tmux-userbindings.sh <- optional
```

> **Setting up a new machine?** The guided, agent-executable runbook is
> [`../../onboarding/gas-city.md`](../../onboarding/gas-city.md) — this page is the
> reference for the files it seeds. The shipped `city.toml` also carries a
> commented **token-hardening** block; read
> [`../../docs/TOKEN-HARDENING.md`](../../docs/TOKEN-HARDENING.md) before you
> uncomment it (the witness relaxation is non-Bedrock only).

## Bring it up

```sh
gc import install                 # fetch the pinned packs into ~/.gc/cache
gc doctor --fix                   # migrate/repair pack composition
gc register && gc start           # register the city, start the supervisor
```

`gc import install` does **not** materialize formulas — the supervisor reconcile
does, a tick later. If `gc bd formula list` looks short immediately after an
install, wait a cycle before concluding anything is wrong.

## Nothing to configure for the heartbeat — it retired

This section used to tell you to copy `switchyard-ops`' `roster.conf.example`
into the installed pack runtime and set its per-lane opt-ins (and, later, the
`BALANCER_*` bounds that were the factory balancer's only switch). Both the file
and the pack that read it are gone — `switchyard-ops` is retired and no longer
on the mirror (see [`../../README.md`](../../README.md)) — so there is nothing
to create here. `switchyard-mcp` reads no roster: a rig's switchyard scope comes
from the MCP scope resolver and the `rig { action: "bind" }` binding
([docs/city-setup.md](../../../docs/city-setup.md#4-rosterconf--retired-with-the-pack-that-read-it)).
The lanes those opt-ins gated run under
[switchyard-conductor](https://github.com/outdoorsea/switchyard-conductor),
which holds its own configuration outside this city.

## Get the switchyard MCP working

The `switchyard-mcp` overlay ships no token, on purpose.

```sh
go build -o ~/.local/bin/switchyard-mcp ./cmd/switchyard-mcp   # from the switchyard repo
switchyard-mcp login                                            # writes a machine-local token
switchyard-mcp doctor                                           # verify resolution
```

The overlay is two files: `overlay/.mcp.json` declares the server, and
`enabledMcpjsonServers` in `overlay/.claude/settings.json` pre-trusts it so an
unattended session is not stopped by a trust prompt. Never put
`SWITCHYARD_API_TOKEN` in either — that leaks it into git and onto the public
packs mirror. The server resolves the token from the environment or a
`chmod 600` token file.

## Keep it honest

If your city root is a git repo, track `pack.toml`, `packs.lock`, and your
agent definitions (the `config-drift` order that mailed the mayor when they
diverged from `HEAD` retired with `switchyard-ops`, so the diff is yours to
run); **never** track `.gc/`, `.beads/`, worktrees, or `.env`. Use
a whitelist `.gitignore` (ignore `/*`, then re-include) — a blacklist leaks the
first artifact nobody thought of.
