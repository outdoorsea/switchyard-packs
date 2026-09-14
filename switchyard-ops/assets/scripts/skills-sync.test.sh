#!/usr/bin/env bash
#
# Self-test for packs/switchyard-ops/assets/scripts/skills-sync.sh — the
# headless org-skill sync loop (switchyard PRD #375, crit:1f1d1c093760).
#
# THE VERIFICATION CONTRACT
# -------------------------
#   "A skills-sync pack order drives the loop headlessly: reads the local
#    ownership manifest, calls list_skills with installed shas, installs or
#    updates stale org skills from their git source at the manifest sha, and
#    never touches gc-owned skill ids"
#
# Each clause is pinned in BOTH directions, because every "did nothing" case
# below would pass against a script that never does anything:
#
#   CALLS list_skills WITH INSTALLED SHAS. The stub MCP records the arguments
#   of every tools/call; the suite asserts the installed map is exactly what
#   the sidecar says is on disk — `{}` on a fresh sink, the old sha after an
#   install, and `{}` again when the directory was hand-deleted behind the
#   sidecar's back (a deleted skill must not grade current).
#
#   INSTALLS AND UPDATES FROM GIT AT THE MANIFEST SHA. The fixture repo has two
#   commits; the manifest pins the second. After a sync the sink holds the
#   second commit's SKILL.md and its sibling file, and the sidecar records the
#   manifest sha — so the NEXT pass grades it current and fetches nothing
#   (pinned by a sentinel file that survives inside the skill directory).
#
#   NEVER TOUCHES gc-OWNED IDS. Every case checks .gc-skill-ownership.json is
#   byte-identical afterwards and gc's symlink still points where it did. The
#   collision case has the manifest publish a skill whose sink name gc owns:
#   the symlink is untouched, nothing is recorded, the mayor is mailed.
#
#   determined FIRST. discovery_available=false and an undetermined verdict
#   both install nothing — an empty list from an unread registry is not
#   evidence, and neither is "could not tell".
#
#   A FAILED FETCH LEAVES NO TRACE: no directory, no stage, no sidecar entry;
#   a mail, once per 24h.
#
# Hermetic: a throwaway city, a local git repo standing in for the skill repo,
# and stubs for gc, curl and switchyard-mcp on PATH. No network, no real city.
# The stub MCP grades verdicts the way cmd/switchyard-mcp/skills_verdict.go
# does for the three determined outcomes, so the loop is exercised against the
# same contract it reads in production. Needs jq and git.
#
# CI runs this a second time under dash via SKILLS_TEST_SH — the same knob as
# the sibling suites (BALANCE_TEST_SH, REVIEW_TEST_SH, ...).
#
# Run:  bash packs/switchyard-ops/assets/scripts/skills-sync.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SYNC="$HERE/skills-sync.sh"
SKILLS_TEST_SH="${SKILLS_TEST_SH:-sh}"

for tool in jq git perl; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "SKIP — skills-sync self-test needs $tool (not on PATH)"
		exit 0
	fi
done

pass=0
fail=0

report() { # <ok|FAIL> <name> [detail]
	if [ "$1" = ok ]; then
		echo "ok   — $2"
		pass=$((pass + 1))
	else
		echo "FAIL — $2${3:+: $3}"
		fail=$((fail + 1))
	fi
}

# ---------------------------------------------------------------------------
# Fixtures. Every case builds a FRESH city: the sidecar and the mail marker
# accumulate, and their state across cycles is the subject under test.
# ---------------------------------------------------------------------------

# The skill repo: two commits of skills/deploy, so "installed at the first,
# manifest at the second" is a real sha_mismatch with observable content.
SRC="$(mktemp -d)/acme-skills"
git init -q "$SRC"
git -C "$SRC" -c user.email=t@t -c user.name=t commit -q --allow-empty -m root
mkdir -p "$SRC/skills/deploy"
printf -- '---\nname: deploy\ndescription: ship it\n---\nv1\n' >"$SRC/skills/deploy/SKILL.md"
git -C "$SRC" add -A
git -C "$SRC" -c user.email=t@t -c user.name=t commit -q -m one
SHA1="$(git -C "$SRC" rev-parse HEAD)"
printf -- '---\nname: deploy\ndescription: ship it\n---\nv2\n' >"$SRC/skills/deploy/SKILL.md"
printf 'helper\n' >"$SRC/skills/deploy/helper.sh"
git -C "$SRC" add -A
git -C "$SRC" -c user.email=t@t -c user.name=t commit -q -m two
SHA2="$(git -C "$SRC" rev-parse HEAD)"

