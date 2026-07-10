# Set up a Gas City (agent runbook)

**This page is written to be executed by a coding agent** on a fresh machine.
Point your agent here:

> Read `onboarding/gas-city.md` in `github.com/outdoorsea/switchyard-packs` and
> set up a Gas City for switchyard on this machine. Run each step, verify its
> checkpoint before moving on, and stop at any **HUMAN** step to ask me.

Rules for the executing agent:
- Run the blocks in order. **Do not proceed past a checkpoint that fails** —
  report the output and stop.
- Steps marked **HUMAN** need the operator's switchyard account or a decision —
  pause and ask.
- This bootstraps **one** rig. Add more by repeating step 4 per product.
- Platform: examples use Homebrew (macOS/Linux). On other platforms, install the
  same tools your package manager's way.

---

## Step 1 — Toolchain

```sh
brew install gascity dolt beads jq   # gascity provides `gc`; beads provides `bd`
# tmux is also required:
brew install tmux
```

**Checkpoint:** all five resolve.
```sh
for b in gc dolt bd jq tmux; do command -v "$b" >/dev/null && echo "ok $b" || echo "MISSING $b"; done
gc version && dolt version && bd version
```
If `gc` is missing, build from source instead: clone `github.com/gastownhall/gascity`, `go build -o ~/go/bin/gc ./cmd/gc`, ensure `~/go/bin` is on `PATH`.

## Step 2 — switchyard MCP server + token  **(HUMAN)**

The city's agents reach switchyard through the **`switchyard-mcp`** server, which
needs a token tied to the operator's switchyard.work account.

1. Install `switchyard-mcp` (obtain per your switchyard distribution — a download
   from switchyard.work or a build of `./cmd/switchyard-mcp`). Ask the operator
   which, if it isn't already on `PATH`.
2. Authenticate (opens a browser):
   ```sh
   switchyard-mcp login
   ```
**Checkpoint:**
```sh
switchyard-mcp doctor    # exit 0 = token resolves and switchyard.work accepts it
```
The token stays machine-local (`$SWITCHYARD_API_TOKEN` or a `chmod 600` file) —
never write it into any config file. See [`README.md`](README.md).

## Step 3 — Create the city

`gc init` **runs an interactive wizard by default** — an agent must pass flags to
make it non-interactive. It scaffolds `.gc/`, `pack.toml`, `city.toml`,
`packs.lock`, and prompt templates, and **brings up a managed-local Dolt store for
the city** (even `--no-start` only skips the agents, not Dolt — so the store is
live after this step):

```sh
gc init --template gastown --default-provider claude ~/gc-<name>
cd ~/gc-<name>
```

**Checkpoint:** scaffold exists and the city's Dolt is up.
```sh
ls .gc pack.toml city.toml packs.lock >/dev/null && echo "scaffold ok"
gc dolt health        # Server: running … (started by init)
```

## Step 4 — Add the first rig, then the switchyard packs  **(HUMAN)**

A rig is a **local checkout of the product's git repo**. Clone the product first;
`gc rig add` probes its `origin/HEAD` and writes canonical rig imports.

**HUMAN decision:** which product repo, and the rig's **name** + bead **prefix**.

```sh
# 1. register the product as a rig
gc rig add /path/to/product-repo --name <rig> --prefix <p>

# 2. see what the template already imported (add only what's missing below)
gc import list

# 3. city-scope, ONCE each — skip any already listed:
gc import add https://github.com/gastownhall/gascity-packs/tree/main/gastown
gc import add https://github.com/outdoorsea/switchyard-packs/tree/main/switchyard-ops

# 4. per-rig overlay (the rig must exist first):
gc import add https://github.com/outdoorsea/switchyard-packs/tree/main/switchyard-mcp --rig <rig>

gc import install && gc import check
```

Then add the **two required switchyard-ops settings** to your rig's block in
`city.toml` — copy them verbatim from the reference
[`examples/city/city.toml`](../examples/city/README.md) — and `gc reload`:
- `formula_vars = { binding_prefix = "gastown." }` — without it the worker handoff
  **silently strands beads**
- `default_sling_targets = ["<rig>/switchyard-ops.brakeman"]`

**Import `switchyard-ops` at city scope only** — a second `--rig` import
double-registers every order (root README's scope table).

**Checkpoint:** `gc import check` passes; `packs.lock` has real SHAs.

## Step 5 — Bring it up

```sh
gc doctor --fix       # migrate/repair pack composition + custom types
gc register           # register the city with the machine-wide supervisor
gc start              # start the controller + reconcile agents up
```

## Step 6 — Verify it's running

```sh
gc dolt health                         # Server: running … healthy
gc agent list | grep -E 'brakeman|witness|refinery|mayor'   # crew present
gc doctor                              # expect green; order-firing warnings settle after a tick
```
`gc import install` does **not** materialize formulas — the supervisor does, a
tick later. If `gc bd formula list` looks short right after install, wait a cycle.

**Checkpoint:** `gc dolt health` is healthy and `gc agent list` shows a
`brakeman` pool in your rig.

## Step 7 — Harden token spend

New crew defaults wake often and re-bill their prompt each time. Apply the
`[[patches.agent]]` blocks from [`../docs/TOKEN-HARDENING.md`](../docs/TOKEN-HARDENING.md)
to `city.toml` (witness `max_session_age`, deacon/witness `idle_timeout`), then
`gc reload`. Verify with `gc config show | grep -A12 'name = "witness"'`.

## Step 8 — Connect to switchyard + first work  **(HUMAN)**

1. Link this Gas Town to switchyard.work (connect code from
   switchyard.work → *Settings → Connect a Gas Town*):
   ```sh
   switchyard-gt link <CODE>
   ```
2. In a coordinator session, run the [`AGENTS.md`](AGENTS.md) loop: `whoami` →
   `set_scope` → `get_project_briefing` → triage `list_intake_queue`.
3. Dispatch a bead to the pool: `gc sling <rig>/switchyard-ops.brakeman <bead-id>`
   (or bare `gc sling <bead-id>` — `default_sling_targets` routes it).

**Done.** The city now runs the 24-hour loop from
[`../docs/LOOP.md`](../docs/LOOP.md). Keep it honest with
[`../docs/TOKEN-HARDENING.md`](../docs/TOKEN-HARDENING.md) and the `config-drift`
order.

---

### If something breaks
- `gc doctor` is the first stop — it names the failing check and often a `--fix`.
- Beads store unreachable / `127.0.0.1:0`: the canonical `.beads/dolt-server.port`
  is missing — write the managed port into it (`gc dolt health` shows the port).
- A stopped town shows `order-firing-current` stale — expected; it clears after
  `gc start` + a tick.
