#!/bin/sh
# pr-refresh: rebase stalled PRs onto the branch they target (see
# orders/pr-refresh.toml for the why; this header covers the mechanics).
#
# WHAT IT TOUCHES, EXACTLY. For each rig in PR_REFRESH_RIGS: enumerate open,
# NON-DRAFT pull requests targeting the rig's refresh base (the branch policy's
# integration branch when the API serves one, else the rig's roster.conf
# override, else nothing — an unresolvable base refreshes nothing, loudly).
# A PR whose head is >= PR_REFRESH_MIN_BEHIND commits behind the base is
# rebased onto the base tip in the lane's OWN clone and force-pushed WITH LEASE
# to the PR's head branch. The lease is the safety: a hand that pushed to the
# branch since our fetch wins, and the push is refused rather than clobbering.
#
# WHAT IT NEVER DOES: merge anything, push to the base branch, touch a draft,
# resolve a conflict. A rebase that conflicts is ABORTED — the PR branch is
# untouched — and mailed once per (PR, head sha); a new push re-arms the alert
# (the auto-release head_sha re-fire rule), because a conflicted stall is
# exactly the state a human must resolve and a once-per-cycle mail would bury.
#
# BOUNDED: at most PR_REFRESH_MAX_PER_CYCLE rebases per rig per cycle — each
# one restarts that PR's CI, and the point is freshness, not a thundering herd.
set -u

. "$(dirname "$0")/../lib/roster.sh"
. "$(dirname "$0")/../lib/switchyard-api.sh"

sy_load_conf

# Opt-in rig list; unset = the lane is off everywhere.
PR_REFRESH_RIGS="${PR_REFRESH_RIGS:-}"
# `<rig>=<git-url>` pairs for the lane's clone. Falls back to VALIDATE_REPOS —
# the validate lane clones the same repository, and two config keys for one URL
# is drift waiting to happen.
PR_REFRESH_REPOS="${PR_REFRESH_REPOS:-${VALIDATE_REPOS:-}}"
# `<rig>=<branch>` pairs — the refresh base when the project's branch policy
# does not serve one. The policy wins when present: it is what workers are
# TOLD to target, so it is what stalled PRs must be re-based against.
PR_REFRESH_BASES="${PR_REFRESH_BASES:-}"
# How far behind the base a PR must be before a rebase is worth its CI restart.
PR_REFRESH_MIN_BEHIND="${PR_REFRESH_MIN_BEHIND:-10}"
PR_REFRESH_MAX_PER_CYCLE="${PR_REFRESH_MAX_PER_CYCLE:-3}"

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || exit 0
[ -n "$PR_REFRESH_RIGS" ] || exit 0

token="$(sy_api_token)"
projects=""
[ -n "$token" ] && projects="$(sy_api_projects "$token")"

state="$(sy_state_dir)"
mkdir -p "$state" 2>/dev/null || exit 0

prf_mail_once() { # KEY SUBJECT BODY — one alert per standing fingerprint.
  _mk="$state/pr-refresh.alert.$1"
  [ -f "$_mk" ] && return 0
  gc mail send mayor --subject "$2" --body "$3" >/dev/null 2>&1 && : >"$_mk" 2>/dev/null || true
}

prf_pair() { # LIST RIG — the value bound for RIG in a "<rig>=<v>" list, or "".
  for _pair in $1; do
    case "$_pair" in "$2="*) printf '%s' "${_pair#"$2"=}"; return 0 ;; esac
  done
  printf ''
}

