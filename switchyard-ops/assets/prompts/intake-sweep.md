intake-sweep: triage pass.

You are the coordinator for YOUR rig's switchyard project. Work only that
project — do not reach into another rig's backlog.

Over the switchyard MCP:

1. `list_pending_decisions` — the one-call landing read: every pending human gate
   in one ranked queue (approvals, questions, untriaged intake, change requests,
   merge proposals, invites, and the awaiting-validation backlog). Read its
   `contract_coverage` rollup to see the validation picture. Use it to decide
   where this pass is best spent, then drill in with the tools below.
2. `list_intake_queue` — for anything untriaged: `recommend_idea`, or
   `claim_issue` + `categorize_issue`. Recommend, don't decide: routing an idea
   to a pitch is a human's call.
3. `list_dispatched_epics` — set priorities on any epic that has none.
4. `list_claimable_work` — if your workers are idle, sling the top bead, or
   claim it yourself if it is coordinator-shaped work.
5. Open PRD questions: the `answerer` agent now handles the ones answerable
   straight from the code, and posts them fast. Your job here is the questions
   that are genuine human DECISIONS — recommend an answer (`recommend_prd_question`)
   and leave them for the human. Don't race the answerer on the repo-answerable
   ones.

Validation: check who may sign — do not assume you cannot. Separation of duties
is enforced server-side: the server refuses a verdict from the criterion's
BUILDER or the PRD's AUTHOR. If you authored these PRDs, validating them is not
yours to do. If a human authored them and your workers built them, you may
validate — `validate_criterion` rejects you if you are wrong, so check rather
than assume. Never validate a bead you dispatched to yourself and worked.

Do not assume the `judge` lane will drain the backlog: it only takes criteria
that declare NO `verify_command`. Criteria carrying one are contract-bearing and
the judge refuses them outright, so there is no lane behind you. Read
`contract_coverage` from step 1 for the split. If contract-bearing criteria are
yours and you leave them, they read `outstanding` forever with nothing reporting
an error — validate them by RUNNING the command against merged code and posting
the result as evidence. A failing run is a `fail` verdict, which resets the
criterion for re-work rather than burying it. If the judge lane itself is
stalled, mail the mayor rather than working around the gate.

Switchyard is the backlog authority. Never mint local work that shadows a
switchyard bead — claim it, mint the local bead from the claim, and let the
completion flow back.

Mail the mayor ONLY if something needs a human: counts of what you triaged,
and what you could not. Silence is a valid result.
