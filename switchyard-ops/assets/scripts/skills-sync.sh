#!/bin/sh
# skills-sync: keep each opted-in rig's org skills current, headlessly.
#
# THE LOOP THIS CLOSES (switchyard PRD #375, crit:1f1d1c093760). A workspace
# registers the company's skill repos once; switchyard discovers what they
# publish and serves every project the same effective manifest, pinned by the
# sha that last touched each skill. This order is the LOCAL half: per rig, it
#
#   1. reads the sink's two ownership manifests — gc's .gc-skill-ownership.json
#      (what gc materialized; never ours to touch) and this order's own
#      .switchyard-skill-ownership.json (what THIS loop installed, at which sha);
#   2. calls the switchyard MCP's list_skills with that installed id→sha map,
#      so the verdicts come back graded by the one grader that owns the rule;
#   3. installs or updates every skill whose verdict is DETERMINED and
#      outdated, straight from the skill repo's git source at the manifest sha;
#   4. never writes a name gc owns.
#
# VERDICTS ARE READ determined-FIRST, and that is the contract list_skills
# documents: outdated=false means "current" only when determined=true, because
# "could not tell" reports outdated=false too. So the only rows this loop acts
# on are determined && outdated (reason not_installed or sha_mismatch); every
# undetermined row is logged with its reason and left exactly as it is, and a
# manifest with discovery_available=false installs NOTHING — the registry was
# not read, so its empty list proves no skill absent.
#
# NEVER TOUCH A gc-OWNED NAME. gc materializes skills into the same sink as
# symlinks and records them in .gc-skill-ownership.json; its cleanup pass
# prunes only symlinks it recorded and leaves regular directories alone. So an
# org skill lands as a REAL directory beside gc's symlinks, and a manifest
# skill whose local name is one gc recorded — or is any symlink, or is a
# directory this loop did not itself install — is a CONFLICT: reported, mailed,
# and skipped, never overwritten. gc's manifest is read and never written.
#
# PINNED BY SHA, FROM GIT. The manifest carries each skill's clone_url,
# subpath and the repo-relative path of its SKILL.md; the install fetches
# exactly the manifest sha (a depth-1 fetch by sha, falling back to a plain
# fetch for a host that refuses sha-in-want), checks out the skill's directory
# from that commit, and swaps it into the sink atomically (stage beside, then
# rename). The sha recorded in the sidecar is the manifest's, so the next
# cycle's list_skills grades it current — a loop that recorded anything else
# would re-install every hour. A skill the manifest publishes with NO sha
# cannot be pinned and is not installed.
#
# ONE PROJECT'S EFFECTIVE MANIFEST governs the sink. A skill the project has
# switched off (disabled_skills) is removed IF this loop installed it; one gc
# owns is, as always, untouched. A skill this loop installed that the manifest
# no longer publishes at all is left in place and logged — a registry change
# is an owner's decision to review, not a reason to delete from every rig.
#
# OPT-IN PER RIG (SKILLS_SYNC_RIGS in roster.conf). This order writes into a
# rig checkout. That is authority an operator grants deliberately, so with the
# variable empty the order is a logged no-op — the same posture as the review
# and validate lanes.
#
# Escalation policy: every failed install and every ownership conflict is
# mailed to the mayor, at most once per 24h per rig (the loop's governing
# invariant, bounded so an hourly cadence does not train anyone to ignore it).
# A switchyard that cannot be reached is logged and NOT mailed: it is
# transient, every other order sees it too, and install-nothing is the safe
# outcome.
set -u

. "$(dirname "$0")/../lib/roster.sh"
. "$(dirname "$0")/../lib/switchyard-api.sh"
. "$(dirname "$0")/../lib/switchyard-mcp.sh"
sy_load_conf

# Rigs to sync, space-separated. Empty = off.
SKILLS_SYNC_RIGS="${SKILLS_SYNC_RIGS:-}"
# The sink, relative to each rig root: where gc materializes skills for Claude
# Code and where this loop installs beside them.
SKILLS_SYNC_SINK="${SKILLS_SYNC_SINK:-.claude/skills}"
# Per-fetch bound. A skill repo is small; a fetch that takes longer than this
# is a hung credential prompt or a dead host, not a large transfer.
SKILLS_SYNC_GIT_TIMEOUT="${SKILLS_SYNC_GIT_TIMEOUT:-120}"
# The page size asked of list_skills. Not a roster knob: it is the MCP's cap,
# named here so the self-test can shrink it to exercise a truncated answer.
SKILLS_SYNC_MANIFEST_LIMIT="${SKILLS_SYNC_MANIFEST_LIMIT:-500}"
case "$SKILLS_SYNC_MANIFEST_LIMIT" in ''|*[!0-9]*) SKILLS_SYNC_MANIFEST_LIMIT=500 ;; esac

