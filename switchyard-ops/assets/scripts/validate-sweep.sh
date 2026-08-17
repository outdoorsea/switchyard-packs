#!/bin/sh
# validate-sweep: the pack-native CONTRACT validator lane.
#
# WHY THIS EXISTS. COMPANION.md carried two COMPANION-REQUIRED rows — the
# contract re-run against merged main (`switchyard-companion validate`) and the
# SSE event bridge (`watch`). On a city that runs no companion (companion is for
# non-city users; a city's lanes come from the pack), those rows meant a fully
# contract-bearing PRD was reachable by NO validator at all: the judge agent
# deliberately takes only criteria declaring no command, and nothing else may
# self-validate (separation of duties). This order closes the validate row;
# event-pump closes the watch row.
#
# THE VERDICT IS THE EXIT CODE, NOTHING ELSE. This lane never reasons about the
# work: claim a delivered contract-bearing criterion (lane=contract — the server
# partitions the lanes, so a judgment criterion can never be handed to us), run
# its declared `verify_command` against merged main, post `done` on exit 0 and
# `fail` otherwise, with the run recorded verbatim in the verdict's
# `verification` block. Judgment stays in the judge agent's session.
#
# A FAIL RELEASES, NEVER COMPLETES. `validations/action done` is for a `done`
# verdict only: a fail resets the criterion to `outstanding` for re-work, and
# that re-work must be validatable again — completing the stake on a fail
# strands the criterion forever (docs/claim-pool-mcp.md's one hard rule for the
# validation lane, enforced here by construction: the action word is derived
# from the verdict, not chosen).
#
# THE CHECKOUT IS THE LANE'S OWN, AND EVERY GUARD FAILS CLOSED. Contracts run in
# `validate-repo.<rig>` under the pack state dir — never the rig root, which
# live workers read and dirty. Before any verdict the cycle must (1) fetch and
# hard-reset that checkout to origin's default branch (a stale tree banks
# verdicts about the wrong code), and (2) pass the rig's optional prep guard
# (`validate-prep.<rig>.sh` beside the state markers) — the hook where a project
# regenerates gitignored code and proves its test harness actually executes
# (e.g. switchyard regenerates templ output and runs a Dolt canary test, because
# a wholesale-skipped `go test` suite exits 0 and would bank a false terminal
# `done`). Any guard failing means the cycle validates NOTHING for that rig and
# says so: the safe failure is a criterion nobody validates, the unsafe one is a
# criterion marked done on evidence never produced.
#
# BOUNDED, AND SAFE TO KILL. At most VALIDATE_MAX_PER_CYCLE criteria per cycle
# per rig, each command under its own timeout shorter than the claim lease, and
# a TERM/INT mid-run releases the held claim rather than posting a verdict — a
# killed cycle costs a re-claim, never a wrong verdict and never a stranded
# stake (the server's lease reclaim is the backstop if even the release is
# lost).
set -u

. "$(dirname "$0")/../lib/roster.sh"
. "$(dirname "$0")/../lib/switchyard-api.sh"

# roster.conf is the ONLY source of RIG_PROJECTS and VALIDATE_*; see the
# repair-sweep header for the measured cost of omitting this call.
sy_load_conf

# Opt-in rig list. Unset = lane off everywhere; a city that never enables it
# must never notice this order exists.
VALIDATE_RIGS="${VALIDATE_RIGS:-}"
# `<rig>=<git-url>` pairs, space-separated — where to clone a rig's validate
# checkout from on first run. A rig with no entry and no existing checkout is
# skipped WITH MAIL: silently skipping would read as a drained backlog.
VALIDATE_REPOS="${VALIDATE_REPOS:-}"
# `<rig>=<branch>` pairs — the branch contracts are validated against, when the
# code lands somewhere other than origin's default branch (an integration
# branch policy). Unset = origin's default branch.
VALIDATE_BRANCHES="${VALIDATE_BRANCHES:-}"
# Per-cycle drain bound and per-command wall clock. The lease must outlive the
# command by enough to post the verdict; 1800s lease vs 900s command leaves the
# posting half the same margin again.
VALIDATE_MAX_PER_CYCLE="${VALIDATE_MAX_PER_CYCLE:-4}"
VALIDATE_CMD_TIMEOUT="${VALIDATE_CMD_TIMEOUT:-900}"
VALIDATE_LEASE_SECONDS="${VALIDATE_LEASE_SECONDS:-1800}"

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0
[ -n "$VALIDATE_RIGS" ] || exit 0

token="$(sy_api_token)"
[ -n "$token" ] || exit 0
projects="$(sy_api_projects "$token")"
[ -n "$projects" ] || exit 0

