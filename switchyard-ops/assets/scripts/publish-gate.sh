#!/bin/sh
# publish-gate: catch work that was closed without ever being published.
#
# This order replaces `merge-gate`, which existed because gastown's refinery
# defaulted `merge_strategy` to `direct` and would land an unreviewed commit on
# the default branch. There is no refinery in a gascity city and nothing merges
# automatically, so that failure mode is gone — but the failure it was really
# guarding (work reaching "done" without a human ever seeing it) simply MOVED.
#
# The new shape: gascity's worker lane closes its own source anchor, and its
# push/PR leg lives in a separate formula whose `push` and `open_pr` vars both
# default to "false". A worker that skips or fumbles the publish step leaves the
# branch on local disk and closes the bead anyway. Every switchyard surface then
# reads that bead as delivered. `sy-item-work` orders `close-source-anchor`
# after `publish` and its close step refuses without a `pr_url`, but that guard
# is prose an agent can talk itself past. This is the mechanical backstop.
#
# Selector: CLOSED work beads that went through the worker lane and carry no
# `pr_url` — identified by `work_dir`, with `gc.kind` empty to exclude the
# workflow/step beads.
#
# `work_dir` is the discriminator on purpose, and picking it correctly matters.
# The obvious choice — `gc.routed_to` ending in `.brakeman`, which is what the
# retired merge-gate selected on — DOES NOT WORK on the gascity lane, and fails
# silently: the metadata is split across two beads. Slinging routes the WORKFLOW
# ROOT (which carries `gc.routed_to` + `gc.kind=workflow`), while `pr_url` and
# `branch` land on the WORK BEAD (which carries neither). A selector demanding
# both on one bead matches nothing, ever — a dead check that looks healthy,
# which is the exact failure class this pack exists to catch. Verified against a
# real run before this was changed.
#
# `work_dir` is written on the work bead by the lane's FIRST step
# (prepare-worktree), so it marks "this went through the worker lane" whether or
# not publish ever ran — which is the whole point, since the bead we most need
# to catch is one that never reached publish at all.
#
# Escalation tier: per LOOP.md this is a live regression, not hygiene — delivered
# work is invisible right now — so it mails as soon as it is seen. But it mails
# about each bead ONCE. Re-reporting the same historical bead every 5 minutes is
# how an escalation channel becomes noise, and unlike merge-gate this order
# cannot fix what it finds: a human decides whether to reopen, re-publish, or
# accept it.
set -u

. "$(dirname "$0")/../lib/roster.sh"

sy_load_conf

SEEN="$(sy_state_dir)/publish-gate.reported"
mkdir -p "$(dirname "$SEEN")" 2>/dev/null

# First run seeds without mailing. A city migrating off the gastown lane has a
# back catalogue of beads that legitimately closed with no pr_url (the refinery
# recorded the merge instead), and replaying all of it into the mayor's inbox
# would bury the first real occurrence. Same reasoning as seeding a notifier
# cursor at head rather than at the beginning of history.
seeding=0
if [ ! -f "$SEEN" ]; then
  seeding=1
  : > "$SEEN"
fi

unpublished=""

for rig in $(gc rig list --json 2>/dev/null | jq -r '(if type=="array" then . else (.rigs // []) end)[] | .name' 2>/dev/null); do
  # `gc bd list` from the city root sees only the town ledger, so every read
  # must name its rig explicitly.
  ids=$(gc bd list --rig "$rig" --status closed --json 2>/dev/null | jq -r '
    .[]
    | select(.metadata != null)
    | select((.metadata["work_dir"] // "") != "")
    | select((.metadata["gc.kind"] // "") == "")
    | select((.metadata["pr_url"] // "") == "")
    | .id' 2>/dev/null)

  for id in $ids; do
    if grep -qxF "$rig/$id" "$SEEN" 2>/dev/null; then
      continue
    fi
    # Seeding marks without alerting: a first run must not mail the whole
    # pre-existing backlog. Otherwise COLLECT here and mark only once the
    # alert has actually been delivered, below.
    if [ "$seeding" -eq 1 ]; then
      printf '%s\n' "$rig/$id" >> "$SEEN"
      continue
    fi
    unpublished="$unpublished $rig/$id"
  done
done

# Silence is the success case.
if [ -n "$unpublished" ]; then
  if gc mail send mayor \
    -s "publish-gate: bead(s) closed with no pull request" \
    -m "These beads were routed to a worker pool and are now CLOSED, but carry no metadata.pr_url — the work was marked delivered without a branch anyone can review:$unpublished

Nothing merges automatically in this city, so a closed bead with no PR usually means the worker's publish step never ran or silently failed. The branch may still exist in the worker's worktree, or may be gone.

Check one with:

  gc bd show --rig <rig> <bead> | grep -iE 'branch|pr_url|assignee'
  git -C <rig-root> ls-remote --heads origin

Then either reopen it for re-publication:

  gc bd update --rig <rig> <bead> --status=open

...or, if the work genuinely landed by another route, record the PR so this stops being reported:

  gc bd update --rig <rig> <bead> --set-metadata pr_url=<url>

Each bead is reported once." >/dev/null 2>&1; then
    # Delivered — NOW it is reported, so it is never reported again.
    for key in $unpublished; do
      printf '%s\n' "$key" >> "$SEEN"
    done
  else
    # Deliberately the OPPOSITE ordering to switchyard's own
    # claim-then-notify escalations (markDecisionEscalated, the buzz notify
    # cursors), which advance the cursor first so a crash costs one line
    # rather than re-announcing forever. That is right for a notifier, where
    # duplicates are noise. This is a SAFETY NET whose only job is catching
    # work that went silently unpublished — dropping its one alert defeats
    # the entire check, while a duplicate mayor mail costs nothing. So
    # nothing is marked unless the mail went out, and the next order cycle
    # re-reports the same beads.
    echo "publish-gate: alert delivery FAILED; leaving$unpublished unreported so the next cycle retries" >&2
  fi
fi

# Mail health is not order health: a mail outage must not make this order look
# broken and get disabled. The retry is carried by the unmarked SEEN file above,
# not by the exit code.
exit 0
