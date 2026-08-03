#!/bin/sh
# pr-gate: catch work that was published and then never merged.
#
# `publish-gate` covers the inverse failure — a bead that closed with no
# `pr_url`, work built but never pushed. This order covers the one the lane has
# no concept of at all: `sy-item-work`'s terminal state is "PR open", and that
# is modelled as SUCCESS. Nothing in the city ages an open PR, counts one, or
# escalates one. A rig can sit indefinitely with every bead closed, every
# switchyard surface green, and a stack of branches nobody ever merged.
#
# The only reason the first occurrence was noticed by a human at all was that an
# unrelated intake sweep happened to mention it in passing. That is not a
# control.
#
# SELECTOR — deliberately NOT filtered on status, unlike publish-gate.
# The live case that motivated this order (sf-hi5, PRD #287) was status=open
# with a pr_url already set, because `publish` runs BEFORE
# `close-source-anchor`: there is a real window where the PR exists and the bead
# has not closed yet. Filtering `--status closed` here would have missed the
# exact bead this order was written for. Select on `pr_url` presence instead,
# with `gc.kind` empty to exclude the workflow/step beads — the same split
# publish-gate documents, where `pr_url` lands on the WORK bead and never on the
# workflow root.
#
# ESCALATION — tiered, once per tier per PR.
# publish-gate mails once per bead, forever, because a bead that closed
# unpublished is a fixed historical fact. An open PR is the opposite: it is a
# live condition that gets worse with age, so once-only would report a PR at
# hour 4 and then go silent while it rots for a week. Re-reporting every sweep
# is the noise failure publish-gate explicitly warns about. Tiers are the middle
# path — each PR is reported when it CROSSES a tier and not again until it
# crosses the next one.
#
# CLASSES — the two are gated by different things and must not be nagged alike.
#   item PR (head `gc-item-*`, base = the PRD integration branch)
#     Policy is: judge reviews, then it auto-merges into the integration branch.
#     So an aged item PR is a LANE FAILURE — the judge never reviewed it, or the
#     merge step never fired. This is the actionable class.
#   integration PR (base = the rig default branch)
#     Gated on the PRD being complete and accepted in switchyard, then merged to
#     main and rebuilt. That is a legitimate long wait against a checkable
#     state, NOT a stall, so it is reported for awareness at a much wider tier
#     and never framed as a fault.
set -u

. "$(dirname "$0")/../lib/roster.sh"

sy_load_conf

# Tier boundaries in hours. Overridable in roster.conf.
# T1 is deliberately wider than one judge-sweep interval: a PR that opened five
# minutes ago is not a problem, it is the expected state, and the reviewer lane
# needs a full cycle to reach it before silence means anything.
PR_GATE_TIER1_HOURS="${PR_GATE_TIER1_HOURS:-4}"
PR_GATE_TIER2_HOURS="${PR_GATE_TIER2_HOURS:-24}"
PR_GATE_TIER3_HOURS="${PR_GATE_TIER3_HOURS:-72}"
# Integration -> main PRs wait on PRD acceptance, so they only get the wide tier.
PR_GATE_INTEGRATION_HOURS="${PR_GATE_INTEGRATION_HOURS:-168}"

SEEN="$(sy_state_dir)/pr-gate.reported"
mkdir -p "$(dirname "$SEEN")" 2>/dev/null
[ -f "$SEEN" ] || : > "$SEEN"

# No first-run seeding, unlike publish-gate. Its seeding exists because a city
# migrating off the gastown lane has a back catalogue of beads that legitimately
# closed with no pr_url. There is no equivalent back catalogue here: an open PR
# is open right now regardless of when this order was installed, and suppressing
# the existing set on install would hide precisely the backlog the order was
# added to surface.

# ISO8601 -> epoch, GNU then BSD. Same portability posture as sy_timeout.
iso_to_epoch() {
  date -u -d "$1" +%s 2>/dev/null && return 0
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null && return 0
  printf ''
}

now=$(date -u +%s)

# Accumulate through files, not shell variables. The bead rows are read in a
# `while read` loop; feeding that from a pipe puts it in a SUBSHELL, where every
# assignment is discarded on exit — the loop would find stalled PRs, mail
# nothing, and exit 0. That is a dead check that looks healthy, which is the
# failure class this pack exists to catch, so it is worth avoiding structurally
# rather than remembering to redirect correctly.
TMP=$(mktemp -d 2>/dev/null) || exit 0
trap 'rm -rf "$TMP"' EXIT INT TERM
: > "$TMP/stalled"
: > "$TMP/awaiting"

