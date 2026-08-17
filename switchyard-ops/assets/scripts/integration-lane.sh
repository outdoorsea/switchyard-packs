#!/bin/sh
# integration-lane: test the COMBINATION of the mergeable pull requests, not the
# parts, and hand a human one reviewable merge.
#
# THE GAP THIS CLOSES
# -------------------
# Every CI gate in this repo measures the PULL REQUEST HEAD, never the merge
# result. Two pull requests that are each green against their own base can be
# broken together, and nothing looks at that combination until it is on `main` —
# where Railway auto-deploys it. The failure is not hypothetical here:
#
#   PR #1490 bundled 8 PRs by hand and found two defects "neither visible on any
#   PR alone" — a rename that git merges clean and then fails to BUILD, and a
#   `schemaVersion` collision between #1464 and #1477.
#   PR #1484 and #1503 both added fields to the same `list_criteria` response
#   rows the same day, each green apart.
#
# `pr-gate` and `publish-gate` both DETECT stuck work and neither INTEGRATES.
# This order makes the hand method (#1483, #1490) a lane.
#
# THE LANE NEVER MERGES. Decided in PRD #340 question 305, and it is a positive
# choice rather than a half-built step. The value is the combination test, which
# is fully delivered without touching the production gate; and "green" has been
# unreliable here before — PR #1346 read green on ZERO checks, which is why the
# candidate filter below refuses an empty check rollup rather than rounding it up
# to success. There is no `gh pr merge` in this file and there must never be one:
# adding it converts a reporting lane into an unattended production deploy path.
#
# WHAT A RUN DOES
#   1. Collect the open PRs that are genuinely mergeable, RE-QUERYING the lazily
#      computed mergeability rather than trusting one read.
#   2. Refuse a `schemaVersion` collision among the constituents BEFORE testing
#      the combination — it is a known collision this repo has already hit, and
#      it is cheaper to name than to discover as a build failure.
#   3. Merge each constituent onto one integration branch with --no-ff.
#   4. Verify the COMBINATION. On a failure, eject the prime suspect and re-run,
#      so the break is attributed to the pair that interacted rather than to the
#      bundle as a whole, and one bad PR delays itself instead of the set.
#   5. Push the branch and open ONE pull request against the default branch.
#   6. Mail the mayor the bundle, the size it used, and everything it excluded
#      and why. Then stop. A human decides.
#
# TWO VERIFICATION LAYERS, DELIBERATELY
# -------------------------------------
# The LOCAL verify (INTEGRATION_LANE_VERIFY) is the PRE-FLIGHT. It is what gives
# the run a verdict it can ATTRIBUTE — you cannot eject a culprit you have not
# measured, and attribution needs a result inside the run. It defaults to
# `go build ./... && go vet ./...` because that is the fast half that catches the
# observed combination-defect class (#1490's clean-merging rename failed at
# BUILD), and because the full `go test ./...` cannot run here: `internal/db` and
# `internal/dashboard` hang for tens of minutes against a REACHABLE local Dolt,
# which a lane run always has and CI never does.
#
# The BUNDLE PR'S OWN CI is the second layer and the REAL measurement: its head
# IS the combination, so the repository's checks run against the merge result.
# ci.yml runs `go test ./...` there (plus a Dolt-backed job), so it is strictly
# stronger than the pre-flight — a combination defect that surfaces as a TEST
# failure, like the #1484 × #1503 pair that both added fields to the same
# `list_criteria` rows, is invisible to the pre-flight and caught only here.
#
# So the run WAITS for that CI and reports its verdict (bundle_ci_verdict). It
# used to stop at the pre-flight and mail "one merge is waiting for you" the
# moment `go build` passed — which told a human a bundle was verified while its
# actual CI was red, the exact false green this lane exists to prevent.
# INTEGRATION_LANE_CI_POLLS=0 opts out, at the cost of that guarantee.
#
# EACH LAYER ATTRIBUTES ITS OWN FAILURE, and they cannot do it the same way. The
# pre-flight ejects a suspect and RE-VERIFIES, so a wrong guess costs one more
# local run and is corrected on the spot. CI gets no second measurement at that
# price — re-running it costs another full wait per suspect — so a CI failure is
# attributed from the failing job's LOG instead: the files it names, matched
# against what each constituent changed (attribute_ci_failure). Without that, the
# STRONGER layer was the one that could not name a culprit, and every defect only
# CI can see arrived as "these 8 pull requests are broken together".
#
# WHY A LOCK
# ----------
# Two runs bundling overlapping sets would race on the same integration branch
# and could produce contradictory merges — the same class PR #1478 hardens
# pool-spawn against. `mkdir` is the lock: it is atomic on every POSIX
# filesystem, unlike a test-then-create on a lock FILE, which has a window
# between the two halves exactly wide enough for the second run to enter.
set -u

. "$(dirname "$0")/../lib/roster.sh"

sy_load_conf

# Bundle size. Read from configuration with a default of 8 (PRD #340 q305), and
# reported on every run — a three-PR bundle must never be ambiguous between "the
# queue was short" and "somebody changed the setting".
INTEGRATION_LANE_BUNDLE_SIZE="${INTEGRATION_LANE_BUNDLE_SIZE:-8}"

# The combination test. See the two-layers note above for why this is the fast
# half by default.
INTEGRATION_LANE_VERIFY="${INTEGRATION_LANE_VERIFY:-go build ./... && go vet ./...}"

# What must happen in the worktree BEFORE the verify can mean anything.
#
# This exists because omitting it made the lane useless on this very repo, in a
# way that looked exactly like a real finding. `*_templ.go` is GITIGNORED here
# (.gitignore: "regenerated by templ generate; never committed") — 0 tracked
# files against 66 `.templ` sources — so a FRESH worktree has none of them and
# `go build ./...` fails with `undefined: ProjectSpecRow` and friends before it
# ever reaches a line either constituent wrote. ci.yml runs `templ generate`
# precisely so its own build works.
#
# Without this step EVERY run reads red regardless of its constituents, ejects up
# to MAX_EJECTIONS innocent PRs with a fabricated attribution ("it builds alone
# but not beside #X"), and mails the mayor a combination alarm every cycle. A
# false alarm that names specific innocent pull requests is worse than no lane.
#
#   auto  (default) — generate templ views at the go.mod-PINNED version when the
#                     repo tracks any `.templ` file, and do nothing when it does
#                     not, so the lane stays usable on a rig without templ.
#   none            — skip preparation entirely.
#   <command>       — run this instead.
#
# Pinned, not `@latest`: generated code must match the version the module is
# built against, which is the same reason ci.yml resolves it from go.mod.
INTEGRATION_LANE_PREPARE="${INTEGRATION_LANE_PREPARE:-auto}"

# Wall-clock bound on one verify run. A verify that hangs would hold the lock and
# starve every later cycle, so it is bounded and a timeout is reported as a
# verify FAILURE rather than swallowed.
INTEGRATION_LANE_VERIFY_TIMEOUT="${INTEGRATION_LANE_VERIFY_TIMEOUT:-900}"

# How many times a run may eject a culprit and re-verify before giving up. Each
# ejection costs a full verify, and a bundle needing more than three is telling
# you the queue is unusually tangled — which is worth a human reading, not more
# machine time.
INTEGRATION_LANE_MAX_EJECTIONS="${INTEGRATION_LANE_MAX_EJECTIONS:-3}"

# How many times a run may eject a constituent after the BUNDLE'S OWN CI failed
# and re-bundle the remainder. Separate from MAX_EJECTIONS above because the two
# cost wildly different things: a pre-flight ejection costs one local verify,
# while this one costs a whole extra CI wait — so the pre-flight can afford to
# guess and re-measure, and this cannot.
#
# It is not zero, and that is the criterion. Attribution alone names the pair and
# unblocks nobody: the bundle sits red, and every constituent the failure never
# touched waits for a human to bisect by hand. One re-bundle turns that into "the
# pull request that broke it delays itself", which is the whole point of testing
# the combination early.
#
# Default 1 rather than more: the second red is a genuinely different situation —
# either the first attribution was wrong or the queue holds two independent
# combination defects — and both are worth a human reading rather than another
# thirty-minute wait. Set 0 to opt out and report the first CI failure as-is.
INTEGRATION_LANE_CI_REBUNDLES="${INTEGRATION_LANE_CI_REBUNDLES:-1}"

# Mergeability re-query. `mergeStateStatus` and `mergeable` are computed LAZILY
# by GitHub: the first read after a push is frequently UNKNOWN, and a stale DIRTY
# survives well past the merge that cleared it. A lane that trusts one read
# bundles unmergeable PRs and silently skips mergeable ones. Poll until it
# settles, then believe it.
INTEGRATION_LANE_MERGE_POLLS="${INTEGRATION_LANE_MERGE_POLLS:-5}"
INTEGRATION_LANE_MERGE_POLL_SLEEP="${INTEGRATION_LANE_MERGE_POLL_SLEEP:-3}"

# How long to wait for the integration branch's OWN CI to reach a verdict. This
# is the run's real measurement (see the two-layers note above), so the run does
# not end until CI has spoken or this budget is spent — a bundle reported before
# its checks finish is reported on the pre-flight alone, which is the weaker
# half. 60 × 30s = 30 minutes, sized under INTEGRATION_LANE_LOCK_STALE_MIN so a
# waiting run is never mistaken for an abandoned one and broken open beneath it.
#
# Set INTEGRATION_LANE_CI_POLLS=0 to skip the wait. That is a real choice for a
# rig whose CI does not run on branches, but it gives up this criterion's
# guarantee: the run then reports on `go build && go vet` alone.
INTEGRATION_LANE_CI_POLLS="${INTEGRATION_LANE_CI_POLLS:-60}"
INTEGRATION_LANE_CI_POLL_SLEEP="${INTEGRATION_LANE_CI_POLL_SLEEP:-30}"