GC_MANIFEST=".gc-skill-ownership.json"
SY_MANIFEST=".switchyard-skill-ownership.json"

log() { printf 'skills-sync: %s\n' "$*"; }

# skill_dir ID — the sink entry name for a namespaced "<repo>/<skill>" id.
# gc names its entries "<binding>.<skill>"; the same dotted shape keeps the
# sink one flat namespace and is a name Claude Code discovers.
skill_dir() { printf '%s.%s' "${1%%/*}" "${1#*/}"; }

# mail_once RIG SUBJECT BODY — mail the mayor, at most once per 24h per rig.
mail_once() {
  _mo_marker="$(sy_state_dir)/skills-sync.$1.alerted"
  if [ -f "$_mo_marker" ] && [ -z "$(find "$_mo_marker" -mmin +1440 2>/dev/null)" ]; then
    log "$1: mayor already alerted within 24h; not re-mailing"
    return 0
  fi
  mkdir -p "$(dirname "$_mo_marker")" 2>/dev/null
  gc mail send mayor -s "$2" -m "$3" >/dev/null 2>&1 && : >"$_mo_marker"
}

# sidecar_read SINK — the loop's own manifest as JSON, `{}`-shaped when absent
# or unreadable. A corrupt file reads as empty: every recorded skill is then
# graded not_installed and re-installed, which is a wasted fetch, never a
# wrong file.
sidecar_read() {
  _sr_json="$(jq -c 'if type == "object" then . else {} end' "$1/$SY_MANIFEST" 2>/dev/null)"
  [ -n "$_sr_json" ] || _sr_json='{}'
  printf '%s' "$_sr_json"
}

# sidecar_write SINK JSON — atomic (temp beside, then rename), mirroring how
# gc writes its own manifest. A torn sidecar would read as corrupt, see above.
sidecar_write() {
  _sw_tmp="$1/.$SY_MANIFEST.tmp.$$"
  printf '%s\n' "$2" | jq '.' >"$_sw_tmp" 2>/dev/null && mv -f "$_sw_tmp" "$1/$SY_MANIFEST"
}