state="$(sy_state_dir)"
mkdir -p "$state" 2>/dev/null || exit 0

# sy_mail_mayor SUBJECT BODY — escalations go to the resident coordinator, the
# same path every other order uses. Best-effort: a failed mail must not fail the
# sweep (the report line still names the problem).
vs_mail() {
  gc mail send mayor --subject "$1" --body "$2" >/dev/null 2>&1 || true
}

# vs_mail_once KEY SUBJECT BODY — one mail per distinct failure fingerprint, so
# a standing misconfiguration alerts once instead of every 15 minutes. The
# marker clears when the failure stops being reported (cleared below on a
# healthy cycle for the rig).
vs_mail_once() {
  _mk="$state/validate-sweep.alert.$1"
  [ -f "$_mk" ] && return 0
  vs_mail "$2" "$3" && : >"$_mk" 2>/dev/null || true
}

# vs_repo_url RIG — the clone URL VALIDATE_REPOS binds for RIG, or empty.
vs_repo_url() {
  for _pair in $VALIDATE_REPOS; do
    case "$_pair" in "$1="*) printf '%s' "${_pair#"$1"=}"; return 0 ;; esac
  done
  printf ''
}

# vs_branch RIG — the branch VALIDATE_BRANCHES binds for RIG, or empty.
vs_branch() {
  for _pair in $VALIDATE_BRANCHES; do
    case "$_pair" in "$1="*) printf '%s' "${_pair#"$1"=}"; return 0 ;; esac
  done
  printf ''
}

# vs_release PRD CRIT WHO — return a held stake to the queue. Best-effort by
# design: the server's lease reclaim self-heals a lost release.
vs_release() {
  sy_api_post "/api/v1/prds/$1/validations/action" "$token" \
    "$(jq -nc --arg c "$2" --arg w "$3" '{crit_label:$c, claimed_by:$w, action:"release"}')" \
    >/dev/null 2>&1 || true
}

# The claim held RIGHT NOW, for the kill trap. One at a time by construction.
HELD_PRD=""
HELD_CRIT=""
HELD_BY=""
on_term() {
  [ -n "$HELD_PRD" ] && vs_release "$HELD_PRD" "$HELD_CRIT" "$HELD_BY"
  exit 143
}
trap on_term TERM INT

