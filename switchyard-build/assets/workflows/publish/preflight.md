This is switchyard's publish preflight. It shadows the Gas City base pack's
`assets/workflows/publish/preflight.md` through the documented asset path-shadow
seam, so the base `publish` formula stays inherited and unforked while the gate
it runs is switchyard's.

A shadow REPLACES the base file; it does not merge with it. Every inherited
check is therefore restated below. Do not trim this file down to the switchyard
rules — deleting a line here deletes the check, and a weaker gate at the same
path silently shadows the stronger one it replaced.

## Inherited checks — carried over from the base preflight, none dropped

Validate auth, token scope, remote, branch names, PR base, collision policy,
protected/default targets, sanitized metadata, final report {{final_report}},
push authorization {{push}}, and open_pr authorization {{open_pr}}.

## Rule 1 — publishing is PR-only

A factory run publishes by opening a pull request, or it does not publish.

- A direct push to the default branch, or to any protected branch, is REFUSED
  here. Refuse it even when {{push}} is authorized: {{push}} authorizes writing
  the topic branch that the pull request will be opened from, and authorizes
  nothing else. Push authorization alone is never sufficient grounds to publish.
- Publishing requires {{open_pr}}. With {{push}} authorized and {{open_pr}} not,
  this is not a publish — record the no-op and stop, leaving the branch ready
  for a later publisher.
- If you cannot determine which branch is the default or which branches are
  protected, that is a refusal, not a pass. See Refusing below.

switchyard's own repository forbids pushing to `main`; work lands via pull
request and is reviewed there. A factory that drains a convoy in parallel
worktrees would otherwise be the one actor in the system able to bypass that
review, at exactly the moment the least human attention is on it.

## Rule 2 — the PR title carries the PRD and bead ids

Refuse to open a pull request whose title does not carry BOTH ids. Both are
required; a title carrying one of the two is refused exactly as a title carrying
neither.

    PRD #<prd-id> <phase>: <summary> (<pool-bead-id>)

    PRD #269 P1: enforce PR-only publishing in the factory (prd-269-c8bee483d06e)

- **The PRD id**, written `PRD #<prd-id>`, and appearing EXACTLY ONCE across the title, body and branch name together. switchyard's webhook auto-links a pull
  request to its PRD by scanning those three for `PRD #N`; two distinct refs
  make the resolver refuse to guess and the pull request then never appears on
  any PRD page. Write any secondary mention without the hash, as `PRD 269`. The
  repository's `prd-ref guard` workflow fails the pull request on a second
  distinct ref.
- **The pool bead id** — the switchyard claim-pool bead this pull request
  delivers, e.g. `prd-269-c8bee483d06e`, in the trailing parentheses. This is
  the id the finalize step completes the bead under, so a title without it
  strands the delivery record: the pull request merges and no bead can be joined
  to it. Use the switchyard pool bead id, not the local workflow bead id.
- The `PRD #<prd-id> <phase>:` prefix followed by one space is byte-identical to the convention every
  merged switchyard pull request already follows, so the auto-link, the guard,
  and a human scanning the pull request list all read a factory title exactly as
  they read a hand-authored one.

One pull request delivers one pool bead. If a single branch has come to deliver
several beads, that is a decomposition failure upstream in the convoy mapping —
report it and refuse rather than listing several bead ids in one title.

## Refusing

Fail closed. When a check above cannot be evaluated — the remote is
unreachable, the default branch is unknown, protected-branch state cannot be
read, the final report {{final_report}} is missing, or the title cannot be
confirmed to carry both ids — REFUSE to publish.

An undeterminable check is a refusal and never a pass.

Do not downgrade one to a warning and proceed.

Record the refusal with the specific check that failed and leave the artifacts
ready for a later publisher. A refusal here is a successful preflight step that
withheld a publish, not a failed workflow.
