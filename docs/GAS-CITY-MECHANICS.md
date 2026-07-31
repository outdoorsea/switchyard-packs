# Gas City mechanics: what is actually configurable

*Verified against `gc 1.4.0` / `bd 1.1.0` in the `gc-fremont` city on 2026-07-30.
Every claim below was tested empirically, not read off a doc. Where a published
doc disagrees with the binary, that is called out.*

Companions: [`OPERATING-MODEL.md`](OPERATING-MODEL.md),
[`TOKEN-HARDENING.md`](TOKEN-HARDENING.md), [`LOOP.md`](LOOP.md).

---

## 1. How to verify a config claim (read this first)

Gas City has **two different failure modes for a bad config key**, and only one
of them is loud:

| Where | Unknown key behavior |
|---|---|
| `city.toml` `[providers.*]` | **Warns**: `unknown field "providers.kimi.model"` |
| `agents/<n>/agent.toml` | **Silently dropped.** No warning, no error, exit 0. |

That asymmetry is why a wrong belief about `agent.toml` can survive for months:
nothing ever complains. **`gc lint` does not catch it either** — a pack whose
agent declares `totally_bogus_key_xyz` lints `ok` at rc=0.

The reliable test is a **round-trip against a throwaway city**, which is
non-destructive to the real one:

```sh
C=/tmp/probecity; mkdir -p "$C/agents/probe"
# minimal city.toml + pack.toml + agents/probe/{agent.toml,prompt.template.md}
gc config show --city "$C" | grep -A10 'name = "probe"'
```

A key that appears in the resolved dump is honored. A key that vanishes is
ignored. **Always include a deliberately bogus key as a negative control** — if
your "supported" key and the bogus key behave identically, you have proved
nothing.

---

## 2. Agent configuration (`agents/<name>/agent.toml`)

Keys observed in use across the 135 cached pack agents, plus those verified by
round-trip:

| Key | Notes |
|---|---|
| `scope` | `"city"` or `"rig"`. Rig-scoped agents materialize once per rig. |
| `description` | Free text. |
| `provider` | **Binds the agent to a `[providers.*]` entry.** Verified. |
| `wake_mode` | `"fresh"` clears context on recycle; `resume` rehydrates it. |
| `work_dir` | Template: `{{.Rig}}`, `{{.AgentBase}}`, `{{.Agent}}`. |
| `nudge` | Text delivered by `gc session nudge`. |
| `idle_timeout` | Sleep after N idle. |
| `min_active_sessions` / `max_active_sessions` | Pool floor/ceiling. |
| `max_session_age` (+ `_jitter`) | Force-recycle even while active. |
| `sleep_after_idle` | |
| `pre_start` | Setup hook (e.g. worktree creation). |
| `start_command` | **Escape hatch**: run an arbitrary command as the session. |
| `prompt_mode` | `"none"` suppresses prompt injection (used with `start_command`). |
| `process_names` | What the reconciler greps to judge liveness. |
| `default_sling_formula` | Formula used when work is slung to this agent. |
| `fallback` | |

### ⚠ `model` is NOT a valid agent key

