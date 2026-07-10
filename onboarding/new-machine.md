# New-machine handoff

Bootstrapping a Gas City for switchyard on a fresh machine? Open a coding-agent
session there (Claude Code, Codex, Hermes, OpenClaw, …) and **paste the block
below**. It points the agent at the canonical runbook, sets the guardrails, and
tells it exactly when to stop and ask you. You supply three things when it asks —
listed at the bottom.

---

```text
You are setting up a Gas City for switchyard on THIS fresh machine, from zero.

Authoritative instructions — fetch and follow, in order:
- Runbook:  https://raw.githubusercontent.com/outdoorsea/switchyard-packs/main/onboarding/gas-city.md
- Operating manual (adopt as AGENTS.md):
            https://raw.githubusercontent.com/outdoorsea/switchyard-packs/main/onboarding/AGENTS.md

Execution rules:
- Do the runbook's steps IN ORDER. After each step run its checkpoint; if the
  checkpoint fails, show me the output and STOP — do not continue.
- Create the city with `gc init --no-start` (per Step 3). Do NOT start the town
  (`gc start`, Step 5) until its rig, packs, and token-hardening are in place
  (Steps 4 and 7). No live agents before then.
- STOP and ask me at every step marked (HUMAN). There are three:
    1. Step 2 — how to obtain the `switchyard-mcp` binary.
    2. Step 4 — which product repo to make the first rig, and its name + prefix.
    3. Step 8 — the `switchyard-gt link <CODE>` connect code.
  I will paste each value when you reach it.
- The switchyard token stays machine-local (`switchyard-mcp login`) — never write
  it into any config file.
- If this machine already runs another Gas City, `gc start`/`register` reconciles
  the shared supervisor and briefly cycles that city's in-flight work. Expected.

Done when ALL of these hold:
- `switchyard-mcp doctor` exits 0 (token resolves, server accepts it),
- `gc dolt health` is healthy and `gc agent list` shows a `brakeman` pool in the rig,
- over the switchyard MCP, `whoami` -> `list_projects` -> `get_project_briefing`
  returns my projects and a claimable-work count.

Finish by pasting back the `whoami` result and one `get_project_briefing`, so I
can confirm the new town inherited the switchyard backlog. Then stop — do not
start claiming/working beads until I say go.
```

---

## Have these three ready

1. **`switchyard-mcp`** — install it on the machine (download from switchyard.work,
   or build `./cmd/switchyard-mcp` from the switchyard source), then the agent runs
   `switchyard-mcp login` (a browser flow).
2. **The first product** — the local path (or clone URL) of the product repo the
   first rig will work on, plus a short rig **name** and bead **prefix**.
3. **A connect code** — switchyard.work → *Settings → Connect a Gas Town* →
   generate one → paste it for `switchyard-gt link <CODE>`.

When the agent finishes, it hands you a `whoami` + a project briefing. Confirm the
projects are yours and the claimable-work count looks right — that's the new town
seeing the cloud backlog. It inherits the same work as any other machine on your
switchyard account; nothing to migrate.
