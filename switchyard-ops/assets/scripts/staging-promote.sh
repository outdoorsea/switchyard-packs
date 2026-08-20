#!/bin/sh
# staging-promote: open and merge the staging -> default-branch promotion PR.
#
# Rationale, gates, and the PR-not-push decision live in
# orders/staging-promote.toml. Shared mechanics with merge-lane.sh: files not
# pipes (subshell-assignment trap), jq reads files not arguments (Linux's
# 128 KiB per-argument cap, hidden on macOS), every verdict queried fresh.
set -u

. "$(dirname "$0")/../lib/roster.sh"

sy_load_conf

STAGING_PROMOTE_RIGS="${STAGING_PROMOTE_RIGS:-}"
STAGING_PROMOTE_FROM="${STAGING_PROMOTE_FROM:-staging}"

[ -n "$STAGING_PROMOTE_RIGS" ] || exit 0

TMP=$(mktemp -d 2>/dev/null) || exit 0
trap 'rm -rf "$TMP"' EXIT INT TERM

LOG="$(sy_state_dir)/staging-promote.log"
REPORTED="$(sy_state_dir)/staging-promote.reported"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
[ -f "$REPORTED" ] || : > "$REPORTED"

# De-fang the two token forms the repo's guards act on: "PRD #N" attaches the
# PR to that PRD, "issue-N" closes that issue on merge. The constituent PRs
# already did both; the promotion must do neither.
defang() {
  sed -e 's/PRD #\([0-9]\)/PRD \1/g' -e 's/issue-\([0-9]\)/issue \1/g'
}

# One rollup verdict shared by both gates below: "<total> <pending> <bad>".
rollup() { # <meta.json path>
  jq -r '
    [.statusCheckRollup[]?
     | if .state? then
         (if .state == "SUCCESS" then "ok"
          elif .state == "PENDING" or .state == "EXPECTED" then "pending"
          else "bad" end)
       else
         (if .status != "COMPLETED" then "pending"
          elif .conclusion == "SUCCESS" or .conclusion == "NEUTRAL"
               or .conclusion == "SKIPPED" then "ok"
          else "bad" end)
       end]
    | "\(length) \([.[] | select(. == "pending")] | length) \([.[] | select(. == "bad")] | length)"
  ' "$1" 2>/dev/null || printf '0 0 1\n'
}

report_once() { # <key> <subject> <body>
  grep -qxF "$1" "$REPORTED" 2>/dev/null && return 0
  gc mail send mayor -s "$2" -m "$3" >/dev/null 2>&1 && printf '%s\n' "$1" >> "$REPORTED"
}