for rig in $VALIDATE_RIGS; do
  project="$(sy_project_for_rig "$rig" "$projects")"
  if [ -z "$project" ]; then
    vs_mail_once "scope-$rig" \
      "validate-sweep: rig $rig resolves to no project" \
      "VALIDATE_RIGS names '$rig' but sy_project_for_rig resolved nothing. Check RIG_PROJECTS in roster.conf. No criterion was validated for it this cycle, and none will be until this is fixed."
    continue
  fi

  # The validator identity. Distinct from every builder identity by
  # construction (builders are brakeman adhoc sessions), which is what keeps
  # separation of duties from starving the lane.
  validator="$rig/switchyard-ops.validator"

  # --- Guard 1: the lane's own checkout, hard-reset to merged main -----------
  repo="$state/validate-repo.$rig"
  if [ ! -d "$repo/.git" ]; then
    url="$(vs_repo_url "$rig")"
    if [ -z "$url" ]; then
      vs_mail_once "norepo-$rig" \
        "validate-sweep: no checkout and no VALIDATE_REPOS entry for $rig" \
        "The contract lane for '$rig' has no $repo checkout and roster.conf's VALIDATE_REPOS carries no '$rig=<git-url>' pair to clone one from. The contract backlog for $project is validated by NOBODY until one is added."
      continue
    fi
    git clone --quiet "$url" "$repo" >/dev/null 2>&1 || {
      vs_mail_once "clone-$rig" \
        "validate-sweep: clone failed for $rig" \
        "git clone $url -> $repo failed; the contract lane for $project validated nothing this cycle."
      continue
    }
  fi
  default_branch="$(vs_branch "$rig")"
  if [ -z "$default_branch" ]; then
    default_branch="$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  fi
  [ -n "$default_branch" ] || default_branch=main
  if ! git -C "$repo" fetch --quiet origin "$default_branch" >/dev/null 2>&1 ||
     ! git -C "$repo" reset --hard --quiet "origin/$default_branch" >/dev/null 2>&1; then
    vs_mail_once "fresh-$rig" \
      "validate-sweep: cannot refresh $rig checkout to merged $default_branch" \
      "fetch/reset in $repo failed. Validating against a stale tree banks verdicts about the wrong code, so the lane refused to run for $project this cycle."
    continue
  fi

  # --- Guard 2: the rig's prep hook (regenerate + prove-the-harness) ---------
  prep="$state/validate-prep.$rig.sh"
  if [ -f "$prep" ]; then
    if ! (cd "$repo" && sh "$prep") >/dev/null 2>&1; then
      vs_mail_once "prep-$rig" \
        "validate-sweep: prep guard refused for $rig" \
        "$prep exited non-zero in $repo. The guard exists to stop false verdicts (missing generated code reads as a false fail; a wholesale-skipped suite reads as a false done), so the lane validated nothing for $project this cycle."
      continue
    fi
  fi

  # A healthy rig clears its standing alerts so a FIXED misconfiguration can
  # alert again if it regresses.
  rm -f "$state/validate-sweep.alert.scope-$rig" "$state/validate-sweep.alert.norepo-$rig" \
        "$state/validate-sweep.alert.clone-$rig" "$state/validate-sweep.alert.fresh-$rig" \
        "$state/validate-sweep.alert.prep-$rig" 2>/dev/null

  # --- Register the validator so its verdicts are not refused unregistered ---
  reg="$(sy_api_post "/api/v1/projects/$project/agents" "$token" \
    "$(jq -nc --arg r "$validator" '{agent_ref:$r, display_name:"switchyard-ops validate-sweep", source:"mcp"}')")"
  if [ -z "$reg" ]; then
    vs_mail_once "register-$rig" \
      "validate-sweep: validator registration refused for $rig" \
      "POST /agents for $validator on $project returned nothing. An unregistered validator's verdicts are refused 404, so the lane stopped before claiming rather than spend runs it cannot bank."
    continue
  fi
  rm -f "$state/validate-sweep.alert.register-$rig" 2>/dev/null

  echo "validate-sweep: $rig -> $project (checkout $(git -C "$repo" rev-parse --short HEAD))"

  # --- The drain loop --------------------------------------------------------
  # failed_crits is the cycle-local wedge guard (issue 377): a fail RELEASES its
  # stake, which makes the criterion immediately re-claimable, so the claim
  # endpoint hands the same queue head straight back — one persistently failing
  # criterion would eat the whole cycle budget and nothing behind it would ever
  # be reached. A criterion this cycle already failed (banked or withheld) is
  # released untouched and the cycle ends; the next cycle retries it fresh.
  failed_crits=" "
  n=0
  while [ "$n" -lt "$VALIDATE_MAX_PER_CYCLE" ]; do
    claim="$(sy_api_post "/api/v1/projects/$project/validations/claim" "$token" \
      "$(jq -nc --arg w "$validator" --argjson l "$VALIDATE_LEASE_SECONDS" '{claimed_by:$w, lane:"contract", lease_seconds:$l}')")"
    if [ -z "$claim" ]; then
      vs_mail_once "claim-$rig" \
        "validate-sweep: validation claim unreadable for $rig" \
        "POST /validations/claim on $project returned nothing (network, token, or a refused body). The contract backlog is validated by nobody until this clears."
      break
    fi
    rm -f "$state/validate-sweep.alert.claim-$rig" 2>/dev/null
    [ "$(printf '%s' "$claim" | jq -r '.claimed // false')" = "true" ] || break

    prd_id="$(printf '%s' "$claim" | jq -r '.task.prd_id // empty')"
    crit="$(printf '%s' "$claim" | jq -r '.task.crit_label // empty')"
    cmd="$(printf '%s' "$claim" | jq -r '.task.verify_command // empty')"
    evidence="$(printf '%s' "$claim" | jq -r '.task.evidence_ref // empty')"
    if [ -z "$prd_id" ] || [ -z "$crit" ] || [ -z "$cmd" ]; then
      # A contract-lane task with no runnable command is a server-side
      # contradiction; release rather than guess.
      [ -n "$prd_id" ] && [ -n "$crit" ] && vs_release "$prd_id" "$crit" "$validator"
      break
    fi
    case "$failed_crits" in *" $crit "*)
      # The queue head is a criterion this cycle already failed; re-running it
      # buys the same verdict again (issue 377). Release and end the cycle.
      vs_release "$prd_id" "$crit" "$validator"
      echo "validate-sweep: $project $crit -> already failed this cycle; queue head wedged, cycle ends"
      break
      ;;
    esac
    HELD_PRD="$prd_id"; HELD_CRIT="$crit"; HELD_BY="$validator"

    ran_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    out_file="$state/validate-sweep.run.$$"
    (cd "$repo" && sy_timeout "$VALIDATE_CMD_TIMEOUT" sh -c "$cmd") >"$out_file" 2>&1
    code=$?

    # Issue 299: a `go test -run <pattern>` that matches NO tests exits 0 and
    # prints "[no tests to run]". Treating that as a passing verdict banks a
    # `done` on work that was never built. Flip it to a failing run so the
    # criterion returns to the pool instead of being falsely signed off.
    #
    # Issue 377: the marker is judged per PACKAGE, not per run. A multi-package
    # pattern (`go test ./... -run X` and friends) prints the marker for every
    # package the pattern matches nothing in, even when the target package ran
    # its tests and passed — grepping the whole output flipped genuinely
    # passing runs to false fails. Vacuous means NO package ran a test: every
    # `ok` package line carries the marker. One `ok` line without it is a real
    # test execution and the exit code stands.
    no_tests_matched=""
    if [ "$code" -eq 0 ] && grep -qiF "no tests to run" "$out_file"; then
      ran_real="$(grep -E '^ok[[:space:]]' "$out_file" | grep -cviF "no tests to run")" || true
      if [ "${ran_real:-0}" -eq 0 ]; then
        code=1
        no_tests_matched="1"
      fi
    fi

    excerpt="$(tail -c 2000 "$out_file" 2>/dev/null)"
    rm -f "$out_file" 2>/dev/null

    if [ "$code" -eq 0 ]; then
      verdict="done"
      outcome="passed"
    else
      # A non-zero exit against a PRD with NO merged delivery on record
      # (empty evidence_ref) is most plausibly "the code is not on this branch
      # yet" — an integration-branch policy keeps criterion code off the
      # validated tree until the whole PRD merges. Banking a fail there resets
      # delivered work for a rebuild whose real blocker is a merge, which is
      # the exact false-negative class that got the judge lane suspended. So
      # the fail is WITHHELD: release the stake with no verdict and let the
      # criterion wait for its merge; a passing run still banks done (the code
      # being present and passing is evidence in itself).
      if [ -z "$evidence" ]; then
        vs_release "$prd_id" "$crit" "$validator"
        HELD_PRD=""; HELD_CRIT=""; HELD_BY=""
        failed_crits="$failed_crits$crit "
        echo "validate-sweep: $project $crit -> fail WITHHELD (no merged delivery on record; released for re-claim after merge)"
        n=$((n + 1))
        continue
      fi
      verdict="fail"
      if [ -n "$no_tests_matched" ]; then
        outcome="failed (exit 0 but 'no tests to run' — the declared contract no longer exists)"
      else
        outcome="failed (exit $code)"
      fi
    fi
    rationale="Automated validation (switchyard-ops validate-sweep). Re-ran the criterion's declared contract against merged $default_branch: \`$cmd\` — $outcome. The verdict is derived from the exit code alone; no judgment was applied."

    body="$(jq -nc \
      --arg c "$crit" --arg v "$verdict" --arg e "$evidence" --arg r "$validator" \
      --arg ra "$rationale" --arg cmd "$cmd" --argjson code "$code" \
      --arg ex "$excerpt" --arg at "$ran_at" \
      '{crit_label:$c, verdict:$v, evidence_ref:$e, validator_agent_ref:$r,
        rationale:$ra, verdict_provenance:"contract",
        verification:{command:$cmd, exit_code:$code, output_excerpt:$ex, ran_at:$at}}')"
    resp="$(sy_api_post "/api/v1/prds/$prd_id/validate" "$token" "$body")"
    if [ -z "$resp" ]; then
      # The verdict did not bank (refused or unreachable). Free the stake so a
      # working validator can take it, and say so once.
      vs_release "$prd_id" "$crit" "$validator"
      HELD_PRD=""; HELD_CRIT=""; HELD_BY=""
      vs_mail_once "verdict-$rig" \
        "validate-sweep: a verdict was refused on $project" \
        "POST /prds/$prd_id/validate ($crit, $verdict) returned nothing. The claim was released; the criterion stays validatable. If this repeats, check the validator registration and the server logs — a refused verdict is otherwise invisible (the criterion just reads outstanding)."
      break
    fi
    rm -f "$state/validate-sweep.alert.verdict-$rig" 2>/dev/null

    # done completes the stake; fail RELEASES it (see header). Derived, not
    # chosen: there is no code path that can pair a fail with `done`.
    if [ "$verdict" = "done" ]; then act="done"; else act="release"; failed_crits="$failed_crits$crit "; fi
    sy_api_post "/api/v1/prds/$prd_id/validations/action" "$token" \
      "$(jq -nc --arg c "$crit" --arg w "$validator" --arg a "$act" '{crit_label:$c, claimed_by:$w, action:$a}')" \
      >/dev/null 2>&1 || true
    HELD_PRD=""; HELD_CRIT=""; HELD_BY=""

    echo "validate-sweep: $project $crit -> $verdict ($cmd)"
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] && echo "validate-sweep: $rig banked $n verdict(s)" || echo "validate-sweep: $rig idle (no claimable contract criteria)"
done
exit 0
