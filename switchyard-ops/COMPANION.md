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

> No companion capability still requires the companion: every verb is a pack lane, pending under PRD #327, or retires with the daemon.

`validate` and `watch` were the last two `COMPANION-REQUIRED` rows; both gained
pack orders on 2026-08-12 (`orders/validate-sweep.toml` and
`orders/event-pump.toml` — see the rewritten sections below for how each of the
original objections was answered). The token and its gate remain, so a row that
re-acquires `COMPANION-REQUIRED` is still a reviewed decision, not a drift.

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
| Golden-journey ship verification | `journeys` | `agents/golden-journey` + `orders/golden-journey-sweep.toml` (30m) | `PACK-LANE` |
| Config/token/reachability preflight | `doctor` | reachability check that escalates | `PENDING` |
| Contract re-run against merged main | `validate` | `orders/validate-sweep.toml` (15m, opt-in via `VALIDATE_RIGS`) | `PACK-LANE` |
| SSE event bridge → session wake | `watch` | `orders/event-pump.toml` (1m, opt-in via `EVENT_PUMP_RIGS`) | `PACK-LANE` |
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
row at all is marked `COMPANION-REQUIRED` — so the headline claim above cannot
quietly stop being true, and re-acquiring the token is a reviewed decision.

## How `validate` became a pack lane

`validate` re-runs a delivered criterion's own `verify_command` and posts a
`done` on exit 0, a `fail` on anything else. Both verdicts are consequential: an
automated `done` is terminal, and a `fail` **resets delivered work for re-work**.
This section used to argue a wake-based pack agent could not offer the
guarantees that demands; `orders/validate-sweep.toml` answers each of those
objections rather than waiving them:

- **"It needs a dedicated clean clone it controls."** The lane owns
  `validate-repo.<rig>` under the pack state dir — never the rig root — cloned
  on first run from `VALIDATE_REPOS`, fetched and hard-reset before every cycle,
  and the cycle refuses to run (with mail) when the reset fails. A rig checkout
  stays a worker's business.
- **"It must be pointed at the branch the criteria actually land on."**
  `VALIDATE_BRANCHES="<rig>=<branch>"` validates against an integration branch
  instead of origin's default. And independently of that setting, a NON-ZERO
  exit on a PRD with **no merged delivery on record** (empty `evidence_ref`)
  banks no verdict at all — the stake is released, because "the code is not on
  this tree yet" is not a judgment on the work. A pass still banks `done`; the
  code being present and passing is evidence in itself. That asymmetry is what
  stops the false-negative rework churn the old text warned about.
- **"A wholesale-skipped suite exits 0 and banks a false done."** The per-rig
  prep guard (`validate-prep.<rig>.sh` in the state dir) runs before any claim:
  regenerate gitignored code, run a canary that proves the harness executes.
  A refused guard validates nothing and mails — fail closed, loudly.

The `judge` agent still deliberately takes only criteria declaring **no**
command, so without this lane a fully contract-bearing PRD is reachable by no
validator at all; that is exactly the backlog this order drains.

## How `watch` became a pack lane

`watch` subscribes to the project's SSE event stream and routes each event
through log → classify → coalesce → hook. The old objection was that it is a
**held-open socket**, and no gc construct holds a connection open across a
wake-based agent's exit.

`orders/event-pump.toml` drops the held-open socket rather than imitating it:
each 1m cycle opens the stream with the stored `Last-Event-ID` cursor, drains
for a bounded window (the stream flushes its backlog immediately on connect),
maps every new event's kind onto the pack order that owns that class, runs each
mapped order at most once, and advances the cursor. Same feed, same classifier
mapping, no daemon.

The consequence is a latency floor of roughly the 1m tick plus the drain
window — versus the 20m–1h sweep cadences the polls impose alone — and the
cooldown sweeps remain the delivery guarantee: a pump failure costs latency,
never coverage.

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