# manifest_json SHA [EXTRA_JQ] — the list_skills body (before verdicts) the
# stub serves: one skill, acme/deploy, pinned at SHA, sourced from $SRC.
manifest_json() {
	jq -n --arg sha "$1" --arg url "$SRC" '{
		count: 1, discovery_available: true,
		repos: [{name: "acme", provider: "github", repo: "acme/acme-skills", clone_url: $url, skills_dir: "skills", skills: ["acme/deploy"], status: {state: "ok"}}],
		skills: [{id: "acme/deploy", name: "deploy", repo: "acme", description: "ship it", sha: $sha,
		          source: {clone_url: $url, subpath: "", path: "skills/deploy/SKILL.md"}}]
	}' | jq -c "${2:-.}"
}

# new_city — scaffold a throwaway city plus stubs, and echo its path.
# One rig, rigA, opted in and bound to acme/app.
new_city() {
	local city
	city="$(mktemp -d)"
	mkdir -p "$city/bin" "$city/state" "$city/rigA/.claude/skills" "$city/gcskills/gc-work"
	printf 'SKILLS_SYNC_RIGS="rigA"\nRIG_PROJECTS="rigA=acme/app"\n' >"$city/state/roster.conf"
	jq -n --arg p "$city/rigA" '[{name: "rigA", path: $p, suspended: false}]' >"$city/rigs.json"
	echo '{"projects":[{"id":1,"name":"App","slug":"app","tenant_slug":"acme"}]}' >"$city/projects.json"
	manifest_json "$SHA2" >"$city/manifest.json"

	# gc's half of the sink: one materialized skill, recorded in its manifest.
	printf 'gc-owned\n' >"$city/gcskills/gc-work/SKILL.md"
	ln -s "$city/gcskills/gc-work" "$city/rigA/.claude/skills/core.gc-work"
	jq -n --arg t "$city/gcskills/gc-work" '{targets: {"core.gc-work": $t}}' >"$city/rigA/.claude/skills/.gc-skill-ownership.json"
	cp "$city/rigA/.claude/skills/.gc-skill-ownership.json" "$city/gc-manifest.before"

	cat >"$city/bin/gc" <<'STUB'
#!/bin/sh
case "$1 $2" in
"rig list") cat "$GC_CITY/rigs.json" ;;
"mail send")
	shift 2
	subj=""
	while [ $# -gt 0 ]; do
		case "$1" in
		-s) subj="$2"; shift 2 ;;
		-m) printf '%s\n' "$2" >>"$GC_CITY/mail-bodies.log"; shift 2 ;;
		*) shift ;;
		esac
	done
	printf 'SUBJ %s\n' "$subj" >>"$GC_CITY/mailed.log"
	;;
esac
exit 0
STUB

	# sy_api_get feeds curl a config on stdin and reads the body on stdout.
	cat >"$city/bin/curl" <<'STUB'
#!/bin/sh
cat >/dev/null
cat "$GC_CITY/projects.json"
STUB

	# The MCP stub: a real newline-delimited JSON-RPC peer. It records every
	# tools/call, grades the fixture manifest against the installed map the
	# way skills_verdict.go does, bounds skills[] to the requested limit the
	# way list_bounds.go's boundListPayload does (truncated/limit/total), and
	# appends the update-signal text block a stale production binary appends —
	# which the loop must ignore.
	cat >"$city/bin/switchyard-mcp" <<'STUB'
