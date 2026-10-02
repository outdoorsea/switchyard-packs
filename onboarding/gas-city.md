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

`gc init` **runs an interactive wizard by default and — left to itself — also
registers the city with the machine-wide supervisor and STARTS it** (steps 7–8 of
its scaffold). You do not want a live town before its rigs, packs, and hardening
are in place, so pass `--no-start` and start it deliberately in Step 5. Init still
brings up the city's managed-local **Dolt** store either way:

```sh
gc init --no-start --template gascity --default-provider claude ~/gc-<name>
cd ~/gc-<name>
```

The `gascity` template already imports `bd`, `core`, and `gascity` (bound as
`gc`, with `gascity/roles` as the default rig import), so Step 4 adds only
`switchyard-mcp` — the one pack this repo still publishes.

`gascity` is also `gc init`'s default template, so a bare `gc init` gets you the
same thing.

**Checkpoint:** scaffold exists, Dolt is up, town not yet started.
```sh
ls .gc pack.toml city.toml packs.lock >/dev/null && echo "scaffold ok"
gc dolt health        # Server: running … (Dolt starts even with --no-start)
```

## Step 4 — Add the first rig, then the switchyard pack  **(HUMAN)**

A rig is a **local checkout of the product's git repo**. Clone the product first;
`gc rig add` probes its `origin/HEAD` and writes canonical rig imports.

**HUMAN decision:** which product repo, and the rig's **name** + bead **prefix**.

```sh
# 1. register the product as a rig
gc rig add /path/to/product-repo --name <rig> --prefix <p>

# 2. confirm the template's imports (bd, core, gascity already present)
gc import list

# 3. switchyard MCP overlay — per-rig (the rig must exist first):
gc import add https://github.com/outdoorsea/switchyard-packs/tree/main/switchyard-mcp --rig <rig>

gc import install && gc import check
```

There is **no city-scope switchyard import**. Older guides added
`switchyard-ops` here — the timed-order heartbeat and `brakeman` worker pool —
and a `default_sling_targets = ["<rig>/switchyard-ops.brakeman"]` line in the
rig's `city.toml` block. That pack is retired and no longer on the mirror
(root `README.md`): declaring it makes `gc import install` refuse the source,
after which the declared-but-uninstalled import rejects the whole city config.
Its lanes run under
[switchyard-conductor](https://github.com/outdoorsea/switchyard-conductor),
outside the city; add neither line.

(Likewise there is no `formula_vars = { binding_prefix = ... }` any more. It
pinned the refinery handoff target, and there is no refinery — a worker opens
its own PR.)

Then install gascity's build-artifact validator into the **rig root** — **nothing
does this for you**, and without it every implement step fails its exec check
three times. It goes at the rig root, not the city root, because gascity's role
agents run with their cwd there (see the root README, "Install gascity's
build-artifact validator"):

```sh
GASCITY=$(dirname "$(gc formula show implementation-base --rig <rig> --json \
  | jq -r '.search_paths[] | select(endswith("/gascity/formulas"))')")
RIG=/path/to/rig-checkout
mkdir -p "$RIG/.gc/scripts/checks" "$RIG/schemas"
cp "$GASCITY"/assets/scripts/checks/*.sh "$RIG/.gc/scripts/checks/"
cp "$GASCITY"/assets/scripts/*.py        "$RIG/.gc/scripts/"
chmod +x "$RIG/.gc/scripts/checks/"*.sh
cp -R "$GASCITY/schemas/build" "$RIG/schemas/"
printf '\n.gc/\nschemas/build/\n' >> "$RIG/.gitignore"
```

**Import `switchyard-mcp` per rig only** — it is an overlay projected into that
rig's agent working directories, never a city-wide import (root README).

**Checkpoint:** `gc import check` passes; `packs.lock` has real SHAs.

## Step 5 — Bring it up

```sh
gc doctor --fix       # migrate/repair pack composition + custom types
gc register           # register with the machine-wide supervisor (no-op if init already did)
gc start              # start the controller + reconcile agents up
```

> On a machine that already runs another Gas City, `gc start`/`register`
> reconciles the **shared** supervisor — briefly cycling that other city's
> in-flight work. Expected; it settles on the next tick.

## Step 6 — Verify it's running

```sh
gc dolt health                         # Server: running … healthy
gc agent list | grep -E '<rig>/|mayor'  # gascity's role agents expanded into the rig, plus the mayor
gc doctor                              # expect green; order-firing warnings settle after a tick
```
`gc import install` does **not** materialize formulas — the supervisor does, a
tick later. If `gc bd formula list` looks short right after install, wait a cycle.

**Checkpoint:** `gc dolt health` is healthy and `gc agent list` shows gascity's
`gc.*` role agents in your rig. (No `brakeman` pool appears: that pool shipped
in the retired `switchyard-ops` pack, and nothing this runbook installs
replaces it in-city.)

## Step 7 — Harden token spend

New crew defaults wake often and re-bill their prompt each time. Apply the
`[[patches.agent]]` block from [`../docs/TOKEN-HARDENING.md`](../docs/TOKEN-HARDENING.md)
to `city.toml` (the coordinator's `idle_timeout`), then `gc reload`. Verify with
`gc config show | grep -A12 'name = "<coordinator>"'`.

## Step 8 — Connect to switchyard + first work  **(HUMAN)**

1. Link this Gas Town to switchyard.work (connect code from
   switchyard.work → *Settings → Connect a Gas Town*):
   ```sh
   switchyard-gt link <CODE>
   ```
2. In a coordinator session, run the [`AGENTS.md`](AGENTS.md) loop: `whoami` →
   `set_scope` → `get_project_briefing` → triage `list_intake`.
3. There is no in-city worker pool to dispatch to. The `brakeman` pool, the
   `pool-spawn` order that staffed it, and the judge / answerer / review lanes
   all shipped in the retired `switchyard-ops` pack; they run under
   [switchyard-conductor](https://github.com/outdoorsea/switchyard-conductor)
   now, which needs no city and is set up outside this runbook. What this city
   gives you is a crew that reaches the switchyard backlog through the MCP
   tools.

**Done.** The city's crew now drives switchyard. Keep its idle bill honest with
[`../docs/TOKEN-HARDENING.md`](../docs/TOKEN-HARDENING.md);
[`../docs/LOOP.md`](../docs/LOOP.md) is the design record of the 24-hour cadence
the retired heartbeat ran, not a schedule this city executes.

---

### If something breaks
- `gc doctor` is the first stop — it names the failing check and often a `--fix`.
- Beads store unreachable / `127.0.0.1:0`: the canonical `.beads/dolt-server.port`
  is missing — write the managed port into it (`gc dolt health` shows the port).
- A stopped town shows `order-firing-current` stale — expected; it clears after
  `gc start` + a tick.