[`OPERATING-MODEL.md`](OPERATING-MODEL.md#token-economy) states:

> **Pin a cheap model** on the mechanical tier (witness, boot, patrol). `model`
> is a valid key in `agent.toml`.

**This is false on gc 1.4.0.** Round-trip proof: an `agent.toml` declaring
`model = "claude-sonnet-4-6"` alongside `idle_timeout = "4h"` resolves to a
config where `idle_timeout` is present and `model` is **absent** — behaving
exactly like the bogus control key in the same file. Zero of the 135 cached pack
agents set `model`, which is consistent with it never having worked.

Consequence: **you cannot currently pin a cheaper model per agent.** The
token-tiering advice in `OPERATING-MODEL.md` is not actionable as written. Model
selection happens at the two layers below instead.

---

## 3. Providers — the real model-selection layer

City-level registry in `city.toml`:

```toml
[workspace]
provider = "claude"          # city-wide default

[providers]
[providers.claude]
base = "builtin:claude"
ready_delay_ms = 0
```

At config load gc prints the resolved inheritance chain:

```
# Provider inheritance chains (as resolved at config load):
#   claude               claude → builtin:claude
#   kimi                 kimi   → builtin:kimi
```

**Accepted `[providers.*]` keys** (verified; anything else warns):
`base`, `command`, `args`, `env`, `ready_delay_ms`.

**Rejected:** `model` — `unknown field "providers.kimi.model"`.

So a model is chosen by **passing it to the provider CLI**, via `args` or `env`:

```toml
[providers.kimi]
base    = "builtin:kimi"
command = "kimi"
args    = ["--model", "kimi-k2.6"]
env     = { KIMI_MODEL = "kimi-k2.6" }
```

…and an agent opts in with `provider = "kimi"`. Both halves round-trip cleanly.

### Providers the installed binary knows about

Auth env vars present in the `gc` binary: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
`GEMINI_API_KEY`, `KIMI_API_KEY`, `KIRO_API_KEY`, `CURSOR_API_KEY`,
`COPILOT_PROVIDER_API_KEY`, `AMP_API_KEY`, `XAI_API_KEY`, `XIAOMI_API_KEY`.

Per-provider hook overlays ship in the `core` pack at
`overlay/per-provider/<name>/` for: `antigravity`, `codex`, `copilot`, `cursor`,
`gemini`, **`kimi`**, `kiro`, `mimocode`, `omp`, `opencode`, `pi`. Each wires a
SessionStart hook that calls `gc prime --hook`, which is what makes a foreign CLI
behave as a Gas City agent. The kimi overlay is
`overlay/per-provider/kimi/.kimi/config.toml` + a Python session-start hook.

Model identifiers referenced by the binary include `kimi-k2.6` ("Kimi K2.6"),
`claude-opus-4-7/4-8`, `claude-sonnet-4-5/4-6`, `gpt-oss-120b`, `qwen3-32b`,
`qwen-3-235b-a22b-instruct`, `deepseek-v4-flash-free`, `glm-4.x`, `gpt-5.6-luna`,
MiMo V2.5.

> **Naming note:** there is no "kimi3". The supported Kimi model is **K2.6**
> (`kimi-k2.6`).

**Config acceptance is not runtime proof.** `builtin:kimi` resolves at config
load and the overlay exists, but an actual kimi-backed session has not been run
in this city. Before depending on it: install the kimi CLI, set `KIMI_API_KEY`,
import the overlay, and start one throwaway session.

### Per-step provider/model in formulas

Formulas select provider *and* model per step via step metadata — this is the
mechanism that actually works today for mixed-model work. From the core
`mol-review-quorum` formula:

```toml
metadata = {
  "gc.run_target"    = "{{lane_one_target}}",
  "gc.provider"      = "{{lane_one_provider}}",
  "opt_model"        = "{{lane_one_model}}",
  "gc.reviewer_model"= "{{lane_one_model}}",
  "gc.output_json_schema"   = "review-quorum.lane.v1",
  "gc.output_json_required" = "true",
}
```

`mol-review-quorum` fans out two **read-only reviewer lanes on different
providers/models**, then routes a synthesis agent over their structured outputs.
It is the closest existing scaffold to a multi-model review capability and
should be the starting point for any such design rather than a new invention.

---

## 4. Orders — scheduling

```toml
[order]
description = "…"
trigger  = "cooldown"
interval = "30m"
exec     = "$PACK_DIR/assets/scripts/lane-ensure.sh judge judging-validator"
```

Orders are **mechanical `exec` scripts with no LLM cost**. The switchyard-ops
convention is that an order decides *whether* to start a session; the judgment
lives in the agent's prompt. This keeps a frequent cadence cheap: `pool-spawn`
runs every 60s (1440×/day) and costs nothing until it finds real demand.

`$PACK_DIR` resolves to the installed pack root. Never hardcode the
content-addressed cache path — it changes on every re-pin.

---

## 5. MCP access — overlay packs

An MCP server reaches agents through a **pure overlay pack** (no agents), which
projects files into agent working dirs. `switchyard-mcp` is the whole pattern:

```
packs/switchyard-mcp/
  pack.toml                      # [pack] name/schema only
  overlay/.claude/settings.json  # { "mcpServers": { "switchyard": {...} } }
```

```json
{ "mcpServers": { "switchyard": {
    "command": "switchyard-mcp",
    "env": { "SWITCHYARD_BASE_URL": "https://switchyard.work" } } } }
```

Imported **per rig** (`[rigs.imports.switchyard-mcp]`), not city-wide. The API
token is deliberately **not** in the overlay: the server self-resolves it from
`$SWITCHYARD_API_TOKEN` or `~/Library/Application Support/switchyard/token`
(written by `switchyard-mcp login`). Never hardcode the token into the overlay —
that leaks it into git.

---

## 6. Token accounting — what exists today

### The sink: `.gc/usage.jsonl`

One JSON object per fact. Two kinds:

```json
{"kind":"model","run_id":"gf-c1q","session_id":"gf-c1q",
 "worker":"gc__run-operator-gf-c1q","model":"claude-opus-5","provider":"claude",
 "input_tokens":2,"output_tokens":254,
 "cache_read_tokens":58463,"cache_creation_tokens":956,
 "unpriced":true,"upstream_req_id":"msg_…","at":1785363125325,
 "idempotency_key":"…"}

{"kind":"compute","run_id":"gf-k7x","worker":"core__control-dispatcher-gf-k7x",
 "city":"gc-fremont","wall_seconds":119.35,"at":…,"idempotency_key":"…"}
```

### The reader: `gc costs`

```
RUN     INVOCATIONS  IN  OUT   CACHE_R  CACHE_C  WALL_S  EST_USD  UNPRICED
gf-ak0  4            7   5347  245028   14297    176.8   0.0000   4
gf-c1q  7            13  2866  436242   7672     363.6   0.0000   7
TOTAL   11           20  8213  681270   21969    659.8   0.0000   11
```

### Three gaps that block per-project / per-PRD / per-PR reporting

1. **Attribution stops at `run_id`.** Records carry
   `run_id` / `session_id` / `worker` / `city` / `model` / `provider` — and *no*
   rig, project, PRD, or PR field. Any per-PRD or per-PR number requires an
   external join: `session → bead → PRD/PR`. Nothing in the sink does that join,
   and `gc costs` groups by run only.
2. **Everything is `unpriced`.** `EST_USD` is `0.0000` across the board because
   no pricing is configured for `claude-opus-5`; unpriced invocations are
   *excluded* from the total rather than estimated. Today you can see token
   spikes but not dollar spikes.
3. **The sink is provider-dependent.** `gc costs` reads facts only under the
   default `local` usage provider; with an `exec:` or `discard` provider they are
   forwarded out of process or dropped. A foreign-CLI provider (kimi, codex) only
   contributes usage facts if it reports them the same way — **unverified for
   kimi**, and a silent zero would look identical to "cheap".

### The cost structure the numbers actually show

`cache_read` dwarfs everything: **681,270 cache-read tokens against 20 input and
8,213 output.** Cost is dominated by re-reading context, not by generation. This
corroborates `TOKEN-HARDENING.md`'s core claim — the lever is **wake/respawn
frequency × prompt size**, not output verbosity. Any token-audit capability that
optimizes output length is optimizing the wrong term by two orders of magnitude.

---

## 7. This city's current shape (gc-fremont, 2026-07-30)

- **Rigs:** `gc-fremont` (HQ, prefix `gf`), `meety-local` (`ml`, suspended),
  `switchyard` (`sw`), `faultline` (`fa`).
- **City imports:** `bd`, `core`, `gascity`. Rigs import `gascity/roles` as `gc`.
- **`switchyard-ops` is NOT imported here.** The `gc.*` agents in this city
  (design-author, implementation-worker, gap-analyst, review-synthesizer, …) come
  from `gascity/roles`, not from switchyard-ops.
- **`switchyard-mcp` is NOT imported** by any rig in `city.toml`.

Both are prerequisites for switchyard-ops work landing in this city.

---

## 8. Standing hazards (learned destructively — do not relearn)

- **Never edit a formula in the pack cache.** HEAD ≠ the `packs.lock` pin makes
  `gc bd` / `hook` / `agent` / `formula` all die **town-wide, any cwd, at rc=0**.
  Move the lock to the code, never the code to the lock. Never push or branch in
  a cache dir. `gc import install` — the error's own suggested fix — rolls the
  pack back and can orphan unpushed cache commits.
- **`[[patches.agent]]` matches the fully-qualified name**, exact, no wildcard:
  `gastown.deacon` (city-scoped) or `<rig>/gastown.witness` (one entry **per
  rig**). A bare leaf name makes `gc config show` exit 1 and rejects the *whole*
  config.
- **`gc rig add` / `gc rig resume` rewrite `city.toml` and drop comments.**
  Re-verify `[[patches.agent]]` after any gc command that rewrites config.
- **`gc session nudge` is keystroke injection** — it types *and submits*. At a
  menu it selects an option; with text pending it submits the operator's line.
  Always `gc session peek` first.
- **`timeout` does not exist on macOS.** A command using it exits rc=0 with empty
  output, which reads as "no findings" on a failing town.