# fetch_skill CLONE_URL SHA SKILL_PATH DEST — materialize the directory that
# declares SKILL_PATH, at exactly SHA, into DEST. rc 1 with a reason on stdout
# when it cannot.
#
# GIT_TERMINAL_PROMPT=0 is the whole difference between "a private repo this
# rig has no credential for fails in a second" and "the order hangs on a
# password prompt nobody will answer until sy_timeout kills it".
fetch_skill() {
  _fs_url="$1"; _fs_sha="$2"; _fs_path="$3"; _fs_dest="$4"
  _fs_dir="$(dirname "$_fs_path")"
  case "$_fs_dir" in ''|.|/|..|../*|/*) printf 'skill path %s does not name a directory inside the repo' "$_fs_path"; return 1 ;; esac
  _fs_tmp="$(mktemp -d "${TMPDIR:-/tmp}/sy-skill.XXXXXX" 2>/dev/null)" || { printf 'mktemp failed'; return 1; }
  export GIT_TERMINAL_PROMPT=0
  if ! git init -q "$_fs_tmp" 2>/dev/null || ! git -C "$_fs_tmp" remote add origin "$_fs_url" 2>/dev/null; then
    rm -rf "$_fs_tmp"; printf 'git init failed'; return 1
  fi
  if ! sy_timeout "$SKILLS_SYNC_GIT_TIMEOUT" git -C "$_fs_tmp" fetch -q --depth 1 origin "$_fs_sha" >/dev/null 2>&1; then
    # A host that refuses sha-in-want answers the shallow ask with an error;
    # a plain fetch of every branch then reaches any sha the default branch
    # reaches, which is where discovery read it from.
    if ! sy_timeout "$SKILLS_SYNC_GIT_TIMEOUT" git -C "$_fs_tmp" fetch -q origin >/dev/null 2>&1; then
      rm -rf "$_fs_tmp"; printf 'git fetch of %s failed (unreachable, unauthorized, or timed out)' "$_fs_url"; return 1
    fi
  fi
  if ! git -C "$_fs_tmp" cat-file -e "$_fs_sha^{commit}" 2>/dev/null; then
    rm -rf "$_fs_tmp"; printf 'commit %s is not reachable from %s' "$_fs_sha" "$_fs_url"; return 1
  fi
  if ! git -C "$_fs_tmp" checkout -q "$_fs_sha" -- "$_fs_dir" 2>/dev/null || [ ! -f "$_fs_tmp/$_fs_dir/SKILL.md" ]; then
    rm -rf "$_fs_tmp"; printf 'no %s at %s in %s' "$_fs_path" "$_fs_sha" "$_fs_url"; return 1
  fi
  rm -rf "$_fs_dest"
  if ! cp -R "$_fs_tmp/$_fs_dir" "$_fs_dest" 2>/dev/null; then
    rm -rf "$_fs_tmp" "$_fs_dest"; printf 'copy into the sink failed'; return 1
  fi
  rm -rf "$_fs_tmp"
  return 0
}

# sync_rig RIG — one rig's whole pass. Never exits; every outcome is a log
# line and, when it is a failure, a mail.
sync_rig() {
  _rig="$1"
  _root="$(sy_rig_root "$_rig")"
  if [ ! -d "$_root" ]; then log "$_rig: rig root $_root is missing — skipped"; return 0; fi
  _project="$(sy_project_for_rig "$_rig" "$PROJECTS")"
  if [ -z "$_project" ]; then
    log "$_rig: no switchyard project resolves for this rig (name it in RIG_PROJECTS) — skipped"
    return 0
  fi
  _tenant="${_project%%/*}"; _slug="${_project#*/}"
  _sink="$_root/$SKILLS_SYNC_SINK"
  mkdir -p "$_sink" 2>/dev/null || { log "$_rig: cannot create $_sink — skipped"; return 0; }

  # gc-owned names: every key gc's manifest records. A missing manifest is an
  # empty set, which is exactly what gc itself does with one.
  _gc_owned="$(jq -r '(.targets // {}) | keys[]' "$_sink/$GC_MANIFEST" 2>/dev/null)"

  # The installed map sent to list_skills: what this loop recorded, minus any
  # entry whose directory is gone (a hand-deleted skill must grade
  # not_installed, not current).
  _sidecar="$(sidecar_read "$_sink")"
  _installed='{}'
  for _id in $(printf '%s' "$_sidecar" | jq -r '(.skills // {}) | keys[]' 2>/dev/null); do
    _dir="$(printf '%s' "$_sidecar" | jq -r --arg id "$_id" '.skills[$id].dir // empty')"
    _sha="$(printf '%s' "$_sidecar" | jq -r --arg id "$_id" '.skills[$id].sha // empty')"
    if [ -n "$_dir" ] && [ -d "$_sink/$_dir" ] && [ ! -L "$_sink/$_dir" ]; then
      _installed="$(printf '%s' "$_installed" | jq -c --arg id "$_id" --arg sha "$_sha" '. + {($id): $sha}')"
    fi
  done

  # ASK FOR THE WHOLE MANIFEST. list_skills is a bounded list read: omitting
  # `limit` serves 50 rows and says so with truncated=true, which for an
  # interactive reader is a display bound and for this loop would be a silently
  # partial sync — the 51st org skill never installed anywhere. 500 is the
  # tool's own cap (cmd/switchyard-mcp/list_bounds.go), so this asks for the
  # most that can be served and treats a still-truncated answer as a failure
  # below rather than as the manifest.
  _args="$(jq -cn --arg t "$_tenant" --arg p "$_slug" --argjson i "$_installed" \
      --argjson n "$SKILLS_SYNC_MANIFEST_LIMIT" \
      '{tenant_slug: $t, project_slug: $p, installed: $i, limit: $n}')"
  _why_file="$(mktemp "${TMPDIR:-/tmp}/sy-skills-why.XXXXXX")"
  _manifest="$(sy_mcp_call list_skills "$_args" "$_why_file")"
  if [ -z "$_manifest" ]; then
    log "$_rig: list_skills for $_project answered nothing ($(cat "$_why_file" 2>/dev/null || printf unknown)) — installing nothing"
    rm -f "$_why_file"
    return 0
  fi
  rm -f "$_why_file"
  if [ "$(printf '%s' "$_manifest" | jq -r '.discovery_available // false' 2>/dev/null)" != true ]; then
    log "$_rig: $_project manifest has discovery_available=false — the registry was not read; installing nothing"
    return 0
  fi

  _n_installed=0; _n_updated=0; _n_current=0; _n_removed=0; _n_skipped=0
  _failures=""

  # A manifest that came back CUT is acted on for the rows it does carry — each
  # row's verdict is complete in itself — but it is not evidence about the rows
  # it does not. So the missing tail is mailed (a rig quietly carrying fewer org
  # skills than the workspace publishes is exactly the silence this pack's
  # governing invariant exists to break), and the "no longer published" report
  # below is suppressed: absence from a truncated list proves nothing.
  _cut=false
  if [ "$(printf '%s' "$_manifest" | jq -r '.truncated // false' 2>/dev/null)" = true ]; then
    _cut=true
    _failures="$_failures
