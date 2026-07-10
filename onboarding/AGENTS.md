# AGENTS.md — driving switchyard

*The operating manual for any agent whose backlog authority is **switchyard**.
Client-agnostic: Codex reads `AGENTS.md` natively, Claude Code reads it too, and
most agent runtimes honor it. Copy this into your project root (or point your
client's system prompt at it). The only thing that differs per client is how you
register the `switchyard-mcp` server — see [`README.md`](README.md).*

## What switchyard is

switchyard is a **PRD-driven backlog authority** that lives in the cloud. You
reach it through the **`switchyard-mcp`** server, which projects it as MCP tools.
You do two jobs: **author** work (turn ideas and intake into approved PRDs and
beads) and **deliver** it (claim beads, build, validate).

**The prime rule:** switchyard is the backlog authority. Never mint local work
that shadows a switchyard bead — *claim* it, mint your local bead from the claim,
and let completion flow back. Anything else forks the truth.

## Orient first — every session

1. `whoami` — confirm your account and resolved scope.
2. `list_projects` → `set_scope(tenant_slug, project_slug)` — target one project
   for the session. (Read tools also accept a per-call `project_slug`, so a
   stateless client can skip `set_scope`.)
3. `get_project_briefing` — the one-call landing read: project, roadmap
   milestones, dispatched epics, open-question count, claimable-work count, and
   the latest report. Start here instead of chaining `get_project` +
   `get_roadmap` + `list_*`.

## The loop

### 1 · Triage intake
- `list_intake_queue` — for anything untriaged: `recommend_idea`, or
  `claim_issue` + `categorize_issue`. **Recommend, don't decide** — routing an
  idea to a pitch is a human's call.
- `list_dispatched_epics` — set priorities on any epic that has none.
- Answer open PRD questions you can settle from the code or history
  (`list_prd_questions` → `answer_prd_question`); leave the rest for humans.

### 2 · Author — idea → beads
Run the sequence in order; each step consumes the last:
```
create_blueprint → draft_prd → set_prd_phases (if phased)
  → ask_prd_question (+ recommend_prd_question with your proposed answer)
  → approve_prd → create_beads_from_prd
```
For any decision the team should weigh in on, use `ask_prd_question` — keep the
decision **on the PRD** where the team can see and answer it. Do **not** ask
out-of-band through a host prompt or modal.

### 3 · Deliver — bead → shipped
- `list_claimable_work` → `claim_bead` (takes a lease).
- Long-running work: renew the lease with `heartbeat_bead` so it doesn't expire
  mid-build.
- Do the work in your repo. When it lands: `complete_bead`.
- Stuck or wrong-shaped? `release_bead` so someone else can take it.

### 4 · Validate — separation of duties
- `validate_criterion` records the acceptance-criterion verdict — and must be
  done by an agent **other** than the one that delivered the work. The server
  enforces this; don't try to validate your own delivery.
- `list_criteria` shows plan-vs-delivered across the whole project.

## Invariants

- **Backlog authority.** switchyard is the source of truth. Claim, then mint
  local work from the claim; never shadow a bead.
- **Recommend, don't decide** the human calls — idea→pitch routing, and PRD
  answers you aren't sure of.
- **Heartbeat long claims** or lose the lease.
- **Separation of duties** — a different agent validates than delivered.
- **One project at a time.** Work only your scoped project; never reach into
  another project's backlog.
- **Report before you rest.** `draft_daily_report` / `create_project_report`
  when you wrap a session's work so the state is legible to the next agent.

## Tool reference, by phase

| Phase | Tools |
|---|---|
| Orient | `whoami`, `list_projects`, `set_scope`, `get_project_briefing` |
| Triage | `list_intake_queue`, `recommend_idea`, `claim_issue`, `categorize_issue`, `list_dispatched_epics`, `list_prd_questions`, `answer_prd_question` |
| Author | `create_blueprint`, `draft_prd`, `set_prd_phases`, `ask_prd_question`, `recommend_prd_question`, `approve_prd`, `create_beads_from_prd` |
| Deliver | `list_claimable_work`, `claim_bead`, `heartbeat_bead`, `complete_bead`, `release_bead` |
| Validate | `list_criteria`, `validate_criterion`, `link_bead_to_criterion` |
| Report | `draft_daily_report`, `create_project_report`, `get_roadmap` |

If a tool name here doesn't match your server, run the client's tool-list command
— the MCP surface is versioned with the server, and `switchyard-mcp` is the
authority on its own tools.
