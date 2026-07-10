# Hermes (Nous Research)

[Hermes Agent](https://github.com/nousresearch/hermes-agent) — a self-improving
terminal agent + multi-platform gateway — driving switchyard through the
`switchyard-mcp` server. Hermes is fully MCP-capable, so this is the same pattern
as every other surface, with one bonus: Hermes lets you expose *only* the tools
you use.

## 1 · Install + token

```sh
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash   # then: hermes
switchyard-mcp login && switchyard-mcp doctor                        # machine-local token
```

MCP support ships with the standard install (`.[all]`). If you installed minimal:

```sh
cd ~/.hermes/hermes-agent && uv pip install -e ".[mcp]"
```

## 2 · Register the MCP server

Add `switchyard` to Hermes's `mcp_servers` config (manage with `hermes mcp`; the
config shape is documented in Hermes's MCP config reference):

```yaml
mcp_servers:
  switchyard:
    command: "switchyard-mcp"   # bare = stdio server
    enabled: true
    # Optional but recommended — expose the smallest useful surface.
    # switchyard-mcp is a large tool set; scope it to the loop you actually run:
    tools:
      include: [whoami, list_projects, set_scope, get_project_briefing,
                list_intake_queue, recommend_idea, list_claimable_work,
                claim_bead, heartbeat_bead, complete_bead,
                list_criteria, validate_criterion]
```

After editing config, run `/reload-mcp` in a session (or restart `hermes`).

## 3 · Instructions

Hermes takes its behavior from [agentskills.io](https://agentskills.io) **skills**
plus its persona/memory — not a bare `AGENTS.md`. Adapt the switchyard loop in
[`AGENTS.md`](AGENTS.md) into a Hermes skill (it's agentskills.io-compatible) or
your persona config, so the orient → triage → author → deliver → validate loop is
always in context. Hermes's learning loop will refine the skill over sessions.

## 4 · Verify

In `hermes`, ask what tools it has (the `switchyard` tools should appear), then
have it run `whoami` and `get_project_briefing`.

## Why the tool filter matters here

Per Hermes's own guidance — *"connect the right thing, with the smallest useful
surface"* — don't expose all ~80 switchyard tools to the model. The `tools.include`
list above mirrors [`AGENTS.md`](AGENTS.md)'s phase table; add the authoring tools
(`create_blueprint`, `draft_prd`, `ask_prd_question`, `approve_prd`,
`create_beads_from_prd`) if this agent also authors PRDs.