- the $_project manifest came back truncated at $(printf '%s' "$_manifest" | jq -r '.limit // empty') of $(printf '%s' "$_manifest" | jq -r '.total // empty') rows; only the rows served were synced"
    log "$_rig: $_project manifest is truncated — syncing the rows served; the rest are NOT accounted for"
  fi
  _rows="$(mktemp "${TMPDIR:-/tmp}/sy-skills-rows.XXXXXX")"
  printf '%s' "$_manifest" | jq -c '.skills[]? | select(.id != null)' >"$_rows" 2>/dev/null

  while IFS= read -r _row; do
    _id="$(printf '%s' "$_row" | jq -r '.id')"
    _det="$(printf '%s' "$_row" | jq -r '.verdict.determined // false')"
    _out="$(printf '%s' "$_row" | jq -r '.verdict.outdated // false')"
    _why="$(printf '%s' "$_row" | jq -r '.verdict.reason // "no_verdict"')"
    if [ "$_det" != true ]; then
      log "$_rig: $_id: verdict undetermined ($_why) — left alone"
      _n_skipped=$((_n_skipped + 1)); continue
    fi
    if [ "$_out" != true ]; then
      _n_current=$((_n_current + 1)); continue
    fi

    _dir="$(skill_dir "$_id")"
    # The ownership gate, in the order that matters: gc's manifest first, then
    # any symlink (gc's shape, whether or not recorded), then a directory that
    # exists but is not ours. Only a name that is free, or that this loop
    # itself installed, is written.
    if printf '%s\n' "$_gc_owned" | grep -qxF "$_dir"; then
      _failures="$_failures
- $_id: sink entry '$_dir' is gc-owned (recorded in $GC_MANIFEST); left untouched"
      _n_skipped=$((_n_skipped + 1)); continue
    fi
    if [ -L "$_sink/$_dir" ]; then
      _failures="$_failures
- $_id: sink entry '$_dir' is a symlink not installed by this loop; left untouched"
      _n_skipped=$((_n_skipped + 1)); continue
    fi
    _ours="$(printf '%s' "$_sidecar" | jq -r --arg id "$_id" --arg d "$_dir" '(.skills[$id].dir // "") == $d')"
    if [ -e "$_sink/$_dir" ] && [ "$_ours" != true ]; then
      _failures="$_failures
- $_id: sink entry '$_dir' exists and was not installed by this loop; left untouched"
      _n_skipped=$((_n_skipped + 1)); continue
    fi

    _sha="$(printf '%s' "$_row" | jq -r '.sha // empty')"
    _url="$(printf '%s' "$_row" | jq -r '.source.clone_url // empty')"
    _path="$(printf '%s' "$_row" | jq -r '.source.path // empty')"
    if [ -z "$_sha" ] || [ -z "$_url" ] || [ -z "$_path" ]; then
      _failures="$_failures
- $_id: manifest carries no pinned sha/clone_url/path; cannot install from git"
      _n_skipped=$((_n_skipped + 1)); continue
    fi

    _stage="$_sink/.skills-sync.$_dir.stage"
    if ! _err="$(fetch_skill "$_url" "$_sha" "$_path" "$_stage")"; then
      rm -rf "$_stage"
      _failures="$_failures
