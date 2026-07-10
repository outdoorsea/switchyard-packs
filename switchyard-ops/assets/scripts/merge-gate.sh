#!/bin/sh
# merge-gate: every bead routed to a worker gets a merge_strategy before the
# refinery reaches it. Without one, gastown's refinery defaults to `direct` and
# lands an agent's unreviewed commit on the rig's default branch.
#
# This is policy the pack owns. gastown decides HOW work merges; switchyard-ops
# decides THAT it must be reviewed. Relying on whoever created the bead to
# remember `--set-metadata merge_strategy=mr` is exactly the silent failure this
# pack exists to close.
#
# Note `gc sling --merge` does NOT do this: it is a `gc convoy create` flag and
# is a no-op on a direct bead route. The refinery reads only the WORK BEAD's
# metadata.merge_strategy, defaulting to "direct".
#
# Selector: open beads whose gc.routed_to names a *.brakeman pool, carrying no
# `gc.kind` (workflow-internal step beads all carry one) and no merge_strategy.
# Idempotent: a bead already stamped is skipped, so re-running is free.
set -u

. "$(dirname "$0")/../lib/roster.sh"

sy_load_conf
# A city that genuinely wants direct-to-branch merges sets MERGE_STRATEGY=direct
# in roster.conf. Anything else is passed through verbatim (e.g. "local").
STRATEGY="${MERGE_STRATEGY:-mr}"

stamped=0
failed=""

for rig in $(gc rig list --json 2>/dev/null | jq -r '(if type=="array" then . else (.rigs // []) end)[] | .name' 2>/dev/null); do
  # `gc bd list` from the city root sees only the town ledger, so every read and
  # every write must name its rig explicitly.
  ids=$(gc bd list --rig "$rig" --status open --json 2>/dev/null | jq -r '
    .[]
    | select(.metadata != null)
    | select((.metadata["gc.routed_to"] // "") | endswith(".brakeman"))
    | select((.metadata["gc.kind"] // "") == "")
    | select((.metadata["merge_strategy"] // "") == "")
    | .id' 2>/dev/null)

  for id in $ids; do
    if gc bd update --rig "$rig" "$id" --set-metadata "merge_strategy=$STRATEGY" >/dev/null 2>&1; then
      stamped=$((stamped + 1))
    else
      failed="$failed $rig/$id"
    fi
  done
done

# Silence is the success case. Only an unstampable bead is worth waking anyone
# for: it will reach the refinery with no strategy and merge straight to the
# default branch.
if [ -n "$failed" ]; then
  gc mail send mayor \
    -s "merge-gate: could not set merge_strategy on routed work" \
    -m "These beads are routed to a worker pool but could not be stamped with merge_strategy=$STRATEGY:$failed

Each will reach the refinery with no strategy, and gastown's refinery defaults to 'direct' — an unreviewed agent commit on the rig's default branch. Stamp them by hand:

  gc bd update --rig <rig> <bead> --set-metadata merge_strategy=$STRATEGY" >/dev/null 2>&1
fi

exit 0