for rig in $(gc rig list --json 2>/dev/null | jq -r '(if type=="array" then . else (.rigs // []) end)[] | .name' 2>/dev/null); do
  default_branch=$(gc rig list --json 2>/dev/null | jq -r --arg r "$rig" '
    (if type=="array" then . else (.rigs // []) end)[]
    | select(.name==$r) | (.default_branch // "main")' 2>/dev/null)
  [ -n "$default_branch" ] || default_branch=main

  # `gc bd list` from the city root sees only the town ledger, so every read
  # must name its rig explicitly.
  #
  # --status MUST be passed explicitly and MUST name every status. Omitting the
  # flag does NOT mean "all statuses" — `gc bd list` defaults to OPEN only. The
  # SELECTOR note above reasoned about not filtering to `closed` and concluded
  # the flag could simply be left off; that silently narrowed this order to open
  # beads, which is the opposite of the intent and made it structurally blind.
  # `pr_url` is written by `publish`, and `close-source-anchor` closes the bead
  # moments later, so a bead carries a pr_url in the OPEN state only inside that
  # brief window and is CLOSED for the entire rest of the PR's life. Measured on
  # switchyard-forge: 0 open beads carried a pr_url while 38 closed ones did, so
  # this loop never once reached the `gh pr view` below — every PR, including a
  # 20h-old one against main, was invisible. The `gh-broken` latch in the state
  # file was a red herring: `gh` authenticates fine from the controller's exec
  # context (HOME and /opt/homebrew/bin are both present).
  # Comma-separated form is required: repeating -s silently overwrites.
  rows=$(gc bd list --rig "$rig" --json \
           --status open,in_progress,blocked,deferred,closed 2>/dev/null | jq -r '
    .[]
    | select(.metadata != null)
    | select((.metadata["pr_url"] // "") != "")
    | select((.metadata["gc.kind"] // "") == "")
    | "\(.id)\t\(.metadata["pr_url"])"' 2>/dev/null)

  [ -n "$rows" ] || continue
  printf '%s\n' "$rows" > "$TMP/rows"

  # Redirected from a file, NOT piped — see the subshell note above.
  while IFS="$(printf '\t')" read -r id url; do
    [ -n "${url:-}" ] || continue

    # Parse owner/repo/number straight out of the URL rather than resolving the
    # rig's remote — the URL is the record of where the PR actually went, and a
    # rig whose remote was retargeted would otherwise be queried in the wrong
    # repo and report a phantom "merged".
    slug=$(printf '%s' "$url" | sed -n 's#^https://github.com/\([^/]*/[^/]*\)/pull/[0-9]*$#\1#p')
    num=$(printf '%s' "$url" | sed -n 's#^.*/pull/\([0-9]*\)$#\1#p')
    if [ -z "$slug" ] || [ -z "$num" ]; then
      continue  # not a github PR url; nothing this order can check
    fi

    meta=$(gh pr view "$num" --repo "$slug" \
            --json state,baseRefName,headRefName,createdAt,reviewDecision,mergeable \
            2>/dev/null)
    if [ -z "$meta" ]; then
      : > "$TMP/gh_broken"
      continue  # transient gh/network failure — next sweep retries
    fi

    state=$(printf '%s' "$meta" | jq -r '.state // ""')
    [ "$state" = "OPEN" ] || continue   # MERGED/CLOSED are done; silence is success

    base=$(printf '%s' "$meta" | jq -r '.baseRefName // ""')
    head=$(printf '%s' "$meta" | jq -r '.headRefName // ""')
    created=$(printf '%s' "$meta" | jq -r '.createdAt // ""')
    review=$(printf '%s' "$meta" | jq -r '.reviewDecision // ""')
    mergeable=$(printf '%s' "$meta" | jq -r '.mergeable // ""')

    created_epoch=$(iso_to_epoch "$created")
    [ -n "$created_epoch" ] || continue
    age_h=$(( (now - created_epoch) / 3600 ))

    # Classify. An item branch is the worker lane's own naming convention.
    case "$head" in
      gc-item-*) class=item ;;
      *)         class=other ;;
    esac
    if [ "$base" = "$default_branch" ] && [ "$class" != "item" ]; then
      class=integration
    fi

    if [ "$class" = "integration" ]; then
      [ "$age_h" -ge "$PR_GATE_INTEGRATION_HOURS" ] || continue
      tier=I
    else
      if   [ "$age_h" -ge "$PR_GATE_TIER3_HOURS" ]; then tier=3
      elif [ "$age_h" -ge "$PR_GATE_TIER2_HOURS" ]; then tier=2
      elif [ "$age_h" -ge "$PR_GATE_TIER1_HOURS" ]; then tier=1
      else continue
      fi
    fi

    key="$rig/$id#$num:$tier"
    grep -qxF "$key" "$SEEN" 2>/dev/null && continue
    printf '%s\n' "$key" >> "$SEEN"

    line="  $rig/$id  $url
    base=$base  head=$head  age=${age_h}h  review=${review:-none}  mergeable=${mergeable:-unknown}"
    if [ "$class" = "integration" ]; then
      printf '%s\n' "$line" >> "$TMP/awaiting"
    else
      printf '%s\n' "$line" >> "$TMP/stalled"
    fi
  done < "$TMP/rows"
done

stalled=$(cat "$TMP/stalled" 2>/dev/null)
awaiting=$(cat "$TMP/awaiting" 2>/dev/null)

# Silence is the success case.
if [ -n "$stalled" ]; then
  gc mail send mayor \
    -s "pr-gate: item PR(s) open past review SLA — the merge lane is not moving" \
    -m "These item PRs are OPEN and aging. Policy for an item PR is: the judge
reviews it, then it merges into the PRD integration branch. An item PR sitting
here means that lane did not run to completion — not that someone is being slow.

$stalled
Most likely causes, cheapest first:

  1. The judge lane is not running or is throttled. Check its cadence:
       grep -A2 'judge-sweep' \$GC_CITY/city.toml
       gc session list | grep -i judge
     A judge-sweep interval widened for a quiet rig and never tightened once
     real intake arrived is the common one.

  2. The judge reviewed it but nothing merges. Review state is shown above;
     if it is APPROVED and the PR is still open, the merge step is the gap.

  3. The PR is not mergeable (conflicts). Shown above as mergeable=CONFLICTING.

Inspect one with:

  gh pr view <n> --repo <owner/repo> --json state,reviewDecision,mergeable,statusCheckRollup
  gh pr diff <n> --repo <owner/repo>

Each PR is reported once per age tier (${PR_GATE_TIER1_HOURS}h / ${PR_GATE_TIER2_HOURS}h / ${PR_GATE_TIER3_HOURS}h), not once per sweep." >/dev/null 2>&1
fi

if [ -n "$awaiting" ]; then
  gc mail send mayor \
    -s "pr-gate: integration PR(s) awaiting PRD acceptance for over ${PR_GATE_INTEGRATION_HOURS}h" \
    -m "These PRs target a rig's default branch, so they are the integration
branch merging as a body of work — not item PRs. This is NOT reported as a
stall: the gate is the PRD being complete and accepted, which is a legitimate
long wait.

$awaiting
It is flagged only because it has now been open long enough to be worth a look —
a PRD that finished and was accepted while nobody merged the branch would look
exactly like this.

Check whether the gate has actually cleared:

  switchyard: get_prd / get_project_briefing for the PRD this branch carries
  if it is complete and accepted, merging to main and rebuilding is in policy.

Reported once past ${PR_GATE_INTEGRATION_HOURS}h." >/dev/null 2>&1
fi

# A gh that is missing, unauthenticated, or rate-limited makes this order a dead
# check that looks healthy — the exact failure class this pack exists to catch —
# so it reports itself. Once only: a broken gh stays broken and does not need a
# mail every sweep.
if [ -f "$TMP/gh_broken" ]; then
  if ! grep -qxF "gh-broken" "$SEEN" 2>/dev/null; then
    printf 'gh-broken\n' >> "$SEEN"
    gc mail send mayor \
      -s "pr-gate: cannot query GitHub — this check is not running" \
      -m "\`gh pr view\` returned nothing for at least one PR with a recorded pr_url.
Until this is fixed, pr-gate cannot tell an open PR from a merged one and will
report nothing — indistinguishable from a healthy city.

  gh auth status
  gh api rate_limit --jq '.rate'

Reported once. Remove the 'gh-broken' line from $SEEN to re-arm." >/dev/null 2>&1
  fi
fi

exit 0
