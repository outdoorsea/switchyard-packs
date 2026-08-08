# Companion Capability Ledger

`switchyard-ops` exists so a Gas City can run switchyard's factory by importing a
pack, without also installing, credentialing and supervising the
`switchyard-companion` binary. This ledger records how far that has actually got:
which of the companion's capabilities a pack lane covers **today**, which are
still in flight, which vanish rather than needing a replacement, and which will
never be a pack lane at all.

It exists because the failure mode here is silent. A lane that is not running
looks exactly like a lane with nothing to do: no error, no mail, an idle rig and
a backlog that quietly does not drain. An operator who assumes `dedup` is covered
because the pack "handles issues" gets no signal that it is not. So this file
never asserts a capability is covered before it is — an unlanded lane is recorded
as **PENDING** against the switchyard PRD #327 acceptance criterion that will
satisfy it, in the same spirit as `packs/switchyard-build/REQUIREMENTS.md`.

**The claim this ledger is built to state, and the one worth remembering:**

> `validate` and `watch` are the only companion capabilities that still require the companion.

Everything else is either covered by a pack lane, landing under PRD #327, or
disappears together with the daemon that hosts it.

## How to read the Status column

The four tokens are deliberately distinct, because "not covered yet" and "will
never be covered" call for opposite responses from an operator — wait, versus
keep the companion installed.

| Token | Meaning | What an operator should do |
| --- | --- | --- |
| `PACK-LANE` | A pack agent or order covers this on `main` today. | Nothing. Confirm it is live (see below). |
| `PENDING` | A PRD #327 criterion covers it; **not landed**. Not running. | Run the companion verb, or accept the gap knowingly. |
| `RETIRES-WITH-DAEMON` | Exists only *because* the companion is a long-lived daemon. Deleted, not replaced. | Nothing. It has no pack equivalent by design. |
| `COMPANION-REQUIRED` | Structurally out of reach for a wake-based pack agent. | **Keep the companion installed for this verb.** |

## The ledger

<!-- ledger:begin -->

| Capability | Companion verb | Pack coverage | Status |
| --- | --- | --- | --- |
| PRD Q&A auto-answering | `answer` | `agents/answerer` + `orders/answer-sweep.toml` (20m) | `PACK-LANE` |
| Judgment verdicts on command-less criteria | `judge` | `agents/judge` + `orders/judge-sweep.toml` (30m) | `PACK-LANE` |
| Claim-pool worker | `work` | `agents/brakeman`, still claiming via `gc hook --claim` | `PENDING` |
| Issue auto-triage | `triage` | intake-triage lane | `PENDING` |
| Duplicate-merge proposals | `dedup` | duplicate-detection lane | `PENDING` |
| Covered-by proposals | `covered-by` | duplicate-detection lane | `PENDING` |
| Golden-journey ship verification | `journeys` | golden-journey lane | `PENDING` |
| Config/token/reachability preflight | `doctor` | reachability check that escalates | `PENDING` |
| Contract re-run against merged main | `validate` | none — see Why `validate` stays | `COMPANION-REQUIRED` |
| SSE event bridge → session wake | `watch` | none — see Why `watch` stays | `COMPANION-REQUIRED` |
| Bridge daemon: control surface + reconcile loop | `serve` | none; cloud-pool dispatch removes the bridge | `RETIRES-WITH-DAEMON` |
| Local `bd` dispatch bridge | `serve` (`local_dispatch`) | none; the managed pool needs no `bd` | `RETIRES-WITH-DAEMON` |
| On-disk sync cursors | `cursors.json` (`state_path`) | none; the pool is claimed, not cursored | `RETIRES-WITH-DAEMON` |
| Upstream progress sync | `/progress` | none; a pool claim reports its own progress | `RETIRES-WITH-DAEMON` |
| First-dispatch notification mail | bridge daemon | none; an artifact of local dispatch | `RETIRES-WITH-DAEMON` |
| Drift reporting stubs | `sync`, `status`, `link` | none; never implemented (stubs) | `RETIRES-WITH-DAEMON` |
| Health port | `health_addr` (`/health`) | none; nothing long-lived to health-check | `RETIRES-WITH-DAEMON` |
| Quiet-window predicate | update guard | none; a pack agent is quiet between wakes | `RETIRES-WITH-DAEMON` |
| Self-update check | `update --check` | none; no installed binary to update | `RETIRES-WITH-DAEMON` |
| Self-update apply | `update` | none; no installed binary to update | `RETIRES-WITH-DAEMON` |
| Agent deregistration on shutdown | bridge daemon | none; a wake-based session has no shutdown | `RETIRES-WITH-DAEMON` |

<!-- ledger:end -->

Enforced by `scripts/check-companion-capability-ledger.sh`, which fails if any
row other than `validate` and `watch` is marked `COMPANION-REQUIRED` — so the
headline claim above cannot quietly stop being true.

## Why `validate` stays

`validate` re-runs a delivered criterion's own `verify_command` and posts a
`done` on exit 0, a `fail` on anything else. Both verdicts are consequential: an
automated `done` is terminal, and a `fail` **resets delivered work for re-work**.
That is why it needs guarantees a wake-based pack agent cannot offer.

- **It needs a dedicated clean clone it controls.** `validate_workdir` is
  hard-reset before each run, and the freshness gate refuses a dirty tree. A rig
  checkout is dirty by construction — a worker's worktree is scoped to a bead —
  so the lane cannot borrow one.
- **It must be pointed at the branch the criteria actually land on.**
  `validate_main_branch` defaults to `main`. Under a one-integration-branch-per-PRD
  policy the code sits on `prd-<N>-<slug>` until the whole PRD merges, so the
  default re-runs every contract against a tree without the code, fails them all,
  and undoes delivered work while reporting success.
- **Its precondition is met, so this is not theoretical.** Contract-bearing
  coverage is no longer ~0; a fully contract-bearing PRD is today the *worst*
  case for acceptance, because `judge` deliberately takes only criteria with **no**
  command and declines every one of these. If no companion runs `validate`, that
  backlog is reachable by no lane at all.

Leave `validate_skip_repo_check` false. If you run this lane, run it from the
companion, against a dedicated clone, on the integration branch.

## Why `watch` stays

`watch` subscribes to the project's SSE event stream and routes each event
through log → classify → coalesce → hook, so a judge or answerer can be woken the
instant a criterion is delivered or a question opens.

It is not a lane that does work; it is a **held-open socket**. It keeps a
long-lived HTTP connection with jittered auto-reconnect and an in-memory
`Last-Event-ID` cursor for resume. A pack agent is wake-based — it starts, acts
and exits — and no gc construct holds a connection open across that boundary. An
order polling on a cadence is the closest a pack gets, which is what
`answer-sweep` (20m) and `judge-sweep` (30m) already are.

The consequence is a latency floor, not a coverage gap: **without `watch` the
polls are the primary trigger rather than a safety net.** The backlog still
drains; it drains on the sweep cadence.

## Never assume a lane is running

The pack's orders spawn lanes on demand, so "no session" is the normal resting
state and is indistinguishable from a broken lane at a glance. Check, don't
assume:

```sh
gc agents list                 # which lane sessions are live right now
gc order status                # per-order last run, and whether it errored
gc dolt logs -n 200            # what the last sweep actually did
switchyard-companion doctor    # config + token + reachability, exit 0 healthy
```

A lane whose order runs but never spawns is the case worth suspecting first: a
sweep with a broken token, or scoped to the wrong project, reports success and
staffs nothing. That specific failure is what the `doctor` row above is `PENDING`
on — until it lands, a broken token surfaces as an idle rig, not as an
escalation.