# A lock older than this is treated as abandoned. Sized well above one full run.
INTEGRATION_LANE_LOCK_STALE_MIN="${INTEGRATION_LANE_LOCK_STALE_MIN:-90}"

# Narrow the lane to named rigs (space-separated). Empty means every rig.
INTEGRATION_LANE_RIGS="${INTEGRATION_LANE_RIGS:-}"

# Require an APPROVED review to enter a bundle. Default OFF, and the default is a
# judgement call worth naming rather than burying.
#
# PRD #340 puts review quality out of scope — "whether a PR should merge on its
# merits stays a human and judge-lane question" — and this lane only asks whether
# a SET is safe TOGETHER. Requiring APPROVED would also empty most bundles here,
# because a large share of PRs in this repo carry no review at all and
# `reviewDecision` is a LATCH that stays CHANGES_REQUESTED after the author has
# already pushed the fix. So the default admits an unreviewed PR and REFUSES a
# CHANGES_REQUESTED one — refuse-only, never require.
#
# The counter-argument is real: a human merging a bundle of eight is implicitly
# waving through any constituent nobody reviewed. If a city would rather bundle
# only blessed work and accept smaller bundles, this is the one line to flip —
# it is a policy setting, not a code change.
INTEGRATION_LANE_REQUIRE_APPROVAL="${INTEGRATION_LANE_REQUIRE_APPROVAL:-0}"

STATE_DIR="$(sy_state_dir)"
mkdir -p "$STATE_DIR" 2>/dev/null

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Make the worktree buildable before the verify runs. See INTEGRATION_LANE_PREPARE.
#
# Returns 0 when the tree is ready, 1 when preparation itself failed. That
# distinction is the whole point: a failure HERE is a fault in the LANE's own
# harness, not evidence about the constituents, and the caller must never eject
# anyone over it.
prepare_worktree() { # <worktree> <logfile>
  [ "$INTEGRATION_LANE_PREPARE" = "none" ] && return 0

  if [ "$INTEGRATION_LANE_PREPARE" != "auto" ]; then
    ( cd "$1" && sy_timeout "$INTEGRATION_LANE_VERIFY_TIMEOUT" \
        sh -c "$INTEGRATION_LANE_PREPARE" ) >> "$2" 2>&1
    return $?
  fi

  # A repo with no templ sources needs nothing, and must not be failed for it.
  [ -n "$(git -C "$1" ls-files '*.templ' 2>/dev/null | head -n1)" ] || return 0

  ( cd "$1" || exit 1
    tv=$(go list -m -f '{{.Version}}' github.com/a-h/templ 2>/dev/null)
    [ -n "$tv" ] || { echo "integration-lane: templ sources present but github.com/a-h/templ is not a module dependency"; exit 1; }
    go install "github.com/a-h/templ/cmd/templ@$tv" >/dev/null 2>&1 \
      || { echo "integration-lane: could not install templ $tv"; exit 1; }
    PATH="$(go env GOPATH)/bin:$PATH"
    export PATH
    sy_timeout "$INTEGRATION_LANE_VERIFY_TIMEOUT" templ generate
  ) >> "$2" 2>&1
}

# De-fang the repo's own PR-content guards when quoting a constituent's title.
#
# This lane AUTHORS a pull request into a repo that gates PR text:
#   `prd-ref guard`   refuses more than one `PRD #N` across title/body/branch
#   `issue-ref guard` matches the hyphenated `issue-N` bead token
# A bundle body that quoted eight constituent titles verbatim would carry eight
# `PRD #N` references and red its OWN checks — the lane would reliably produce
# an unmergeable bundle and blame the constituents. Quote titles with the hash
# and the hyphen removed: `PRD #91` -> `PRD 91`, `issue-249` -> `issue 249`.
# The reference is still readable by a human and no longer a machine token.
# This is the same convention CLAUDE.md prescribes for secondary mentions.
sanitize_ref_tokens() {
  sed -e 's/PRD #\([0-9]\)/PRD \1/g' \
      -e 's/PRD#\([0-9]\)/PRD \1/g' \
      -e 's/[Ii]ssue-\([0-9]\)/issue \1/g'
}

# Record an excluded pull request and WHY.
#
# Every exclusion goes through here and nowhere else. A run that reports success
# while a mergeable PR silently fell out of the set is the failure mode this
# whole file is written against: silent truncation reads as coverage.
exclude() { # <num> <title> <reason>
  printf '  #%s  %s\n      excluded: %s\n' \
    "$1" "$(printf '%s' "$2" | sanitize_ref_tokens)" "$3" >> "$TMP/excluded"
}

# Which constituents ALREADY on the branch collided with the one that just
# failed to merge — the pair, not the bundle.
#
# A merge conflict is localized by construction: git raises one only where BOTH
# sides changed the same path. So the counterpart is always among the merged
# constituents whose own change set contains a conflicted path, and intersecting
# the two sets names it exactly. Without this the only record of the event was
# "conflicts with the rest of the bundle", which blames a set of eight for a
# collision between two of them.
#
# Measured as `base...oid` — from each constituent's own MERGE-BASE, not the
# base tip — because `main` moves under the open PRs all day and a diff against
# the tip credits a constituent with every change that landed after it was cut.
conflict_counterparts() { # <worktree> <base_sha> <conflicted-paths-file>
  _cps=""
  while IFS="$(printf '\t')" read -r _cn _coid _ch _ct; do
    [ -n "${_cn:-}" ] || continue
    if git -C "$1" diff --name-only "$2...$_coid" 2>/dev/null \
         | grep -qFxf "$3" 2>/dev/null; then
      if [ -n "$_cps" ]; then _cps="$_cps, #$_cn"; else _cps="#$_cn"; fi
    fi
  done < "$TMP/merged"
  printf '%s' "$_cps"
}

# The constituents on the branch right now, as "#1, #2" — used when a failure
# cannot be narrowed to a pair and the honest report is the set that was built
# together.
merged_set() {
  awk -F'\t' '{printf "%s#%s", (NR>1 ? ", " : ""), $1}' "$TMP/merged" 2>/dev/null
}

# Take the per-rig lock, or return 1. `mkdir` is the atomic primitive.
lane_lock() { # <rig>
  _lock="$STATE_DIR/integration-lane.$1.lock"
  if mkdir "$_lock" 2>/dev/null; then
    printf '%s\n' "$$" > "$_lock/pid" 2>/dev/null
    date -u +%s > "$_lock/started" 2>/dev/null
    return 0
  fi

  # Held. Break it only if it is older than the stale window — a run that is
  # genuinely in flight must keep the lock, and a crashed run must not hold it
  # forever. Absent or unreadable `started` counts as stale: a lock we cannot age
  # is a lock we can never release, which is worse than one extra run.
  _started=$(cat "$_lock/started" 2>/dev/null)
  _now=$(date -u +%s)
  case "$_started" in
    ''|*[!0-9]*) _age_min=$((INTEGRATION_LANE_LOCK_STALE_MIN + 1)) ;;
    *)           _age_min=$(( (_now - _started) / 60 )) ;;
  esac
  if [ "$_age_min" -gt "$INTEGRATION_LANE_LOCK_STALE_MIN" ]; then
    rm -rf "$_lock" 2>/dev/null
    if mkdir "$_lock" 2>/dev/null; then
      printf '%s\n' "$$" > "$_lock/pid" 2>/dev/null
      date -u +%s > "$_lock/started" 2>/dev/null
      return 0
    fi
  fi
  return 1
}

# Say the run is still alive. The lock ages from `started`, so without this a
# LONG run and an ABANDONED one are the same fact, and the next cycle breaks the
# lock out from under a run that is merely waiting — two runs then bundle
# overlapping sets on one branch, which is the thing the lock exists to stop.
# Refreshing it makes the stale window mean "no progress" instead of "no finish".
lane_touch() { # <rig>
  date -u +%s > "$STATE_DIR/integration-lane.$1.lock/started" 2>/dev/null
}

lane_unlock() { # <rig>
  rm -rf "$STATE_DIR/integration-lane.$1.lock" 2>/dev/null
}

# Read a PR's mergeability, re-querying while GitHub reports it as not yet
# computed. Echoes "<mergeable>\t<mergeStateStatus>".
requery_mergeable() { # <slug> <num>
  _i=0
  _m=UNKNOWN
  _s=UNKNOWN
  while [ "$_i" -lt "$INTEGRATION_LANE_MERGE_POLLS" ]; do
    _json=$(gh pr view "$2" --repo "$1" --json mergeable,mergeStateStatus 2>/dev/null)
    if [ -n "$_json" ]; then
      _m=$(printf '%s' "$_json" | jq -r '.mergeable // "UNKNOWN"' 2>/dev/null)
      _s=$(printf '%s' "$_json" | jq -r '.mergeStateStatus // "UNKNOWN"' 2>/dev/null)
      # MERGEABLE/CONFLICTING are settled answers. UNKNOWN means GitHub has not
      # finished computing the merge; asking again is the whole point.
      if [ "$_m" != "UNKNOWN" ] && [ "$_s" != "UNKNOWN" ]; then
        break
      fi
    fi
    _i=$((_i + 1))
    [ "$_i" -lt "$INTEGRATION_LANE_MERGE_POLLS" ] && sleep "$INTEGRATION_LANE_MERGE_POLL_SLEEP"
  done
  printf '%s\t%s' "${_m:-UNKNOWN}" "${_s:-UNKNOWN}"
}