for rig in $STAGING_PROMOTE_RIGS; do
  rig_root="$(sy_rig_root "$rig")"
  [ -d "$rig_root/.git" ] || continue

  default_branch=$(gc rig list --json 2>/dev/null | jq -r --arg r "$rig" '
    (if type=="array" then . else (.rigs // []) end)[]
    | select(.name==$r) | (.default_branch // "main")' 2>/dev/null)
  [ -n "$default_branch" ] || default_branch=main

  slug=$(git -C "$rig_root" remote get-url origin 2>/dev/null \
    | sed -e 's#^git@github.com:##' -e 's#^https://github.com/##' -e 's#\.git$##')
  case "$slug" in
    */*) : ;;
    *)   continue ;;
  esac

  gh api "repos/$slug/compare/$default_branch...$STAGING_PROMOTE_FROM" \
    > "$TMP/compare.json" 2>/dev/null
  [ -s "$TMP/compare.json" ] || continue

  ahead=$(jq -r '.ahead_by // 0' "$TMP/compare.json")
  [ "${ahead:-0}" -gt 0 ] || continue   # nothing to promote; silence is success

  # Reuse the open promotion PR if one exists — a PR from a branch always
  # reflects the branch's current head, so a second one would be a duplicate.
  pr=$(gh pr list --repo "$slug" --state open \
        --head "$STAGING_PROMOTE_FROM" --base "$default_branch" \
        --json number --jq '.[0].number // empty' 2>/dev/null)

  if [ -z "$pr" ]; then
    jq -r '.commits[]? | "- " + (.commit.message | split("\n")[0])' \
      "$TMP/compare.json" 2>/dev/null | defang | head -60 > "$TMP/subjects"
    {
      printf 'Mechanical promotion of `%s` into `%s` (%s commits ahead), per the standing 30-minute promotion cadence (owner directive, 2026-08-19).\n\n' \
        "$STAGING_PROMOTE_FROM" "$default_branch" "$ahead"
      printf 'Every constituent below was individually reviewed and CI-verified before it merged into `%s`; this PR adds no content of its own, and the merge lands only once the trial-merge checks on THIS PR prove the combination.\n\n' \
        "$STAGING_PROMOTE_FROM"
      cat "$TMP/subjects"
      printf '\nOpened by the `staging-promote` pack order.\n'
    } > "$TMP/body"
    # issue-ref-exempt from birth: constituent subjects lead with fix()/close
    # and mention issues in prose, which the issue-ref guard reads as a closing
    # claim missing its token. A promotion PR names issues its constituents
    # already closed and must close nothing itself — the exemption is correct
    # by construction, and the first live promotion (PR 1758) proved the guard
    # fires without it.
    pr=$(gh pr create --repo "$slug" --base "$default_branch" \
          --head "$STAGING_PROMOTE_FROM" \
          --title "Promote $STAGING_PROMOTE_FROM to $default_branch ($ahead commits)" \
          --label issue-ref-exempt \
          --body-file "$TMP/body" 2>/dev/null \
          | sed -n 's#^.*/pull/\([0-9]*\)$#\1#p')
    if [ -z "$pr" ]; then
      report_once "create-failed-$rig" \
        "staging-promote: cannot open the promotion PR for $slug" \
        "gh pr create --head $STAGING_PROMOTE_FROM --base $default_branch failed on $slug. Until this is fixed nothing promotes, and the lane stays silent about it after this one mail."
      continue
    fi
    # Freshly created: its trial-merge checks have not run yet. Next tick merges.
    printf '%s opened promotion PR %s#%s (%s ahead)\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$slug" "$pr" "$ahead" >> "$LOG"
    continue
  fi

  gh pr view "$pr" --repo "$slug" \
    --json mergeable,headRefOid,statusCheckRollup > "$TMP/meta.json" 2>/dev/null
  [ -s "$TMP/meta.json" ] || continue

  mergeable=$(jq -r '.mergeable // ""' "$TMP/meta.json")
  head_oid=$(jq -r '.headRefOid // ""' "$TMP/meta.json")
  if [ "$mergeable" = "CONFLICTING" ]; then
    report_once "conflict-$head_oid" \
      "staging-promote: $slug promotion PR #$pr conflicts with $default_branch" \
      "The $STAGING_PROMOTE_FROM -> $default_branch promotion cannot merge cleanly at $head_oid. Someone landed work directly on $default_branch that staging does not contain; a person needs to back-merge $default_branch into $STAGING_PROMOTE_FROM."
    continue
  fi

  rollup "$TMP/meta.json" > "$TMP/ci"
  read -r total pending bad < "$TMP/ci"
  [ "${total:-0}" -gt 0 ] || continue     # checks not reported yet; next tick
  [ "${pending:-1}" = "0" ] || continue   # still proving; next tick
  if [ "${bad:-1}" != "0" ]; then
    report_once "red-$head_oid" \
      "staging-promote: $slug promotion PR #$pr is red at $head_oid" \
      "The trial-merge checks on the $STAGING_PROMOTE_FROM -> $default_branch promotion failed, so nothing promotes until the offending change is fixed or reverted on $STAGING_PROMOTE_FROM. The lane re-checks every tick and will mail again only if the head moves and fails again."
    continue
  fi

  if gh pr merge "$pr" --repo "$slug" --merge >/dev/null 2>&1; then
    printf '%s merged promotion PR %s#%s into %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$slug" "$pr" "$default_branch" >> "$LOG"
  else
    report_once "merge-failed-$head_oid" \
      "staging-promote: $slug promotion PR #$pr passed every gate but the merge failed" \
      "gh pr merge $pr --repo $slug --merge failed although the PR was mergeable and its checks were green. The lane retries every tick; if this repeats, the repo's merge rules are outside the lane's model."
  fi
done

exit 0
