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

## Configure switchyard-ops for this city

Everything city-specific lives outside the pack, in an un-versioned file:

```sh
cp "$(gc import why switchyard-ops --path)/assets/roster.conf.example" \
   "<city>/.gc/runtime/packs/switchyard-ops/roster.conf"
```

With no `roster.conf` at all, switchyard-ops still works: it derives its roster
from `gc agent list --json` (every agent with `pool.min >= 1` that is not
suspended). You only need the file for singleton aliases and the retro agent.

## Get the switchyard MCP working

The `switchyard-mcp` overlay ships no token, on purpose.

```sh
go build -o ~/.local/bin/switchyard-mcp ./cmd/switchyard-mcp   # from the switchyard repo
switchyard-mcp login                                            # writes a machine-local token
switchyard-mcp doctor                                           # verify resolution
```

Never put `SWITCHYARD_API_TOKEN` in `overlay/.claude/settings.json` — that
leaks it into git. The server resolves the token from the environment or a
`chmod 600` token file.

## Keep it honest

If your city root is a git repo, the `config-drift` order mails the mayor when
tracked config diverges from `HEAD`. Track `pack.toml`, `packs.lock`, and your
agent definitions; **never** track `.gc/`, `.beads/`, worktrees, or `.env`. Use
a whitelist `.gitignore` (ignore `/*`, then re-include) — a blacklist leaks the
first artifact nobody thought of.