# The integration branch's OWN CI verdict, as "<verdict>\t<failing check names>".
#
#   green    every check finished and none failed
#   red      at least one check failed — the combination is broken
#   pending  checks exist but had not finished inside the poll budget
#   none     no check ever appeared for this branch
#
# THIS IS THE RUN'S MEASUREMENT. The local verify is a pre-flight: it defaults to
# `go build ./... && go vet ./...`, while this repo's ci.yml runs `go test ./...`
# and a Dolt-backed suite besides. A combination defect that surfaces as a TEST
# failure — two pull requests adding fields to the same response rows, the #1484
# × #1503 pair this PRD cites — passes the pre-flight and is caught only here. A
# run that reports before reading this is reporting on the weaker half.
#
# `none` is NOT green, and the distinction is the point. A rollup is legitimately
# empty for the first seconds after `gh pr create` (the workflows have not
# registered yet), which is why an empty read keeps polling rather than settling;
# but if it is STILL empty when the budget runs out, the combination was never
# measured. PR #1346 read green on ZERO checks. Rounding that up here — on the
# one branch the whole lane exists to measure — would make the lane's central
# claim the thing it is least entitled to say.
bundle_ci_verdict() { # <slug> <pr> <rig>
  _i=0
  _verdict=none
  _failed=""
  while [ "$_i" -lt "$INTEGRATION_LANE_CI_POLLS" ]; do
    # This wait is the longest thing a run does. Keep the lock warm through it,
    # or the next cycle reads a waiting run as a dead one.
    lane_touch "$3"
    _cjson=$(gh pr view "$2" --repo "$1" --json statusCheckRollup 2>/dev/null)
    if [ -n "$_cjson" ]; then
      # Same classification the candidate filter uses, deliberately: one
      # vocabulary for "what does a check rollup say" across the whole lane.
      # Pending is the INVERSE of COMPLETED, never an enumeration:
      # CheckStatusState also carries REQUESTED and WAITING and can grow, and a
      # status an enumeration missed would read as settled — a check that has
      # not run minting a premature green.
      _ctot=$(printf '%s' "$_cjson" | jq -r '(.statusCheckRollup // []) | length' 2>/dev/null)
      _cfail=$(printf '%s' "$_cjson" | jq -r '
        (.statusCheckRollup // [])
        | map(select(
            (.conclusion // "") == "FAILURE" or (.conclusion // "") == "CANCELLED"
            or (.conclusion // "") == "TIMED_OUT" or (.conclusion // "") == "ACTION_REQUIRED"
            or (.conclusion // "") == "STARTUP_FAILURE"
            or (.state // "") == "FAILURE" or (.state // "") == "ERROR"))
        | map(.name // .context // "check") | join(", ")' 2>/dev/null)
      _cpend=$(printf '%s' "$_cjson" | jq -r '
        (.statusCheckRollup // [])
        | map(select(
            (((.status // "") != "") and ((.status // "") != "COMPLETED"))
            or (.state // "") == "PENDING"))
        | length' 2>/dev/null)
      [ -n "${_ctot:-}" ] || _ctot=0
      [ -n "${_cpend:-}" ] || _cpend=0
      if [ -n "$_cfail" ]; then
        # A failure is settled news. Waiting for the rest to finish would only
        # delay a verdict that cannot improve.
        _verdict=red
        _failed="$_cfail"
        break
      fi
      if [ "$_ctot" -gt 0 ]; then
        if [ "$_cpend" -eq 0 ]; then
          _verdict=green
          break
        fi
        _verdict=pending
      fi
    fi
    _i=$((_i + 1))
    [ "$_i" -lt "$INTEGRATION_LANE_CI_POLLS" ] && sleep "$INTEGRATION_LANE_CI_POLL_SLEEP"
  done
  printf '%s\t%s' "$_verdict" "$_failed"
}

# The failing job's LOG, so a CI failure can be attributed rather than announced.
#
# A check NAME is not a defect. "build & test failed" is true of the bundle as a
# whole and implicates all eight constituents equally, which leaves a human to
# bisect by hand — the work this lane exists to have already done. The log is
# where the FILES are, and a file is the thread back to the pull request that
# changed it.
#
# The run id lives only inside `detailsUrl`
# (https://github.com/o/r/actions/runs/<run>/job/<job>), so it is parsed from
# there. Every failure is best-effort: a log this cannot fetch degrades to "could
# not attribute", never to a guess.
ci_failure_log() { # <slug> <pr-url>
  _ljson=$(gh pr view "$2" --repo "$1" --json statusCheckRollup 2>/dev/null)
  [ -n "$_ljson" ] || return 0
  _lruns=$(printf '%s' "$_ljson" | jq -r '
    (.statusCheckRollup // [])
    | map(select(
        (.conclusion // "") == "FAILURE" or (.conclusion // "") == "CANCELLED"
        or (.conclusion // "") == "TIMED_OUT" or (.conclusion // "") == "ACTION_REQUIRED"
        or (.conclusion // "") == "STARTUP_FAILURE"
        or (.state // "") == "FAILURE" or (.state // "") == "ERROR"))
    | map(.detailsUrl // "") | .[]' 2>/dev/null \
    | sed -n 's#.*/actions/runs/\([0-9][0-9]*\).*#\1#p' | sort -u)
  for _lr in $_lruns; do
    gh run view "$_lr" --repo "$1" --log-failed 2>/dev/null
  done
}

# Which constituents does a CI failure implicate, and on what evidence?
#
# Attribution here is derived from FILES, never from position in the merge order.
# The local pre-flight path can afford the order heuristic — it ejects its last
# constituent and RE-VERIFIES, so a wrong guess is corrected by the next cycle.
# CI attribution gets no such second measurement: re-running it costs another
# full CI wait per suspect. So the evidence has to come from the failure itself.
#
# Two signals:
#
#   CITED   the failing log names a file this pull request changed. Direct
#           evidence, and on its own what makes the failure attributable at all.
#   SHARED  two constituents changed the SAME file. That is the interaction —
#           it is exactly how #1484 and #1503 broke together, each green apart,
#           both adding fields to the same `list_criteria` response rows.
#
# A constituent implicated by NEITHER is not named, and that restraint is the
# whole criterion. A report that lists every constituent has attributed the
# defect to the bundle, which is what the human already knew from the red check.
#
# Writes the report to stdout; empty output means nothing could be attributed.
attribute_ci_failure() { # <worktree> <base-sha> <candidates> <ci-log> <scratch-dir>
  _awt=$1; _abase=$2; _acand=$3; _alog=$4; _adir=$5
  mkdir -p "$_adir" 2>/dev/null || return 0
  [ -s "$_alog" ] || return 0

  # Each constituent's changed files, measured against its OWN merge-base — the
  # same rule the schemaVersion check settled on, and for the same reason. A diff
  # against the base TIP lists every file `main` moved since the branch was cut,
  # so a pull request that touched nothing would be "cited" for somebody else's
  # file and the innocent-bystander case would name everyone.
  while IFS="$(printf '\t')" read -r _anum _aoid _ahead _atitle; do
    [ -n "${_anum:-}" ] || continue
    _amb=$(git -C "$_awt" merge-base "$_abase" "$_aoid" 2>/dev/null)
    [ -n "$_amb" ] || _amb=$_abase
    git -C "$_awt" diff --name-only "$_amb" "$_aoid" 2>/dev/null \
      | sort > "$_adir/f.$_anum"
  done < "$_acand"

  # CITED. -F, not a regex: a path contains `.` and `/`, and a file named
  # `internal/db/dolt.go` read as a pattern would also match text that merely
  # looks like it. One named file is enough to implicate.
  : > "$_adir/cited"
  while IFS="$(printf '\t')" read -r _anum _aoid _ahead _atitle; do
    [ -n "${_anum:-}" ] || continue
    while read -r _af; do
      [ -n "$_af" ] || continue
      # A boundary before the name, so `internal/db/wide.go` in the log does not
      # cite a constituent that only changed `wide.go`. Literal match still, via
      # index(): a path read as a regex would match text that merely looks like it.
      if awk -v f="$_af" '
           { p = index($0, f); if (p == 0) next
             if (p == 1) { found = 1; exit }
             c = substr($0, p - 1, 1)
             if (c !~ /[A-Za-z0-9._\/-]/) { found = 1; exit } }
           END { exit !found }' "$_alog" 2>/dev/null; then
        printf '%s\t%s\n' "$_anum" "$_af" >> "$_adir/cited"
        break
      fi
    done < "$_adir/f.$_anum"
  done < "$_acand"

  # SHARED. Ordered pairs only (a < b), so a pair is reported once and never
  # against itself.
  : > "$_adir/shared"
  while IFS="$(printf '\t')" read -r _aa _x1 _x2 _x3; do
    [ -n "${_aa:-}" ] || continue
    while IFS="$(printf '\t')" read -r _ab _y1 _y2 _y3; do
      [ -n "${_ab:-}" ] || continue
      [ "$_aa" -lt "$_ab" ] 2>/dev/null || continue
      _aboth=$(comm -12 "$_adir/f.$_aa" "$_adir/f.$_ab" 2>/dev/null | head -n3 | tr '\n' ' ')
      [ -n "$_aboth" ] || continue
      printf '%s\t%s\t%s\n' "$_aa" "$_ab" "$(printf '%s' "$_aboth" | sed 's/ $//')" >> "$_adir/shared"
    done < "$_acand"
  done < "$_acand"

  # IMPLICATED = cited, plus whoever shares a file with a cited one. The partner
  # is the other half of the interaction: when only one pull request's file is
  # named, the pull request it collides with in that file is the pair.
  cut -f1 "$_adir/cited" 2>/dev/null | sort -u > "$_adir/cited.nums"
  cp "$_adir/cited.nums" "$_adir/implicated" 2>/dev/null || : > "$_adir/implicated"
  while IFS="$(printf '\t')" read -r _aa _ab _afiles; do
    [ -n "${_aa:-}" ] || continue
    if grep -qx -- "$_aa" "$_adir/cited.nums" 2>/dev/null \
       || grep -qx -- "$_ab" "$_adir/cited.nums" 2>/dev/null; then
      printf '%s\n%s\n' "$_aa" "$_ab" >> "$_adir/implicated"
    fi
  done < "$_adir/shared"
  sort -un "$_adir/implicated" 2>/dev/null > "$_adir/implicated.sorted"
  mv "$_adir/implicated.sorted" "$_adir/implicated" 2>/dev/null

  _alist=$(sed 's/^/#/' "$_adir/implicated" 2>/dev/null | tr '\n' ' ' | sed -e 's/ $//' -e 's/ /, /g')
  if [ -z "$_alist" ]; then
    # NO FABRICATION. This lane has a scar here: a missing `templ generate` once
    # produced confident "it builds alone but not beside #X" attributions against
    # innocent pull requests on every single run. A named innocent is worse than
    # no name, so the honest answer is said out loud rather than filled in.
    printf 'Could not attribute this CI failure to any constituent: the failing job'\''s log\n'
    printf 'names no file that any of them changed. The break is real and the bundle is red;\n'
    printf 'what is missing is the thread from the failure back to a pull request.\n'
    if [ -s "$_adir/shared" ]; then
      printf '\nNot attribution, but the only overlap in the set — these constituents at least\n'
      printf 'change the same files, so they are where to look first:\n'
      while IFS="$(printf '\t')" read -r _aa _ab _afiles; do
        [ -n "${_aa:-}" ] || continue
        printf '  #%s and #%s both change: %s\n' "$_aa" "$_ab" "$_afiles"
      done < "$_adir/shared"
    fi
    return 0
  fi

  printf 'Combination CI failure attributed to: %s\n' "$_alist"
  while IFS="$(printf '\t')" read -r _anum _af; do
    [ -n "${_anum:-}" ] || continue
    printf '  #%s  changed %s, which the failing check names\n' "$_anum" "$_af"
  done < "$_adir/cited"
  # Evidence only for pairs the attribution actually names. `shared` holds every
  # overlap in the set; printing an unimplicated pair here would state a fact
  # about a constituent the very next line lists as not implicated, and the
  # evidence section would re-spread blame across the bundle.
  while IFS="$(printf '\t')" read -r _aa _ab _afiles; do
    [ -n "${_aa:-}" ] || continue
    grep -qx -- "$_aa" "$_adir/implicated" 2>/dev/null || continue
    grep -qx -- "$_ab" "$_adir/implicated" 2>/dev/null || continue
    printf '  #%s and #%s both change: %s\n' "$_aa" "$_ab" "$_afiles"
  done < "$_adir/shared"

  # Who is NOT implicated is part of the report too: it is what makes this an
  # attribution to a pair rather than a notice about the bundle, and it is what
  # tells the other constituents' authors they are not being asked to look.
  _arest=$(while IFS="$(printf '\t')" read -r _anum _x1 _x2 _x3; do
      [ -n "${_anum:-}" ] || continue
      grep -qx -- "$_anum" "$_adir/implicated" 2>/dev/null || printf '#%s ' "$_anum"
    done < "$_acand")
  [ -n "$_arest" ] && printf 'Not implicated by this failure: %s\n' \
    "$(printf '%s' "$_arest" | sed -e 's/ $//' -e 's/ /, /g')"
  return 0
}

# The `schemaVersion` a commit claims, or empty when the file is absent.
schema_version_at() { # <worktree> <ref>
  git -C "$1" show "$2:internal/db/dolt.go" 2>/dev/null \
    | sed -n 's/^const schemaVersion = \([0-9][0-9]*\).*$/\1/p' \
    | head -n1
}

# The report text, recomputed from the ledgers on disk.
#
# A re-bundle changes all of it — the exclusion ledger has grown by the ejected
# constituent and the bundle is one smaller — so it is derived where it is used
# rather than captured once and quietly gone stale.
report_text() {
  excluded_txt=$(cat "$TMP/excluded" 2>/dev/null)
  notes_txt=$(cat "$TMP/notes" 2>/dev/null)
  n_final=$(wc -l < "$TMP/candidates" 2>/dev/null | tr -d ' ')
  [ -n "$n_final" ] || n_final=0
  constituents=$(while IFS="$(printf '\t')" read -r num oid head title; do
      [ -n "${num:-}" ] || continue
      printf '  #%s  %s\n' "$num" "$(printf '%s' "$title" | sanitize_ref_tokens)"
    done < "$TMP/candidates")
}

# Merge the candidates onto one branch and test the COMBINATION, ejecting a
# pre-flight culprit and re-verifying. Sets `combination`.
combine_and_verify() {
  while : ; do
    n_in=$(wc -l < "$TMP/candidates" 2>/dev/null | tr -d ' ')
    [ -n "$n_in" ] || n_in=0
    if [ "$n_in" -lt 2 ]; then
      combination=abandoned
      return 0
    fi

    # Fresh branch each attempt: re-bundling on top of a half-merged attempt
    # would carry the ejected commit's tree along with it.
    git -C "$WT" checkout --quiet --detach "$base_sha" >/dev/null 2>&1
    : > "$TMP/merged"

    while IFS="$(printf '\t')" read -r num oid head title; do
      [ -n "${oid:-}" ] || continue
      # --no-ff ALWAYS. The constituent's own head SHA must stay reachable from
      # the bundle tip, because that reachability is the entire mechanism by
      # which GitHub auto-closes each constituent when the bundle merges.
      if git -C "$WT" merge --no-ff --no-edit \
           -m "Integration: merge #$num" "$oid" >/dev/null 2>&1; then
        printf '%s\t%s\t%s\t%s\n' "$num" "$oid" "$head" "$title" >> "$TMP/merged"
      else
        # A CONFLICT IS A COMBINATION FAILURE, and it gets the same attribution
        # the verify path gets. Both sides re-queried MERGEABLE against
        # $default_branch alone, so this collision exists ONLY in the bundle —
        # it is the single most common combination-only defect in a busy queue,
        # and it used to be reported as "conflicts with the rest of the bundle",
        # which is the whole set wearing the blame for a collision between two.
        #
        # Read the conflicted paths BEFORE `merge --abort`, which throws the
        # index away along with the only record of what broke.
        git -C "$WT" diff --name-only --diff-filter=U 2>/dev/null \
          | sort -u > "$TMP/conflicted"
        git -C "$WT" merge --abort >/dev/null 2>&1

        c_paths=$(awk '{printf "%s%s", (NR>1 ? ", " : ""), $0}' "$TMP/conflicted" 2>/dev/null \
                    | sanitize_ref_tokens)
        [ -n "$c_paths" ] || c_paths="not reported by git"
        c_with=$(conflict_counterparts "$WT" "$base_sha" "$TMP/conflicted")

        if [ -n "$c_with" ]; then
          exclude "$num" "$title" \
            "CONFLICTS with $c_with over $c_paths — each merges clean against $default_branch alone, so this collision exists only in combination"
          printf 'Combination CONFLICT attributed to #%s interacting with: %s\nConflicted paths: %s\n' \
            "$num" "$c_with" "$c_paths" >> "$TMP/notes"
        else
          # No merged constituent's change set contains a conflicted path. Say
          # so rather than inventing a counterpart — a named pair that is wrong
          # is worse than an honest "not narrowed".
          c_beside=$(merged_set)
          if [ -z "$c_beside" ]; then
            # NOTHING was on the branch yet, so this did not conflict with a
            # constituent at all: it conflicts with $default_branch itself, and
            # the MERGEABLE answer that admitted it was stale. Blaming the
            # bundle for that would be a fabricated combination defect.
            exclude "$num" "$title" \
              "conflicts with $default_branch itself over $c_paths — it was the first constituent merged, so no other pull request is implicated; its MERGEABLE answer was stale"
            printf 'NOT a combination failure: #%s conflicts with %s itself over %s. It was the first constituent merged, so nothing else was on the branch and no other pull request is implicated.\n' \
              "$num" "$default_branch" "$c_paths" >> "$TMP/notes"
          else
            # Reachable for rename/delete-modify shapes, where the conflicted
            # path need not appear in any constituent's name-only diff.
            exclude "$num" "$title" \
              "conflicts with the bundle over $c_paths (merged clean against $default_branch alone) — the counterpart could not be narrowed from the conflicted paths"
            printf 'Combination CONFLICT: #%s could not be merged beside %s, and the counterpart could not be narrowed from the conflicted paths.\nConflicted paths: %s\n' \
              "$num" "$c_beside" "$c_paths" >> "$TMP/notes"
          fi
        fi
      fi
    done < "$TMP/candidates"

    cp "$TMP/merged" "$TMP/candidates"
    n_merged=$(wc -l < "$TMP/merged" 2>/dev/null | tr -d ' ')
    [ -n "$n_merged" ] || n_merged=0
    if [ "$n_merged" -lt 2 ]; then
      combination=abandoned
      return 0
    fi

    # Make the tree buildable first. A failure HERE is the LANE's own harness
    # breaking, not a fact about the constituents, so it must never eject anyone
    # — that is precisely how a missing `templ generate` turned into fabricated
    # "it builds alone but not beside #X" attributions against innocent PRs.
    : > "$TMP/prepare.log"
    if ! prepare_worktree "$WT" "$TMP/prepare.log"; then
      combination=unpreparable
      return 0
    fi

    # THE COMBINATION TEST. This is the measurement the per-PR checks cannot
    # make, because they each ran against a different base.
    if ( cd "$WT" && sy_timeout "$INTEGRATION_LANE_VERIFY_TIMEOUT" \
           sh -c "$INTEGRATION_LANE_VERIFY" ) > "$verify_log" 2>&1; then
      combination=green
      return 0
    fi

    combination=red
    if [ "$ejections" -ge "$INTEGRATION_LANE_MAX_EJECTIONS" ]; then
      # THE EVIDENCE HAS TO SURVIVE THE CEILING. The attribution write below
      # sits in the ejection path, so returning here without it discarded the
      # failing output entirely. At the default ceiling of 3 that cost only the
      # final attempt's log; at 0 it cost every line, and the mail then asserted
      # "each green alone and BROKEN TOGETHER" while showing neither a pair nor
      # one line of build output.
      printf 'Combination failure NOT narrowed further: the ejection ceiling (%s) was reached after %s ejection(s), so no further constituent was ejected. The %s constituents built together were: %s\n%s\n' \
        "$INTEGRATION_LANE_MAX_EJECTIONS" "$ejections" "$n_merged" "$(merged_set)" \
        "$(tail -n 25 "$verify_log" | sanitize_ref_tokens)" >> "$TMP/notes"
      return 0
    fi

    # ATTRIBUTION. The bundle is built in a fixed order, so the LAST constituent
    # merged is the one whose addition turned a set that we are about to re-test
    # into a failing one. Eject it and re-verify: if the remainder goes green,
    # the interaction is between that PR and the set below it, which is a pair
    # a human can act on — and the ejected PR delays only itself.
    #
    # This is attribution, not proof of guilt. The report says which PRs
    # interacted, because "these two together break the build" is the actionable
    # fact; deciding which of the two is wrong is a review question.
    suspect=$(tail -n1 "$TMP/merged")
    s_num=$(printf '%s' "$suspect" | cut -f1)
    s_title=$(printf '%s' "$suspect" | cut -f4)
    remaining=$(awk -F'\t' -v n="$s_num" '$1!=n {printf "%s ", $1}' "$TMP/merged")
    exclude "$s_num" "$s_title" "ejected after a COMBINATION failure — it builds alone but not beside #$(printf '%s' "$remaining" | sed 's/ $//' | sed 's/ /, #/g')"
    printf 'Combination failure attributed to #%s interacting with: %s\n%s\n' \
      "$s_num" "$remaining" "$(tail -n 25 "$verify_log" | sanitize_ref_tokens)" >> "$TMP/notes"

    awk -F'\t' -v n="$s_num" '$1!=n' "$TMP/merged" > "$TMP/candidates"
    ejections=$((ejections + 1))
  done
}

# Push the verified bundle, open ONE pull request for it, and read that pull
# request's OWN CI — the run's real measurement. Sets `combination` and `pr_url`.
publish_bundle() {
  [ "$combination" = green ] || return 0

  git -C "$WT" branch -f "$branch" HEAD >/dev/null 2>&1
  if ! git -C "$WT" push --quiet origin "$branch:$branch" >/dev/null 2>&1; then
    printf 'the combination was green but pushing %s failed.\n' "$branch" >> "$TMP/notes"
    notes_txt=$(cat "$TMP/notes" 2>/dev/null)
    combination=push-failed
    return 0
  fi

  body="This bundle exists because **CI measures a pull request's head, never the merge
result**. Each constituent below is green against its own base; this branch is
the first place they were ever built TOGETHER.

Combination verified locally with: \`$INTEGRATION_LANE_VERIFY\`
Bundle size in use: $INTEGRATION_LANE_BUNDLE_SIZE
Constituents ($n_final):

$constituents
## MERGE THIS WITH A MERGE COMMIT

Not squash, not rebase. Each constituent's own head commit is reachable from
this branch, and that reachability is the entire mechanism by which GitHub
auto-closes every constituent pull request when this merges. A squash flattens
those commits away: the bundle would merge, and every constituent would be left
OPEN with its code already on \`main\`, each looking unmerged. $squash_note

## What this lane did NOT do

It did not merge anything, and it never will — that decision is yours. Read the
combination's checks on this pull request before merging: they are the only
checks in this repository that measure the merge result rather than a head."
  if [ -n "$rebundle_note" ]; then
    body="$body

## This is a re-bundle

$rebundle_note"
  fi
  if [ -n "$excluded_txt" ]; then
    body="$body

## Excluded from this bundle

$excluded_txt"
  fi
  if [ -n "$notes_txt" ]; then
    body="$body

## Notes

$notes_txt"
  fi
  # A failed `gh pr create` must NOT fall through as an empty URL. It did
  # once: the mayor got "one merge is waiting for you" with a blank link, no
  # error, and an orphaned integration branch on origin that nothing prunes.
  # Capture the status, and take the branch back down so a failed run leaves
  # no litter for the next one to trip over.
  if pr_url=$(gh pr create --repo "$slug" --base "$default_branch" --head "$branch" \
                --title "Integration bundle $stamp: $n_final PRs tested together" \
                --body "$body" 2>>"$TMP/notes"); then
    pr_url=$(printf '%s' "$pr_url" | tail -n1)
  else
    pr_url=""
  fi

  if [ -z "$pr_url" ]; then
    combination=create-failed
    if git -C "$WT" push --quiet origin ":$branch" >/dev/null 2>&1; then
      printf 'gh pr create failed; the pushed branch %s was deleted again, so nothing is orphaned.\n' \
        "$branch" >> "$TMP/notes"
    else
      printf 'gh pr create failed AND %s could not be deleted — an ORPHANED branch is on origin; remove it with: git push origin :%s\n' \
        "$branch" "$branch" >> "$TMP/notes"
    fi
    notes_txt=$(cat "$TMP/notes" 2>/dev/null)
    return 0
  fi

  # The bundle this one replaces is now a hazard rather than evidence: it holds
  # most of the same constituents and it is RED, so leaving it open invites
  # exactly the merge that would land the pull request just ejected. Closed
  # rather than deleted — a closed pull request keeps its failing checks and its
  # logs, which is the part worth keeping.
  if [ -n "$superseded_url" ]; then
    gh pr close "$superseded_url" --repo "$slug" --comment \
      "Superseded by $pr_url, which is the same bundle without the constituent its CI failure implicated. Closed so the two do not compete for one merge; this pull request's checks and logs stay readable as the evidence." \
      >/dev/null 2>&1
    printf 'Superseded bundle %s was closed in favour of %s.\n' \
      "$superseded_url" "$pr_url" >> "$TMP/notes"
    superseded_url=""
  fi

  [ "$INTEGRATION_LANE_CI_POLLS" -gt 0 ] || return 0

  # THE MEASUREMENT. The pull request's head is the combination, so its
  # checks are the only ones in this repository that judge the merge
  # result rather than somebody's head. Read them before saying a word to
  # a human: everything up to here was a pre-flight.
  ci_checked=1
  ci_out=$(bundle_ci_verdict "$slug" "$pr_url" "$rig")
  ci_verdict=$(printf '%s' "$ci_out" | cut -f1)
  ci_failed=$(printf '%s' "$ci_out" | cut -f2)
  case "$ci_verdict" in
    green)
      printf 'The integration branch CI PASSED on the combination itself.\n' >> "$TMP/notes"
      ;;
    red)
      combination=ci-red
      printf 'The integration branch CI FAILED on the combination: %s\n' \
        "$(printf '%s' "$ci_failed" | sanitize_ref_tokens)" >> "$TMP/notes"
      # ATTRIBUTION. Naming the failing CHECK says the bundle broke; it does
      # not say who broke it, and this is the path where that matters most —
      # CI is the run's real measurement, so the combination defects that
      # only it can see would otherwise be the only ones reported with no
      # suspect at all. Done here, while the scratch worktree still exists:
      # every constituent's changed-file set is computed from it, and it is
      # removed once the re-bundle loop is done with it.
      #
      # The scratch directory is cleared first. attribute_ci_failure returns
      # early on a log it cannot read, so a second attempt that fetched no log
      # would otherwise inherit the FIRST attempt's implicated set and eject
      # somebody on evidence about a bundle that no longer exists.
      rm -rf "$TMP/attr"
      ci_failure_log "$slug" "$pr_url" > "$TMP/ci.log" 2>/dev/null
      attr_now=$(attribute_ci_failure "$WT" "$base_sha" \
        "$TMP/candidates" "$TMP/ci.log" "$TMP/attr" 2>/dev/null \
        | sanitize_ref_tokens)
      # ACCUMULATED, not overwritten. A run that re-bundles has two failures to
      # account for, and the FIRST is the one that names the pair — replacing it
      # with the second would drop the reason a constituent was ejected at all.
      if [ -n "$attr_now" ]; then
        ci_attribution="${ci_attribution:+$ci_attribution
}$attr_now"
      fi
      # The attribution goes in the mail's LEAD, not down here: it is the
      # headline fact of this run, and repeating it in the notes would only
      # dilute it. What lands in the notes is the evidence behind it.
      if [ -s "$TMP/ci.log" ]; then
        printf 'What broke (from the failing job'\''s log):\n%s\n' \
          "$(tail -n 25 "$TMP/ci.log" | sanitize_ref_tokens)" >> "$TMP/notes"
      fi
      ;;
    pending)
      combination=ci-pending
      printf 'The integration branch CI had not finished after %s poll(s); the combination is UNMEASURED.\n' \
        "$INTEGRATION_LANE_CI_POLLS" >> "$TMP/notes"
      ;;
    *)
      combination=ci-absent
      printf 'No CI check ever appeared on %s; the combination is UNMEASURED.\n' \
        "$branch" >> "$TMP/notes"
      ;;
  esac
  notes_txt=$(cat "$TMP/notes" 2>/dev/null)
}

# A CI failure ejects ONE constituent and the remainder is re-bundled, so the
# pull request that broke the combination delays itself instead of the set.
#
# Returns 0 when a re-bundle is set up (the caller loops round again) and 1 when
# the run is finished. Every 1 is a decision worth reading, so each one says why.
#
# EXACTLY ONE, and the newest of the implicated. The implicated set is an
# interacting PAIR — that is what attribution means here — and breaking the pair
# needs only one of them gone, so ejecting both would delay two pull requests to
# fix one interaction. The newest is the one the others were fine without.
#
# NOBODY is ejected on no evidence. attribute_ci_failure declines to name a
# suspect it cannot tie to a file, and that restraint has to survive into the
# action: a re-bundle that drops an innocent constituent is worse than the red
# bundle it replaces, because it looks like progress.
eject_after_ci_failure() {
  [ "$combination" = ci-red ] || return 1

  if [ "$ci_rebundles" -ge "$INTEGRATION_LANE_CI_REBUNDLES" ]; then
    [ "$INTEGRATION_LANE_CI_REBUNDLES" -gt 0 ] && printf \
      'A second CI failure is not re-bundled again (INTEGRATION_LANE_CI_REBUNDLES=%s): either the first attribution was wrong or this queue holds two independent combination defects, and both are worth a person reading.\n' \
      "$INTEGRATION_LANE_CI_REBUNDLES" >> "$TMP/notes"
    return 1
  fi

  if [ ! -s "$TMP/attr/implicated" ]; then
    printf 'Nothing was ejected: the failing job'\''s log names no file any constituent changed, so there is no evidence to eject anyone on. The bundle stays as it is.\n' \
      >> "$TMP/notes"
    return 1
  fi

  eject_num=$(sort -n "$TMP/attr/implicated" 2>/dev/null | tail -n1)
  [ -n "$eject_num" ] || return 1
  eject_title=$(awk -F'\t' -v n="$eject_num" '$1==n {print $4; exit}' "$TMP/candidates")

  awk -F'\t' -v n="$eject_num" '$1!=n' "$TMP/candidates" > "$TMP/remainder"
  n_rest=$(wc -l < "$TMP/remainder" 2>/dev/null | tr -d ' ')
  [ -n "$n_rest" ] || n_rest=0
  if [ "$n_rest" -lt 2 ]; then
    printf 'Ejecting #%s would leave %s constituent(s), which is not a combination to test. The bundle stays as it is.\n' \
      "$eject_num" "$n_rest" >> "$TMP/notes"
    rm -f "$TMP/remainder"
    return 1
  fi

  mv "$TMP/remainder" "$TMP/candidates"
  exclude "$eject_num" "$eject_title" \
    "ejected after the bundle's CI failed on the combination, and the remaining $n_rest were re-bundled without it"
  rebundle_note="#$eject_num was ejected after the previous bundle's CI failed on the
combination and the failure was attributed to it. The remaining $n_rest constituents
are bundled here. #$eject_num is not judged wrong — it is the half of the interacting
pair that this bundle can ship without, and it keeps its own pull request."
  printf 'Ejected #%s after the integration branch CI failed, and re-bundled the remaining %s so one pull request delays itself rather than the whole set.\n' \
    "$eject_num" "$n_rest" >> "$TMP/notes"

  # The red bundle is closed once its replacement exists, not before: a
  # replacement that fails to open would otherwise leave the run with no bundle
  # at all and the evidence closed behind it.
  superseded_url="$pr_url"
  ci_rebundles=$((ci_rebundles + 1))
  branch="$branch_stem-r$ci_rebundles"
  combination=unknown
  return 0
}

# ---------------------------------------------------------------------------
# Per-rig run
# ---------------------------------------------------------------------------

stamp=$(date -u +%Y%m%d-%H%M%S)

rigs=$(gc rig list --json 2>/dev/null \
  | jq -r '(if type=="array" then . else (.rigs // []) end)[] | .name' 2>/dev/null)
[ -n "${INTEGRATION_LANE_RIGS:-}" ] && rigs="$INTEGRATION_LANE_RIGS"

for rig in $rigs; do
  rig_root="$(sy_city)/$rig"
  [ -d "$rig_root/.git" ] || continue

  default_branch=$(gc rig list --json 2>/dev/null | jq -r --arg r "$rig" '
    (if type=="array" then . else (.rigs // []) end)[]
    | select(.name==$r) | (.default_branch // "main")' 2>/dev/null)
  [ -n "$default_branch" ] || default_branch=main

  # owner/repo straight off the rig's own remote.
  slug=$(git -C "$rig_root" remote get-url origin 2>/dev/null \
    | sed -e 's#^git@github.com:##' -e 's#^https://github.com/##' -e 's#\.git$##')
  case "$slug" in
    */*) : ;;
    *)   continue ;;   # not a GitHub remote; nothing this lane can bundle
  esac

  lane_lock "$rig" || continue

  # Accumulate through FILES, not shell variables. The candidate rows are read in
  # a `while read` loop; feeding that from a pipe puts it in a SUBSHELL where
  # every assignment is discarded on exit — the loop would find a bundle, build
  # nothing, and exit 0. That is a dead check that looks healthy, which is the
  # failure class this pack exists to catch.
  TMP=$(mktemp -d 2>/dev/null) || { lane_unlock "$rig"; continue; }
  : > "$TMP/candidates"
  : > "$TMP/excluded"
  : > "$TMP/constituents"
  : > "$TMP/notes"

  # -------------------------------------------------------------------------
  # 1. Collect candidates
  # -------------------------------------------------------------------------
  rows=$(gh pr list --repo "$slug" --state open --base "$default_branch" \
           --limit 100 \
           --json number,title,headRefName,headRefOid,isDraft,reviewDecision,statusCheckRollup \
           2>/dev/null)
  if [ -z "$rows" ]; then
    # A gh that is missing, unauthenticated or rate-limited makes this order a
    # dead check that looks healthy. Say so rather than reporting a quiet run.
    printf 'gh returned nothing for %s — the lane could not read the queue.\n' "$slug" \
      >> "$TMP/notes"
    gc mail send mayor \
      -s "integration-lane: cannot query GitHub for $slug — this lane is not running" \
      -m "\`gh pr list --repo $slug\` returned nothing. Until this is fixed the lane
cannot tell a full merge queue from an empty one and will report nothing, which
is indistinguishable from a healthy queue.

  gh auth status
  gh api rate_limit --jq '.rate'" >/dev/null 2>&1
    rm -rf "$TMP"; lane_unlock "$rig"; continue
  fi

  # -------------------------------------------------------------------------
  # 1b. Refuse to build a bundle this repository cannot merge correctly
  # -------------------------------------------------------------------------
  # Every constituent auto-closes because its own head commit becomes REACHABLE
  # from the base when the bundle merges — which is the entire reason step 3
  # merges with --no-ff. That reachability survives a merge commit and nothing
  # else: squash and rebase both rewrite those commits away, so the bundle would
  # land and leave every constituent OPEN with its code already shipped, each
  # looking unmerged and each needing to be closed by hand.
  #
  # If the repository does not offer the merge-commit button, "MERGE THIS WITH A
  # MERGE COMMIT" in the body is an instruction nobody can follow and the only
  # button on offer is the one that breaks the mechanism. So this is checked
  # BEFORE the branch is pushed: a bundle nobody can merge correctly is worse
  # than no bundle, and discovering it afterwards has already littered origin.
  #
  # Fail CLOSED when the setting cannot be read, matching the empty check rollup
  # and the empty `gh pr list` above. "Cannot confirm" is not "allowed", and
  # this repository has already been burned by rounding an unknown up to
  # success — PR #1346 read green on ZERO checks.
  merge_cfg=$(gh repo view "$slug" --json mergeCommitAllowed,squashMergeAllowed 2>/dev/null)
  # `| tostring`, NOT `// empty`. jq's alternative operator falls through on
  # `false` exactly as it does on `null`, so `.mergeCommitAllowed // empty` reads
  # an explicitly DISABLED button as an unreadable one. Both refuse, so the
  # lane stayed safe — but the mayor got told the setting could not be read when
  # it had been read perfectly and said no. tostring keeps the three states
  # apart: "true", "false", "null"; and an empty result means gh itself
  # produced nothing.
  merge_commit_ok=$(printf '%s' "$merge_cfg" | jq -r '.mergeCommitAllowed | tostring' 2>/dev/null)
  squash_ok=$(printf '%s' "$merge_cfg" | jq -r '.squashMergeAllowed | tostring' 2>/dev/null)
  # The warning is tailored to what the settings actually said: the reader was
  # just read, so the body must not offer a squash button on a repository where
  # it does not exist.
  if [ "$squash_ok" = true ]; then
    squash_note="This repository allows squash merging, so the wrong button is right there."
  else
    squash_note="Squash merging is disabled here, so the button you are offered is already the right one."
  fi
  if [ "$merge_commit_ok" != true ]; then
    if [ "$merge_commit_ok" != false ]; then
      why="could not be read"
      detail="\`gh repo view $slug --json mergeCommitAllowed\` returned nothing, so the lane
could not confirm that the merge-commit button exists."
    else
      why="are disabled"
      detail="\`mergeCommitAllowed\` is false on $slug."
    fi
    gc mail send mayor \
      -s "integration-lane: $rig is not bundling — merge commits $why" \
      -m "$detail

A bundle is only worth handing over if it can be merged WITH A MERGE COMMIT.
Each constituent pull request auto-closes because its own head commit becomes
reachable from \`$default_branch\` when the bundle merges; squash and rebase
rewrite those commits away, so the bundle would land and leave every
constituent OPEN with its code already shipped.

This run therefore built no bundle, rather than handing you one whose only
merge button is the wrong one. To enable the lane:

  gh api -X PATCH repos/$slug -f allow_merge_commit=true

  (Settings -> General -> Pull Requests -> Allow merge commits)" >/dev/null 2>&1
    rm -rf "$TMP"; lane_unlock "$rig"; continue
  fi

  printf '%s' "$rows" | jq -r '
    .[]
    | [ (.number|tostring),
        (.headRefName // ""),
        (.headRefOid // ""),
        (.isDraft|tostring),
        (.reviewDecision // ""),
        ((.statusCheckRollup // []) | length | tostring),
        ((.statusCheckRollup // [])
          | map(select(
              (.conclusion // "") == "FAILURE" or (.conclusion // "") == "CANCELLED"
              or (.conclusion // "") == "TIMED_OUT" or (.conclusion // "") == "ACTION_REQUIRED"
              or (.conclusion // "") == "STARTUP_FAILURE"
              or (.state // "") == "FAILURE" or (.state // "") == "ERROR"))
          | length | tostring),
        ((.statusCheckRollup // [])
          | map(select(
              (((.status // "") != "") and ((.status // "") != "COMPLETED"))
              or (.state // "") == "PENDING"))
          | length | tostring),
        (.title // "")
      ] | @tsv' 2>/dev/null > "$TMP/rows"

  while IFS="$(printf '\t')" read -r num head oid draft review nchecks nfailed npending title; do
    [ -n "${num:-}" ] || continue

    # Never bundle a previous bundle. An integration branch is not a
    # constituent, and a lane that ate its own output would compound bundles.
    case "$head" in
      integration/*) continue ;;
    esac

    if [ "$draft" = "true" ]; then
      exclude "$num" "$title" "draft"; continue
    fi

    # `reviewDecision` is a LATCH: it stays CHANGES_REQUESTED even after the
    # author pushes a fix, and it stays that way on a PR that has since merged.
    # So it is used only to REFUSE, never to require — requiring APPROVED would
    # exclude the large share of PRs here that carry no review at all, and
    # whether a PR deserves to merge on its own merits is a human and judge-lane
    # question this lane does not answer. It only asks whether the SET is safe.
    if [ "$review" = "CHANGES_REQUESTED" ]; then
      exclude "$num" "$title" "review is CHANGES_REQUESTED"; continue
    fi
    if [ "$INTEGRATION_LANE_REQUIRE_APPROVAL" = "1" ] && [ "$review" != "APPROVED" ]; then
      exclude "$num" "$title" "no approving review (INTEGRATION_LANE_REQUIRE_APPROVAL=1)"; continue
    fi

    # ZERO checks is not success. PR #1346 read green on zero GHA checks; a lane
    # that rounds an empty rollup up to "green" bundles untested code and reports
    # a verified combination.
    if [ "${nchecks:-0}" = "0" ]; then
      exclude "$num" "$title" "no CI checks reported (an empty rollup is not green)"; continue
    fi
    if [ "${nfailed:-0}" != "0" ]; then
      exclude "$num" "$title" "$nfailed failing check(s)"; continue
    fi
    if [ "${npending:-0}" != "0" ]; then
      exclude "$num" "$title" "$npending check(s) still running"; continue
    fi

    # Mergeability LAST: it is the expensive read, so everything cheap has
    # already filtered. Re-queried, never a single lazily-computed read.
    mm=$(requery_mergeable "$slug" "$num")
    mergeable=$(printf '%s' "$mm" | cut -f1)
    mstate=$(printf '%s' "$mm" | cut -f2)
    if [ "$mergeable" != "MERGEABLE" ]; then
      exclude "$num" "$title" "not mergeable after $INTEGRATION_LANE_MERGE_POLLS re-queries (mergeable=$mergeable mergeStateStatus=$mstate)"
      continue
    fi
    case "$mstate" in
      CLEAN|HAS_HOOKS|UNSTABLE) : ;;
      BLOCKED)
        exclude "$num" "$title" "mergeStateStatus=BLOCKED (a required gate has not passed)"; continue ;;
      *)
        exclude "$num" "$title" "mergeStateStatus=$mstate"; continue ;;
    esac

    printf '%s\t%s\t%s\t%s\n' "$num" "$oid" "$head" "$title" >> "$TMP/candidates"
  done < "$TMP/rows"

  n_candidates=$(wc -l < "$TMP/candidates" 2>/dev/null | tr -d ' ')
  [ -n "$n_candidates" ] || n_candidates=0

  # -------------------------------------------------------------------------
  # 2. Nothing to add? Be silent.
  # -------------------------------------------------------------------------
  # Fewer than two mergeable PRs means there is no COMBINATION to test, and this
  # lane's whole value is the combination. Bundling one PR would create a branch
  # and a mail that tell a human nothing their existing PR did not already say.
  # No branch, no pull request, no mail.
  if [ "$n_candidates" -lt 2 ]; then
    rm -rf "$TMP"; lane_unlock "$rig"; continue
  fi

  # -------------------------------------------------------------------------
  # 3. Apply the bundle size, naming the overflow
  # -------------------------------------------------------------------------
  # Truncation is reported, never silent: an excluded PR that nobody names is
  # left behind while the run reports success.
  #
  # OLDEST FIRST. `gh pr list` returns newest-first, so capping that order starves
  # the oldest pull requests: with a queue durably above the cap they are excluded
  # EVERY run under the message "next run picks it up", which would be a lie — the
  # next run makes the same cut. Sorting ascending by number makes the oldest the
  # ones that get in, so the queue actually drains and the message is true.
  sort -n -k1,1 "$TMP/candidates" > "$TMP/candidates.sorted" 2>/dev/null \
    && mv "$TMP/candidates.sorted" "$TMP/candidates"
  if [ "$n_candidates" -gt "$INTEGRATION_LANE_BUNDLE_SIZE" ]; then
    tail -n +"$((INTEGRATION_LANE_BUNDLE_SIZE + 1))" "$TMP/candidates" \
    | while IFS="$(printf '\t')" read -r num oid head title; do
        [ -n "${num:-}" ] || continue
        exclude "$num" "$title" "queue exceeds the bundle size in use ($INTEGRATION_LANE_BUNDLE_SIZE); next run picks it up"
      done
    head -n "$INTEGRATION_LANE_BUNDLE_SIZE" "$TMP/candidates" > "$TMP/candidates.capped"
    mv "$TMP/candidates.capped" "$TMP/candidates"
  fi

  # -------------------------------------------------------------------------
  # 4. Scratch worktree off the freshly fetched default branch
  # -------------------------------------------------------------------------
  WT="$TMP/wt"
  git -C "$rig_root" fetch --quiet origin "$default_branch" >/dev/null 2>&1
  if ! git -C "$rig_root" worktree add --detach --quiet "$WT" "origin/$default_branch" >/dev/null 2>&1; then
    printf 'could not create a scratch worktree from %s\n' "$rig_root" >> "$TMP/notes"
    rm -rf "$TMP"; lane_unlock "$rig"; continue
  fi

  base_sha=$(git -C "$WT" rev-parse HEAD 2>/dev/null)
  base_schema=$(schema_version_at "$WT" HEAD)

  # Fetch every constituent head into the worktree by SHA, so the merge below
  # combines exactly the commits the candidate read measured — not whatever the
  # branch has moved to since.
  while IFS="$(printf '\t')" read -r num oid head title; do
    [ -n "${oid:-}" ] || continue
    git -C "$WT" cat-file -e "$oid^{commit}" 2>/dev/null && continue
    git -C "$WT" fetch --quiet origin "$oid" >/dev/null 2>&1 \
      || git -C "$WT" fetch --quiet origin "pull/$num/head" >/dev/null 2>&1
  done < "$TMP/candidates"

  # -------------------------------------------------------------------------
  # 5. schemaVersion collision — BEFORE the combination is tested
  # -------------------------------------------------------------------------
  # Two PRs claiming one schemaVersion is a collision this repo has already hit
  # (#1464 vs #1477, found inside bundle #1490). It merges perfectly cleanly and
  # then silently skips a migration in production, so it is worth naming as a
  # collision rather than discovering as a mysterious build or runtime failure.
  # Checked before the merge loop: a run must never spend a full verify cycle to
  # rediscover something a `git show` can answer.
  #
  # A PR CLAIMS A VERSION ONLY IF IT CHANGED ONE, MEASURED AGAINST ITS OWN
  # MERGE-BASE — never against the base TIP.
  #
  # Comparing the head to the base tip asks "does this branch differ from main
  # today?", which is true of every branch cut before main's last bump even when
  # it has not touched dolt.go at all. Measured against the live queue on
  # 2026-08-11 with main at 202: #1511 and #1504 read 198, #1484 and #1476 read
  # 196, and all four have head == merge-base and touch dolt.go zero times. The
  # tip comparison called every one of them a bump, then ejected two of them as
  # "colliding" on a version neither had claimed — 7 of 10 open PRs excluded for
  # a bump that never happened, collapsing the bundle to one.
  #
  # And the same comparison was blind in the opposite direction. When a PR bumps
  # to EXACTLY the value the base already stamps, head == base tip, so the old
  # predicate skipped it as "no bump" — the one case that matters most. Git
  # merges the identical line without a conflict and the migration is silently
  # skipped, because `migrate()` short-circuits on `ver >= schemaVersion`; that
  # is the outage class scripts/check-schema-version-bump.sh documents. A bump
  # must be STRICTLY ABOVE what the target branch stamps, so that is what is
  # enforced here rather than mere difference.
  : > "$TMP/claimed"
  : > "$TMP/keep"
  while IFS="$(printf '\t')" read -r num oid head title; do
    [ -n "${num:-}" ] || continue

    # A head we could not fetch cannot be merged OR schema-checked. Say that,
    # rather than letting the merge below fail and be reported as a conflict
    # with the bundle — a wrong reason that blames the other constituents.
    if ! git -C "$WT" cat-file -e "$oid^{commit}" 2>/dev/null; then
      exclude "$num" "$title" "could not fetch its head commit $oid from origin — not schema-checked and not merged"
      continue
    fi

    mb=$(git -C "$WT" merge-base "$base_sha" "$oid" 2>/dev/null)
    sv_head=$(schema_version_at "$WT" "$oid")
    sv_mb=""
    [ -n "$mb" ] && sv_mb=$(schema_version_at "$WT" "$mb")

    if [ -n "$sv_head" ] && [ -n "$sv_mb" ] && [ "$sv_head" != "$sv_mb" ]; then
      # This PR genuinely moves schemaVersion. Two ways that can be wrong.
      if [ -n "$base_schema" ] && [ "$sv_head" -le "$base_schema" ]; then
        exclude "$num" "$title" "schemaVersion $sv_head is not above $default_branch, which already stamps $base_schema — an equal bump merges cleanly and then skips its own migration"
        printf 'schemaVersion: #%s bumps %s -> %s, but %s already stamps %s. Equal or lower is the `ver >= schemaVersion` short-circuit outage, so it was ejected before the combination was tested.\n' \
          "$num" "$sv_mb" "$sv_head" "$default_branch" "$base_schema" >> "$TMP/notes"
        continue
      fi
      # awk, not `grep "^$sv<tab>"`: a tab inside a shell string is invisible and
      # survives exactly as long as nothing reformats this file.
      prior_num=$(awk -F'\t' -v v="$sv_head" '$1==v {print $2; exit}' "$TMP/claimed" 2>/dev/null)
      if [ -n "$prior_num" ]; then
        exclude "$num" "$title" "schemaVersion collision: both this and #$prior_num bump to $sv_head (base $default_branch stamps $base_schema)"
        printf 'schemaVersion %s is claimed by BOTH #%s and #%s — #%s was ejected before the combination was tested.\n' \
          "$sv_head" "$prior_num" "$num" "$num" >> "$TMP/notes"
        continue
      fi
      printf '%s\t%s\n' "$sv_head" "$num" >> "$TMP/claimed"
    fi
    printf '%s\t%s\t%s\t%s\n' "$num" "$oid" "$head" "$title" >> "$TMP/keep"
  done < "$TMP/candidates"
  mv "$TMP/keep" "$TMP/candidates"

  # -------------------------------------------------------------------------
  # 6. Combine, verify, publish — and eject rather than stalling the set
  # -------------------------------------------------------------------------
  # ONE loop, because a CI failure is not the end of a run. Each pass combines
  # the candidates, tests the combination, publishes the bundle and reads that
  # bundle's OWN CI; then it asks whether a constituent should be ejected and the
  # remainder re-bundled. A verdict needing no ejection leaves on the first pass,
  # so the common case is exactly what it was before this loop existed.
  branch_stem="integration/$stamp"
  branch="$branch_stem"
  ejections=0
  ci_rebundles=0
  verify_log="$TMP/verify.log"
  combination=unknown
  # Per-rig, not per-run: without this reset the second rig in a city would
  # inherit the first rig's attribution and blame its pull requests.
  ci_attribution=""
  # Per-rig, like ci_attribution: whether THIS rig's run actually consulted the
  # bundle CI. The green mail's wording branches on it, and inheriting the
  # previous rig's value would let a POLLS=0 run claim a verification it never
  # made.
  ci_checked=""
  rebundle_note=""
  superseded_url=""
  pr_url=""

  while : ; do
    combine_and_verify
    report_text
    publish_bundle
    eject_after_ci_failure || break
  done

  # -------------------------------------------------------------------------
  # 7. Report — and hand the decision to a human
  # -------------------------------------------------------------------------
  # Re-derived after the loop: a re-bundle grew the exclusion ledger and shrank
  # the constituent list, and the mail must describe the bundle that SHIPPED.
  report_text

  git -C "$rig_root" worktree remove --force "$WT" >/dev/null 2>&1
  git -C "$rig_root" worktree prune >/dev/null 2>&1

  # A run with nothing to say says nothing. But "nothing to say" is narrow: it
  # means no bundle AND nothing excluded. An exclusion is always worth a mail —
  # an excluded PR nobody names is the silent-truncation failure.
  if [ "$combination" = abandoned ] && [ -z "$excluded_txt" ]; then
    rm -rf "$TMP"; lane_unlock "$rig"; continue
  fi

  case "$combination" in
    green)
      subject="integration-lane: $rig bundle of $n_final is green — one merge is waiting for you"
      # The CI claim is earned, never assumed: a POLLS=0 run skips the bundle-CI
      # wait entirely, and a green mail that still said "green on the branch's
      # own CI" would be the exact false-green this layer exists to end. Say
      # what was measured, and only that.
      if [ -n "$ci_checked" ]; then
        lead="The combination is GREEN — and green on the integration branch's own CI, not
just on the lane's pre-flight. $n_final pull requests were merged onto one branch
and the repository's checks ran against that merge result; nothing else in this
repository measures the combination."
      else
        lead="The combination BUILDS — on the lane's pre-flight only. $n_final pull requests
were merged onto one branch and verified together, but INTEGRATION_LANE_CI_POLLS=0
skipped the integration branch's own CI, so that stronger check has NOT run."
      fi
      lead="$lead

  $pr_url

Merge it with a MERGE COMMIT, not a squash. Each constituent auto-closes on
reachability, and a squash destroys that — the bundle would land and leave every
constituent open with its code already on main.

The lane does not merge. That gate is yours and stays yours."
      ;;
    red)
      subject="integration-lane: $rig — a combination failure survived $ejections ejection(s)"
      lead="These pull requests are each green alone and BROKEN TOGETHER. The lane ejected
its prime suspect $ejections time(s) and the remainder still fails, so it did not
open a bundle. No branch was pushed.

This is the defect class the lane exists to catch: it would have reached main,
and Railway auto-deploys main."
      ;;
    ci-red)
      subject="integration-lane: $rig — the integration branch's CI FAILED on the combination; do NOT merge"
      lead="These $n_final pull requests build together and then FAIL CI TOGETHER. The bundle
was opened, its checks ran against the merge result, and they came back red:

  $pr_url

This is the defect class the lane exists to catch, and it is the half the local
pre-flight cannot see: that pre-flight is \`$INTEGRATION_LANE_VERIFY\`, while CI
also runs the test suite. Each constituent is green on its own base; the
combination is not.
${ci_attribution:+
$ci_attribution}
Do NOT merge this bundle. Read the failing checks on it, and either fix the
interaction or close the bundle and let the next run rebuild without the
culprit. The pull request is left OPEN on purpose — it is the evidence, and its
failing checks carry the full detail."
      ;;
    ci-pending)
      subject="integration-lane: $rig bundle is UNMEASURED — its CI had not finished"
      lead="The bundle was opened and its CI had not reported a verdict before the lane's
wait ran out, so the combination is UNMEASURED:

  $pr_url

Treat this as \"not yet known\", never as green. The checks are still the
answer — read them on the pull request before merging. If this repeats, CI is
slower than INTEGRATION_LANE_CI_POLLS × INTEGRATION_LANE_CI_POLL_SLEEP
(currently $INTEGRATION_LANE_CI_POLLS × ${INTEGRATION_LANE_CI_POLL_SLEEP}s) and that budget is the thing to raise."
      ;;
    ci-absent)
      subject="integration-lane: $rig bundle has NO CI checks — the combination was never measured"
      lead="The bundle was opened and no CI check ever appeared on it:

  $pr_url

An empty check rollup is NOT a pass. PR #1346 read green on zero checks, and on
this branch that mistake would be the worst one available — measuring the
combination is the only reason this lane exists, so a bundle nothing ran against
has no verdict at all.

Check that the workflow triggers cover this branch (\`on: pull_request:\` must
name \`$default_branch\`), then read the checks yourself before merging."
      ;;
    unpreparable)
      subject="integration-lane: $rig — THE LANE could not prepare a buildable tree (not a combination failure)"
      lead="This is a fault in the LANE, not in any pull request. Preparation of the scratch
worktree failed before the combination was ever tested, so NOTHING here is
evidence about the constituents and nothing was ejected or blamed.

No branch was pushed and no bundle was opened. Read this as \"the lane is not
running\", not as \"the queue is broken\".

Preparation is INTEGRATION_LANE_PREPARE (currently: $INTEGRATION_LANE_PREPARE).
On this repo the default generates templ views at the go.mod-pinned version,
because *_templ.go is gitignored and a fresh worktree cannot build without it.

$(tail -n 25 "$TMP/prepare.log" 2>/dev/null | sanitize_ref_tokens)"
      ;;
    create-failed)
      subject="integration-lane: $rig combination green but opening the bundle PR FAILED"
      lead="The combination passed and \`gh pr create\` then failed, so there is NO pull
request to review — do not go looking for one. The notes below say whether the
pushed branch was cleaned up or is orphaned on origin.

Nothing is lost: the next run rebuilds the bundle from scratch."
      ;;
    push-failed)
      subject="integration-lane: $rig bundle verified green but could not be pushed"
      lead="The combination passed and then the push failed, so no pull request exists.
Nothing is lost — the next run rebuilds the bundle from scratch — but if this
repeats, the lane's push credentials are the thing to check."
      ;;
    *)
      subject="integration-lane: $rig — nothing bundled, $(printf '%s' "$excluded_txt" | grep -c 'excluded:') PR(s) excluded"
      lead="No bundle was opened: fewer than two pull requests survived the filters. Every
pull request the lane declined is named below with its reason, so nothing is
silently left behind."
      ;;
  esac

  # An ejection a human cannot trace back to its evidence is indistinguishable
  # from a pull request that quietly went missing. On the ci-red path the
  # attribution IS the lead, so it is already said; on every other path — above
  # all a run that ejected somebody and then went GREEN, where the headline is
  # rightly the merge that is waiting — it would otherwise be dropped along with
  # the only account of why the bundle is one smaller than the queue.
  attribution_section=""
  if [ -n "$ci_attribution" ] && [ "$combination" != ci-red ]; then
    attribution_section="What the CI failure was attributed to:
$ci_attribution"
  fi

  gc mail send mayor -s "$subject" -m "$lead
${attribution_section:+
$attribution_section}
Bundle size in use: $INTEGRATION_LANE_BUNDLE_SIZE (INTEGRATION_LANE_BUNDLE_SIZE)
Candidates that passed the filters: $n_candidates
Combination verify: $INTEGRATION_LANE_VERIFY
${constituents:+
Constituents ($n_final):
$constituents}
${excluded_txt:+
Excluded, and why:
$excluded_txt}
${notes_txt:+
Notes:
$notes_txt}
This lane never merges. It prepares a bundle and reports; the merge is a human
decision. See packs/README.md for the full behaviour." >/dev/null 2>&1

  rm -rf "$TMP"
  lane_unlock "$rig"
done

exit 0