- $_id ($_why): $_err"
      _n_skipped=$((_n_skipped + 1)); continue
    fi
    # Swap: the old copy steps aside, the stage takes its name, the old copy
    # goes. A crash between the two renames leaves a '.old' beside a live
    # skill, never a sink with the skill missing.
    _old="$_sink/.skills-sync.$_dir.old"
    rm -rf "$_old"
    [ -d "$_sink/$_dir" ] && mv "$_sink/$_dir" "$_old"
    if ! mv "$_stage" "$_sink/$_dir"; then
      [ -d "$_old" ] && mv "$_old" "$_sink/$_dir"
      rm -rf "$_stage"
      _failures="$_failures
- $_id: could not move the fetched skill into place"
      _n_skipped=$((_n_skipped + 1)); continue
    fi
    rm -rf "$_old"

    _now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _sidecar="$(printf '%s' "$_sidecar" | jq -c --arg id "$_id" --arg d "$_dir" --arg sha "$_sha" \
        --arg url "$_url" --arg path "$_path" --arg now "$_now" \
        '.version = 1 | .skills[$id] = {dir: $d, sha: $sha, clone_url: $url, path: $path, installed_at: $now}')"
    sidecar_write "$_sink" "$_sidecar"
    if [ "$_why" = sha_mismatch ]; then
      log "$_rig: $_id: updated to $(printf '%s' "$_sha" | cut -c1-7) in $_sink/$_dir"
      _n_updated=$((_n_updated + 1))
    else
      log "$_rig: $_id: installed at $(printf '%s' "$_sha" | cut -c1-7) into $_sink/$_dir"
      _n_installed=$((_n_installed + 1))
    fi
  done <"$_rows"
  rm -f "$_rows"

  # The project's overlay: a disabled skill THIS loop installed comes out.
  for _id in $(printf '%s' "$_manifest" | jq -r '.disabled_skills[]?' 2>/dev/null); do
    _dir="$(printf '%s' "$_sidecar" | jq -r --arg id "$_id" '.skills[$id].dir // empty')"
    [ -n "$_dir" ] || continue
    if printf '%s\n' "$_gc_owned" | grep -qxF "$_dir" || [ -L "$_sink/$_dir" ]; then continue; fi
    rm -rf "$_sink/$_dir"
    _sidecar="$(printf '%s' "$_sidecar" | jq -c --arg id "$_id" 'del(.skills[$id])')"
    sidecar_write "$_sink" "$_sidecar"
    log "$_rig: $_id: removed — disabled for $_project"
    _n_removed=$((_n_removed + 1))
  done

  # Installed here, no longer published anywhere: say so, do nothing. Skipped
  # entirely on a truncated manifest — see _cut above.
  for _id in $([ "$_cut" = true ] || printf '%s' "$_sidecar" | jq -r '(.skills // {}) | keys[]' 2>/dev/null); do
    if [ "$(printf '%s' "$_manifest" | jq -r --arg id "$_id" '[.skills[]?.id] | index($id) != null')" != true ] \
       && [ "$(printf '%s' "$_manifest" | jq -r --arg id "$_id" '[.disabled_skills[]?] | index($id) != null')" != true ]; then
      log "$_rig: $_id: no longer in the $_project manifest — left in place; remove by hand if unwanted"
    fi
  done

  log "$_rig: $_project — installed $_n_installed, updated $_n_updated, removed $_n_removed, current $_n_current, skipped $_n_skipped"
  if [ -n "$_failures" ]; then
    log "$_rig: problems:$_failures"
    mail_once "$_rig" "skills-sync: $_rig could not sync every org skill" "Rig $_rig (switchyard project $_project) — the following skills were NOT installed or updated this cycle:$_failures

Skills gc materialized are never touched by this loop; a conflict on one of those names means the org skill and a gc pack publish the same id — rename one. A failed fetch is a credential or reachability problem on this machine for that skill repo.

This mails at most once per 24h per rig; the order log has every cycle."
  fi
  return 0
}

if [ -z "$SKILLS_SYNC_RIGS" ]; then
  log "off — SKILLS_SYNC_RIGS is empty in roster.conf; nothing synced"
  exit 0
fi
for _tool in jq git; do
  command -v "$_tool" >/dev/null 2>&1 || { log "$_tool is not on PATH — cannot sync"; exit 0; }
done

TOKEN="$(sy_api_token)"
PROJECTS="$(sy_api_projects "$TOKEN")"
if [ -z "$PROJECTS" ]; then
  log "switchyard project list unreadable (no token, or $(sy_api_base) unreachable) — installing nothing this cycle"
  exit 0
fi

for _rig in $SKILLS_SYNC_RIGS; do
  sync_rig "$_rig"
done
exit 0