for rig in $PR_REFRESH_RIGS; do
  url="$(prf_pair "$PR_REFRESH_REPOS" "$rig")"
  if [ -z "$url" ]; then
    prf_mail_once "norepo-$rig" \
      "pr-refresh: no repo URL for $rig" \
      "PR_REFRESH_RIGS names '$rig' but neither PR_REFRESH_REPOS nor VALIDATE_REPOS carries a '$rig=<git-url>' pair. No PR was refreshed for it, and none will be until one is added."
    continue
  fi

  # The refresh base: the branch policy's integration branch when served (it is
  # what workers are TOLD to target), else the rig's configured override.
  base=""
  if [ -n "$projects" ]; then
    project="$(sy_project_for_rig "$rig" "$projects")"
    if [ -n "$project" ]; then
      base="$(sy_api_get "/api/v1/projects/$project/briefing" "$token" \
        | jq -r '.branch_policy.integration_branch // empty' 2>/dev/null)"
    fi
  fi
  [ -n "$base" ] || base="$(prf_pair "$PR_REFRESH_BASES" "$rig")"
  if [ -z "$base" ]; then
    prf_mail_once "nobase-$rig" \
      "pr-refresh: no refresh base for $rig" \
      "Neither the project's branch policy nor PR_REFRESH_BASES names the branch $rig's PRs target, so the lane cannot know what to rebase onto. Set the branch policy (project settings -> Branches) or add a '$rig=<branch>' pair."
    continue
  fi

  repo="$state/pr-refresh-repo.$rig"
  if [ ! -d "$repo/.git" ]; then
    git clone --quiet "$url" "$repo" >/dev/null 2>&1 || {
      prf_mail_once "clone-$rig" \
        "pr-refresh: clone failed for $rig" \
        "git clone $url -> $repo failed; no PR was refreshed this cycle."
      continue
    }
  fi
  git -C "$repo" fetch --quiet --prune origin >/dev/null 2>&1 || {
    prf_mail_once "fetch-$rig" \
      "pr-refresh: fetch failed for $rig" \
      "git fetch in $repo failed; refreshing against a stale base would rebase onto history, so the lane refused to run."
    continue
  }
  git -C "$repo" rev-parse --verify --quiet "origin/$base" >/dev/null 2>&1 || {
    prf_mail_once "badbase-$rig" \
      "pr-refresh: base branch origin/$base does not exist for $rig" \
      "The refresh base resolved to '$base' but origin has no such branch. Create it, or fix the policy/override."
    continue
  }
  rm -f "$state/pr-refresh.alert.norepo-$rig" "$state/pr-refresh.alert.nobase-$rig" \
        "$state/pr-refresh.alert.clone-$rig" "$state/pr-refresh.alert.fetch-$rig" \
        "$state/pr-refresh.alert.badbase-$rig" 2>/dev/null

  prs="$(cd "$repo" && sy_timeout "${PR_REFRESH_GH_TIMEOUT:-60}" gh pr list --base "$base" --state open \
    --json number,headRefName,isDraft --limit 100 2>/dev/null)" || prs=""
  [ -n "$prs" ] || { echo "pr-refresh: $rig unreadable PR list (gh); skipped"; continue; }

  n=0
  for row in $(printf '%s' "$prs" | jq -r '.[] | select(.isDraft | not) | "\(.number)\t\(.headRefName)"' 2>/dev/null | tr '\t' '|'); do
    [ "$n" -lt "$PR_REFRESH_MAX_PER_CYCLE" ] || break
    num="${row%%|*}"; head="${row#*|}"
    [ -n "$num" ] && [ -n "$head" ] || continue
    git -C "$repo" rev-parse --verify --quiet "origin/$head" >/dev/null 2>&1 || continue
    behind="$(git -C "$repo" rev-list --count "origin/$head..origin/$base" 2>/dev/null || echo 0)"
    [ "$behind" -ge "$PR_REFRESH_MIN_BEHIND" ] 2>/dev/null || continue

    head_sha="$(git -C "$repo" rev-parse "origin/$head")"
    conflict_marker="$state/pr-refresh.conflict.$rig.$num"
    if [ -f "$conflict_marker" ] && [ "$(cat "$conflict_marker" 2>/dev/null)" = "$head_sha" ]; then
      # Already found conflicted at THIS head and alerted; a new push clears it.
      continue
    fi

    if git -C "$repo" checkout --quiet -B "prf-tmp-$num" "origin/$head" >/dev/null 2>&1 &&
       git -C "$repo" -c user.email=pr-refresh@switchyard-ops -c user.name=pr-refresh \
         rebase --quiet "origin/$base" >/dev/null 2>&1; then
      if git -C "$repo" push --quiet --force-with-lease origin "prf-tmp-$num:$head" >/dev/null 2>&1; then
        echo "pr-refresh: $rig PR #$num rebased onto $base ($behind behind) and pushed"
        rm -f "$conflict_marker" 2>/dev/null
        n=$((n + 1))
      else
        # The lease refused: someone pushed since our fetch. Their hand wins;
        # next cycle re-measures. Not a fault, not a mail.
        echo "pr-refresh: $rig PR #$num push refused by lease (branch moved); left alone"
      fi
    else
      git -C "$repo" rebase --abort >/dev/null 2>&1 || true
      printf '%s' "$head_sha" >"$conflict_marker" 2>/dev/null
      gc mail send mayor \
        --subject "pr-refresh: PR #$num conflicts with $base on $rig" \
        --body "Rebasing PR #$num ($head, $behind commits behind) onto $base conflicts, so the branch was left untouched. A conflicted stall needs a human (or the PR's author agent) to resolve; this alert re-arms only when the PR's head changes." \
        >/dev/null 2>&1 || true
      echo "pr-refresh: $rig PR #$num conflicts with $base; aborted untouched and mailed"
    fi
    git -C "$repo" checkout --quiet --detach "origin/$base" >/dev/null 2>&1 || true
  done
  echo "pr-refresh: $rig refreshed $n PR(s) against $base"
done
exit 0