#!/bin/sh
while IFS= read -r line; do
	case "$line" in
	*'"method":"initialize"'*)
		printf '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"tools":{}},"serverInfo":{"name":"stub","version":"0"}}}\n' ;;
	*'"method":"tools/call"'*)
		printf '%s\n' "$line" | jq -c '.params' >>"$GC_CITY/mcp-calls.log"
		if [ -f "$GC_CITY/mcp-refuse" ]; then
			printf '{"jsonrpc":"2.0","id":2,"result":{"isError":true,"content":[{"type":"text","text":"project not found"}]}}\n'
			continue
		fi
		installed="$(printf '%s' "$line" | jq -c '.params.arguments.installed')"
		limit="$(printf '%s' "$line" | jq -c '.params.arguments.limit // 0')"
		text="$(jq -c --argjson inst "$installed" --argjson lim "$limit" '
			.skills |= map(
				if has("verdict") then . else
				.verdict = (
					if $inst == null then {outdated: false, determined: false, reason: "no_installed_set"}
					elif ($inst[.id] // null) == null then {outdated: true, determined: true, reason: "not_installed"}
					elif (.sha // "") == "" then {outdated: false, determined: false, reason: "unknown_manifest_sha"}
					elif $inst[.id] == .sha then {outdated: false, determined: true, reason: "current"}
					else {outdated: true, determined: true, reason: "sha_mismatch"} end) end)
			| if $lim > 0 and (.skills | length) > $lim
			  then .total = (.skills | length) | .skills = .skills[:$lim] | .truncated = true | .limit = $lim
			  else . end' "$GC_CITY/manifest.json")"
		jq -cn --arg t "$text" '{jsonrpc: "2.0", id: 2, result: {content: [{type: "text", text: $t}, {type: "text", text: "{\"switchyard_mcp_update_available\":{\"signal\":\"update_available\"}}"}]}}'
		;;
	esac
done
STUB
	chmod +x "$city/bin/gc" "$city/bin/curl" "$city/bin/switchyard-mcp"
	echo "$city"
}

# run CITY — one order cycle. Captures the log for assertions.
run() {
	GC_CITY="$1" GC_PACK_STATE_DIR="$1/state" SWITCHYARD_API_TOKEN="sy_test" \
		PATH="$1/bin:$PATH" SY_MCP_MAX_TIME=20 SKILLS_SYNC_GIT_TIMEOUT=60 \
		SKILLS_SYNC_MANIFEST_LIMIT="${SKILLS_SYNC_MANIFEST_LIMIT:-}" \
		"$SKILLS_TEST_SH" "$SYNC" >"$1/run.log" 2>&1
	echo $? >"$1/run.rc"
}

sink() { printf '%s/rigA/.claude/skills' "$1"; }
sidecar_sha() { jq -r --arg id "$1" '.skills[$id].sha // ""' "$(sink "$2")/.switchyard-skill-ownership.json" 2>/dev/null; }
last_installed_arg() { tail -n1 "$1/mcp-calls.log" 2>/dev/null | jq -c '.arguments.installed'; }
mail_count() { grep -c '^SUBJ' "$1/mailed.log" 2>/dev/null || echo 0; }

# gc_untouched CITY LABEL — the two invariants every case must hold.
gc_untouched() {
	if cmp -s "$1/gc-manifest.before" "$(sink "$1")/.gc-skill-ownership.json" \
		&& [ "$(readlink "$(sink "$1")/core.gc-work")" = "$1/gcskills/gc-work" ] \
		&& [ "$(cat "$1/gcskills/gc-work/SKILL.md")" = gc-owned ]; then
		report ok "$2: gc manifest and gc symlink untouched"
	else
		report FAIL "$2: gc manifest or gc symlink was touched"
	fi
}

# ---------------------------------------------------------------------------
# OFF BY DEFAULT.
# ---------------------------------------------------------------------------
c="$(new_city)"
printf 'RIG_PROJECTS="rigA=acme/app"\n' >"$c/state/roster.conf"
run "$c"
[ "$(cat "$c/run.rc")" = 0 ] && report ok "off: exits 0" || report FAIL "off: rc $(cat "$c/run.rc")"
[ ! -f "$c/mcp-calls.log" ] && report ok "off: list_skills is never called" || report FAIL "off: list_skills was called"
grep -q 'SKILLS_SYNC_RIGS is empty' "$c/run.log" && report ok "off: says why" || report FAIL "off: no reason logged" "$(cat "$c/run.log")"

# ---------------------------------------------------------------------------
# INSTALL: a fresh sink. The positive control for everything below.
# ---------------------------------------------------------------------------
c="$(new_city)"
run "$c"
[ "$(cat "$c/run.rc")" = 0 ] && report ok "install: exits 0" || report FAIL "install: rc $(cat "$c/run.rc")" "$(cat "$c/run.log")"
[ "$(last_installed_arg "$c")" = '{}' ] && report ok "install: list_skills called with installed={}" || report FAIL "install: installed arg" "$(last_installed_arg "$c")"
args="$(tail -n1 "$c/mcp-calls.log" | jq -r '"\(.name) \(.arguments.tenant_slug)/\(.arguments.project_slug)"')"
[ "$args" = "list_skills acme/app" ] && report ok "install: scoped to the rig's project by per-call override" || report FAIL "install: scope" "$args"
lim="$(tail -n1 "$c/mcp-calls.log" | jq -r '.arguments.limit')"
[ "$lim" = 500 ] && report ok "install: asks for the MCP's 500-row cap, not the 50-row default" || report FAIL "install: limit" "$lim"
[ "$(tail -n1 "$(sink "$c")/acme.deploy/SKILL.md" 2>/dev/null)" = v2 ] && report ok "install: SKILL.md materialized at the manifest sha" || report FAIL "install: SKILL.md" "$(cat "$c/run.log")"
[ -f "$(sink "$c")/acme.deploy/helper.sh" ] && report ok "install: supporting files come with it" || report FAIL "install: helper.sh missing"
[ ! -L "$(sink "$c")/acme.deploy" ] && report ok "install: an org skill is a real directory, not a symlink" || report FAIL "install: symlink"
[ "$(sidecar_sha acme/deploy "$c")" = "$SHA2" ] && report ok "install: sidecar records the manifest sha" || report FAIL "install: sidecar sha" "$(sidecar_sha acme/deploy "$c")"
grep -q 'acme/deploy: installed at' "$c/run.log" && report ok "install: logged" || report FAIL "install: not logged" "$(cat "$c/run.log")"
[ "$(mail_count "$c")" = 0 ] && report ok "install: no mail on a clean pass" || report FAIL "install: mailed"
[ -z "$(ls -A "$(sink "$c")" | grep '^\.skills-sync')" ] && report ok "install: no stage/old leftovers" || report FAIL "install: leftovers" "$(ls -A "$(sink "$c")")"
gc_untouched "$c" install

# SECOND PASS: current, so nothing is fetched. The sentinel proves the
# directory was not re-materialized.
touch "$(sink "$c")/acme.deploy/.sentinel"
rm -f "$c/mcp-calls.log"
run "$c"
[ "$(last_installed_arg "$c")" = "{\"acme/deploy\":\"$SHA2\"}" ] && report ok "current: installed sha is sent back" || report FAIL "current: installed arg" "$(last_installed_arg "$c")"
[ -f "$(sink "$c")/acme.deploy/.sentinel" ] && report ok "current: directory left alone" || report FAIL "current: directory re-materialized"
grep -q 'current 1, skipped 0' "$c/run.log" && report ok "current: counted current, nothing installed" || report FAIL "current: summary" "$(cat "$c/run.log")"
gc_untouched "$c" current

# ---------------------------------------------------------------------------
# UPDATE: installed at the first commit, manifest at the second.
# ---------------------------------------------------------------------------
c="$(new_city)"
mkdir -p "$(sink "$c")/acme.deploy"
printf 'stale\n' >"$(sink "$c")/acme.deploy/SKILL.md"
jq -n --arg sha "$SHA1" '{version: 1, skills: {"acme/deploy": {dir: "acme.deploy", sha: $sha}}}' >"$(sink "$c")/.switchyard-skill-ownership.json"
run "$c"
[ "$(last_installed_arg "$c")" = "{\"acme/deploy\":\"$SHA1\"}" ] && report ok "update: old sha sent as installed" || report FAIL "update: installed arg" "$(last_installed_arg "$c")"
[ "$(tail -n1 "$(sink "$c")/acme.deploy/SKILL.md")" = v2 ] && report ok "update: content replaced with the manifest sha's" || report FAIL "update: content" "$(cat "$c/run.log")"
[ "$(sidecar_sha acme/deploy "$c")" = "$SHA2" ] && report ok "update: sidecar moved to the manifest sha" || report FAIL "update: sidecar" "$(sidecar_sha acme/deploy "$c")"
grep -q 'acme/deploy: updated to' "$c/run.log" && report ok "update: logged as an update" || report FAIL "update: log" "$(cat "$c/run.log")"
gc_untouched "$c" update

# ---------------------------------------------------------------------------
# HAND-DELETED: the sidecar says installed, the directory is gone.
# ---------------------------------------------------------------------------
c="$(new_city)"
jq -n --arg sha "$SHA2" '{version: 1, skills: {"acme/deploy": {dir: "acme.deploy", sha: $sha}}}' >"$(sink "$c")/.switchyard-skill-ownership.json"
run "$c"
[ "$(last_installed_arg "$c")" = '{}' ] && report ok "hand-deleted: a missing directory is not reported installed" || report FAIL "hand-deleted: installed arg" "$(last_installed_arg "$c")"
[ "$(tail -n1 "$(sink "$c")/acme.deploy/SKILL.md" 2>/dev/null)" = v2 ] && report ok "hand-deleted: re-installed" || report FAIL "hand-deleted: not re-installed"

# ---------------------------------------------------------------------------
# gc-OWNED COLLISION: the manifest publishes a skill whose sink name gc owns.
# ---------------------------------------------------------------------------
c="$(new_city)"
manifest_json "$SHA2" '.skills[0].id = "core/gc-work" | .skills[0].name = "gc-work" | .skills[0].repo = "core"' >"$c/manifest.json"
run "$c"
[ "$(cat "$c/run.rc")" = 0 ] && report ok "collision: exits 0" || report FAIL "collision: rc"
[ -L "$(sink "$c")/core.gc-work" ] && report ok "collision: gc's symlink is still a symlink" || report FAIL "collision: symlink replaced"
gc_untouched "$c" collision
[ -z "$(sidecar_sha core/gc-work "$c")" ] && report ok "collision: nothing recorded as ours" || report FAIL "collision: sidecar entry written"
[ "$(mail_count "$c")" = 1 ] && report ok "collision: mayor mailed" || report FAIL "collision: mail count $(mail_count "$c")"
grep -q 'gc-owned' "$c/mail-bodies.log" && report ok "collision: mail names the gc-owned entry" || report FAIL "collision: mail body" "$(cat "$c/mail-bodies.log" 2>/dev/null)"

# A symlink gc materialized but did NOT record (a pre-manifest gc) is still
# not ours to touch.
c="$(new_city)"
ln -s "$c/gcskills/gc-work" "$(sink "$c")/acme.deploy"
run "$c"
[ "$(readlink "$(sink "$c")/acme.deploy")" = "$c/gcskills/gc-work" ] && report ok "unrecorded symlink: left in place" || report FAIL "unrecorded symlink: replaced"
[ -z "$(sidecar_sha acme/deploy "$c")" ] && report ok "unrecorded symlink: nothing recorded" || report FAIL "unrecorded symlink: sidecar written"
[ "$(mail_count "$c")" = 1 ] && report ok "unrecorded symlink: mayor mailed" || report FAIL "unrecorded symlink: mail count $(mail_count "$c")"

# A directory that exists but is not in the sidecar was put there by someone
# else. Not ours either.
c="$(new_city)"
mkdir -p "$(sink "$c")/acme.deploy"
printf 'hand-written\n' >"$(sink "$c")/acme.deploy/SKILL.md"
run "$c"
[ "$(cat "$(sink "$c")/acme.deploy/SKILL.md")" = hand-written ] && report ok "foreign dir: left in place" || report FAIL "foreign dir: overwritten"
[ "$(mail_count "$c")" = 1 ] && report ok "foreign dir: mayor mailed" || report FAIL "foreign dir: mail count $(mail_count "$c")"

# ---------------------------------------------------------------------------
# determined FIRST.
# ---------------------------------------------------------------------------
c="$(new_city)"
manifest_json "$SHA2" '.discovery_available = false | .skills = [] | .count = 0' >"$c/manifest.json"
run "$c"
[ ! -e "$(sink "$c")/acme.deploy" ] && report ok "discovery unavailable: installs nothing" || report FAIL "discovery unavailable: installed"
grep -q 'discovery_available=false' "$c/run.log" && report ok "discovery unavailable: says the registry was not read" || report FAIL "discovery unavailable: log" "$(cat "$c/run.log")"
[ "$(mail_count "$c")" = 0 ] && report ok "discovery unavailable: not a failure to mail" || report FAIL "discovery unavailable: mailed"

c="$(new_city)"
manifest_json "" '.skills[0].verdict = {outdated: false, determined: false, reason: "unknown_manifest_sha"}' >"$c/manifest.json"
run "$c"
[ ! -e "$(sink "$c")/acme.deploy" ] && report ok "undetermined verdict: installs nothing" || report FAIL "undetermined verdict: installed"
grep -q 'undetermined (unknown_manifest_sha)' "$c/run.log" && report ok "undetermined verdict: reason logged" || report FAIL "undetermined verdict: log" "$(cat "$c/run.log")"

# A determined not_installed row whose manifest carries no sha cannot be
# pinned, so it is reported rather than installed from wherever HEAD is.
c="$(new_city)"
manifest_json "" >"$c/manifest.json"
run "$c"
[ ! -e "$(sink "$c")/acme.deploy" ] && report ok "no sha: installs nothing unpinned" || report FAIL "no sha: installed"
[ "$(mail_count "$c")" = 1 ] && report ok "no sha: mayor mailed" || report FAIL "no sha: mail count $(mail_count "$c")"

# ---------------------------------------------------------------------------
# FAILED FETCH leaves no trace, and mails once per 24h.
# ---------------------------------------------------------------------------
c="$(new_city)"
manifest_json "$SHA2" '.skills[0].source.clone_url = "/nonexistent/acme-skills"' >"$c/manifest.json"
run "$c"
[ "$(cat "$c/run.rc")" = 0 ] && report ok "fetch fails: exits 0" || report FAIL "fetch fails: rc"
[ ! -e "$(sink "$c")/acme.deploy" ] && report ok "fetch fails: no directory" || report FAIL "fetch fails: directory exists"
[ -z "$(sidecar_sha acme/deploy "$c")" ] && report ok "fetch fails: no sidecar entry" || report FAIL "fetch fails: sidecar written"
[ -z "$(ls -A "$(sink "$c")" | grep '^\.skills-sync')" ] && report ok "fetch fails: no stage leftovers" || report FAIL "fetch fails: leftovers" "$(ls -A "$(sink "$c")")"
[ "$(mail_count "$c")" = 1 ] && report ok "fetch fails: mayor mailed" || report FAIL "fetch fails: mail count $(mail_count "$c")"
run "$c"
[ "$(mail_count "$c")" = 1 ] && report ok "fetch fails: second cycle within 24h does not re-mail" || report FAIL "fetch fails: re-mailed"
gc_untouched "$c" "fetch fails"

# ---------------------------------------------------------------------------
# A wrong sha the repo does not have is a failure, not a fallback to HEAD.
# ---------------------------------------------------------------------------
c="$(new_city)"
manifest_json "0123456789abcdef0123456789abcdef01234567" >"$c/manifest.json"
run "$c"
[ ! -e "$(sink "$c")/acme.deploy" ] && report ok "unknown sha: installs nothing" || report FAIL "unknown sha: installed something"
[ "$(mail_count "$c")" = 1 ] && report ok "unknown sha: mayor mailed" || report FAIL "unknown sha: mail count $(mail_count "$c")"

# ---------------------------------------------------------------------------
# DISABLED for this project: removed if ours, never if gc's.
# ---------------------------------------------------------------------------
c="$(new_city)"
mkdir -p "$(sink "$c")/acme.old"
printf 'old\n' >"$(sink "$c")/acme.old/SKILL.md"
jq -n --arg sha "$SHA1" '{version: 1, skills: {"acme/old": {dir: "acme.old", sha: $sha}}}' >"$(sink "$c")/.switchyard-skill-ownership.json"
manifest_json "$SHA2" '.disabled_skills = ["acme/old", "core/gc-work"]' >"$c/manifest.json"
run "$c"
[ ! -e "$(sink "$c")/acme.old" ] && report ok "disabled: a skill this loop installed is removed" || report FAIL "disabled: still present"
[ -z "$(sidecar_sha acme/old "$c")" ] && report ok "disabled: sidecar entry dropped" || report FAIL "disabled: sidecar kept"
[ "$(tail -n1 "$(sink "$c")/acme.deploy/SKILL.md" 2>/dev/null)" = v2 ] && report ok "disabled: the enabled skill still installs" || report FAIL "disabled: enabled skill missing"
gc_untouched "$c" disabled

# A skill this loop installed that the manifest simply no longer publishes is
# left where it is — and said so.
c="$(new_city)"
mkdir -p "$(sink "$c")/acme.gone"
printf 'gone\n' >"$(sink "$c")/acme.gone/SKILL.md"
jq -n --arg sha "$SHA1" '{version: 1, skills: {"acme/gone": {dir: "acme.gone", sha: $sha}}}' >"$(sink "$c")/.switchyard-skill-ownership.json"
run "$c"
[ -f "$(sink "$c")/acme.gone/SKILL.md" ] && report ok "unpublished: left in place" || report FAIL "unpublished: removed"
grep -q 'acme/gone: no longer in the acme/app manifest' "$c/run.log" && report ok "unpublished: logged" || report FAIL "unpublished: log" "$(cat "$c/run.log")"

# TRUNCATED: the manifest came back cut. The rows served still sync (the
# positive control), the cut tail is mailed rather than taken as the whole
# manifest, and the "no longer published" report above — whose positive half
# is the case just run — is suppressed, since absence from a cut list proves
# nothing. The stub bounds skills[] to the limit the loop sends, so shrinking
# the limit to 1 cuts acme/zzz off the end.
c="$(new_city)"
mkdir -p "$(sink "$c")/acme.gone"
printf 'gone\n' >"$(sink "$c")/acme.gone/SKILL.md"
jq -n --arg sha "$SHA1" '{version: 1, skills: {"acme/gone": {dir: "acme.gone", sha: $sha}}}' >"$(sink "$c")/.switchyard-skill-ownership.json"
manifest_json "$SHA2" '.skills += [.skills[0] | .id = "acme/zzz" | .name = "zzz"] | .count = 2' >"$c/manifest.json"
SKILLS_SYNC_MANIFEST_LIMIT=1 run "$c"
[ "$(tail -n1 "$c/mcp-calls.log" | jq -r '.arguments.limit')" = 1 ] && report ok "truncated: the limit reaches list_skills" || report FAIL "truncated: limit arg"
[ "$(tail -n1 "$(sink "$c")/acme.deploy/SKILL.md" 2>/dev/null)" = v2 ] && report ok "truncated: the rows served still install" || report FAIL "truncated: served row not installed" "$(cat "$c/run.log")"
[ ! -e "$(sink "$c")/acme.zzz" ] && report ok "truncated: the cut row is not invented" || report FAIL "truncated: cut row installed"
grep -q 'manifest is truncated' "$c/run.log" && report ok "truncated: logged" || report FAIL "truncated: log" "$(cat "$c/run.log")"
grep -q 'truncated at 1 of 2 rows' "$c/mail-bodies.log" 2>/dev/null && report ok "truncated: mayor mailed with the cut" || report FAIL "truncated: mail body" "$(cat "$c/mail-bodies.log" 2>/dev/null)"
! grep -q 'no longer in the' "$c/run.log" && report ok "truncated: no 'no longer published' claim from a cut list" || report FAIL "truncated: unpublished claimed" "$(cat "$c/run.log")"
[ -f "$(sink "$c")/acme.gone/SKILL.md" ] && report ok "truncated: nothing removed" || report FAIL "truncated: acme.gone removed"
gc_untouched "$c" truncated

# ---------------------------------------------------------------------------
# The MCP refusing (a scope this token cannot reach) installs nothing.
# ---------------------------------------------------------------------------
c="$(new_city)"
: >"$c/mcp-refuse"
run "$c"
[ ! -e "$(sink "$c")/acme.deploy" ] && report ok "mcp refuses: installs nothing" || report FAIL "mcp refuses: installed"
grep -q 'answered nothing (project not found)' "$c/run.log" && report ok "mcp refuses: the refusal is logged verbatim" || report FAIL "mcp refuses: log" "$(cat "$c/run.log")"

# A rig whose project cannot be resolved never reaches the MCP.
c="$(new_city)"
printf 'SKILLS_SYNC_RIGS="rigA"\n' >"$c/state/roster.conf"
echo '{"projects":[{"id":1,"name":"App","slug":"app","tenant_slug":"acme"},{"id":2,"name":"App","slug":"app","tenant_slug":"other"}]}' >"$c/projects.json"
printf 'RIG_PROJECTS=""\nSKILLS_SYNC_RIGS="rigA"\n' >"$c/state/roster.conf"
run "$c"
[ ! -f "$c/mcp-calls.log" ] && report ok "unresolved rig: list_skills never called" || report FAIL "unresolved rig: called"
grep -q 'no switchyard project resolves' "$c/run.log" && report ok "unresolved rig: says so" || report FAIL "unresolved rig: log" "$(cat "$c/run.log")"

echo
echo "skills-sync.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
