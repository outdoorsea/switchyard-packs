#!/bin/sh
#
# fanout-child-run.sh — run ONE fan-out child bead inside the parent's
# worktree, on the parent's branch, under a confinement that refuses the two
# acts which would cost the criterion its single deliverable.
#
# switchyard PRD #372, crit:cb7409dc0b5a.
#
# WHY A CHILD IS RUN HERE AND NOT SLUNG
#
# Every worker shape this pack already owns hands the worker its OWN worktree:
# `gc sling` and `gc session new` both start a session whose agent.toml
# declares `work_dir`, and whose `pre_start` runs `worktree-setup.sh` to mint
# it. Worse, a bare sling attaches this pack's `default_sling_formula`,
# `sy-item-work`, whose publish step pushes a branch and opens a pull request.
#
# A fan-out child given either of those breaks the epic this criterion belongs
# to — "one worktree, one PR" — in the two ways that are hardest to notice: the
# work lands on a branch the parent never sees, or a second pull request
# appears against a criterion that has exactly one deliverable. So a child is
# EXECUTED by this harness, in the parent's worktree, with no bead routed and
# no formula attached. The cloud pool keeps its meaning; local beads stay pure
# execution detail.
#
# WHAT THIS SCRIPT GUARANTEES
#
#   1. The child runs in the parent's worktree. The worktree is checked, and a
#      worktree on a DIFFERENT branch is refused rather than used — a child
#      committing on some other branch splits the deliverable, and nothing
#      downstream would notice until the pull request came up short.
#   2. The child gets a DIGEST brief, not a dossier: bounded, and bounded in
#      the only safe direction. The item text is truncated; the rules never
#      are, because a brief that dropped its own refusal lines to fit a budget
#      would be worse than no budget.
#   3. The child cannot open a pull request or take a cloud claim, because the
#      harness WITHHOLDS THE CREDENTIALS for both and, as defence in depth,
#      puts refusal shims first on its PATH. See fanout-confine/.
#
# WHY CREDENTIALS AND NOT JUST PATH. The first version of this harness relied on
# the PATH shims alone. They do not survive contact with a real child: the
# default launcher is `claude -p`, whose shell initializes from the user's
# profile and RE-SETS PATH, so `env PATH=<confine>:$PATH zsh -lc 'command -v gh'`
# resolves the real gh while a plain `sh -c` resolves the shim. The shims also
# cannot reach an MCP tool call at all — clients spawn switchyard-mcp by
# absolute path, so PATH is never consulted. A login shell restores PATH; it
# does not restore a token. So the enforcement that actually holds is the child
# not HAVING the credential: no GitHub token, no GitLab token, NEITHER
# switchyard env token (the plural SWITCHYARD_API_TOKENS outranks the singular,
# so scrubbing one and not the other withholds nothing), and a switchyard config
# home with no token in it. The shims stay because they refuse loudly and tell
# the child WHY, which a bare 401 does not.
#
# WHAT THIS STILL DOES NOT COVER, stated because the guarantee above is only as
# good as its exceptions. A credential PINNED IN AN MCP CLIENT CONFIG does not
# reach the child by inheritance, so emptying it here cannot remove it: Claude
# Code reads ~/.claude.json, finds the `switchyard` server stanza registered for
# the child's project directory, and INJECTS that stanza's own env block into
# the server process it spawns. docs/mcp-auth-provisioning.md lists exactly that
# as a credential-bearing source, and it is a live configuration in this repo
# today. Closing it needs the launcher started with `--strict-mcp-config`, which
# this harness deliberately cannot do: its contract is that NOTHING is appended
# to the launcher's argv (a path appended there becomes `claude -p`'s whole
# prompt), and scripts/fanout-one-pr.test.sh asserts that argv is empty. So a
# child launched by a Claude Code that has a pinned switchyard token can still
# reach the claim protocol as MCP TOOL CALLS. Tracked as follow-up work against
# PRD #372; it belongs with the launcher contract (crit:cb7409dc0b5a), not with
# the credential scrub here.
#
# The brief is fed on the child's STDIN, which also closes a trap this PRD has
# already been bitten by once: a caller looping over a plan file would
# otherwise hand each child the loop's stdin, and a child that read any of it
# would eat the remaining plan items.
#
# CONFIGURATION
#   SY_FANOUT_CHILD_LAUNCHER  command line that runs one child. The brief is on
#                             the child's STDIN and its path is in
#                             SY_FANOUT_BRIEF; nothing is appended to argv.
#                             Default: `claude -p`.
#   SY_FANOUT_BRIEF_MAX_BYTES digest budget for the brief. Default 4000. It
#                             bounds the ITEM; the rules are a floor, so a
#                             brief can exceed a very small budget rather than
#                             ship without them.
#   SY_FANOUT_REFUSAL_LOG     where the confinement records what a child tried.
#                             Defaults to <brief>.refusals.
#   SY_FANOUT_MAX_CONCURRENCY children that may run at once. Default 3, lowered
#                             by the balancer's live target for the rig. This
#                             script takes one slot for the duration of the
#                             child and reports the cap it ran under.
#   SY_FANOUT_RIG             the rig whose balancer target gates that cap, when
#                             --rig is not passed (the flag wins). This is NOT
#                             optional plumbing: the load-aware gate matches
#                             balancer targets BY RIG NAME, so a child run with
#                             neither --rig nor this variable enforces only the
#                             configured cap — while the decomposer, which does
#                             get --rig, reports the balancer's. The brakeman
#                             prompt's documented invocation passes --rig for
#                             exactly that reason: so the cap on the decision
#                             line is the cap every child actually ran under.
#   SY_FANOUT_SLOT_DIR        where those slots live. Defaults to a path derived
#                             from the shared worktree.
#   SY_FANOUT_SLOT_WAIT       seconds to wait for a slot before running anyway.
#                             Default 300. See lib/fanout.sh.
#
# USAGE
#   fanout-child-run.sh --bead <id> --worktree <path> --branch <name>
#                       [--item <text> | --item-file <path>] [--crit <label>]
#                       [--prd <id>] [--parent <bead>] [--brief-out <path>]
#                       [--rig <rig>]
#
# Prefer --item-file for anything long: Linux caps a single argument at 128 KiB
# and a longer --item fails to exec, with no report line at all.
#
# Exit 0 when the child ran and succeeded; non-zero otherwise — a refusal is
# NOT a success here (unlike the decomposer's serial decision, which is one),
# because a child that did not run is work the parent still has to do.

set -u

# roster.conf FIRST, exactly as every roster-tunable sibling does: this script
# runs inside a brakeman session whose environment carries no roster.conf vars,
# so without sy_load_conf the SY_FANOUT_* knobs documented in
# roster.conf.example are dead config on every real deployment — an operator's
# launcher choice would be silently ignored. fanout-decompose.sh (the other half
# of this PRD) carries the same two lines for the same reason.
. "$(dirname "$0")/../lib/roster.sh"
sy_load_conf
# AFTER sy_load_conf: roster.conf is where SY_FANOUT_MAX_CONCURRENCY is set, so
# a cap resolved above this line would ignore the operator's configuration.
. "$(dirname "$0")/../lib/fanout.sh"

FANOUT_BRIEF_DEFAULT_BYTES=4000
REFUSED_EXIT=3
CHILD_FAILED_EXIT=4

usage() {
	cat >&2 <<'USAGE'
usage: fanout-child-run.sh --bead <id> --worktree <path> --branch <name>
                          [--item <text> | --item-file <path>] [--crit <label>]
                          [--prd <id>] [--parent <bead>] [--brief-out <path>]
                          [--rig <rig>]
USAGE
	exit 2
}

bead=""
wt=""
branch=""
item=""
item_path=""
crit=""
prd=""
parent=""
brief=""
rig="${SY_FANOUT_RIG:-}"

while [ $# -gt 0 ]; do
	case "$1" in
	--bead) [ $# -ge 2 ] || usage; bead="$2"; shift 2 ;;
	--worktree) [ $# -ge 2 ] || usage; wt="$2"; shift 2 ;;
	--branch) [ $# -ge 2 ] || usage; branch="$2"; shift 2 ;;
	--item) [ $# -ge 2 ] || usage; item="$2"; shift 2 ;;
	--item-file) [ $# -ge 2 ] || usage; item_path="$2"; shift 2 ;;
	--crit) [ $# -ge 2 ] || usage; crit="$2"; shift 2 ;;
	--prd) [ $# -ge 2 ] || usage; prd="$2"; shift 2 ;;
	--parent) [ $# -ge 2 ] || usage; parent="$2"; shift 2 ;;
	--brief-out) [ $# -ge 2 ] || usage; brief="$2"; shift 2 ;;
	--rig) [ $# -ge 2 ] || usage; rig="$2"; shift 2 ;;
	-h | --help) usage ;;
	*)
		printf 'fanout-child-run: unknown argument %s\n' "$1" >&2
		usage
		;;
	esac
done

[ -n "$bead" ] || usage
[ -n "$wt" ] || usage
[ -n "$branch" ] || usage

# The confinement is resolved BEFORE anything changes directory: $0 is relative
# on most call sites, and a relative PATH entry handed to a child that runs
# somewhere else silently confines nothing.
script_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || script_dir=""
confine="$script_dir/fanout-confine"

work="$(mktemp -d "${TMPDIR:-/tmp}/fanout-child.XXXXXX")" || {
	printf 'fanout-child-run: cannot create a work directory\n' >&2
	exit 2
}
# Signals are RE-RAISED, not absorbed. A bare `trap ... INT TERM` runs the
# handler and falls through to a 0 exit, so a parent (or a lease timeout) that
# kills this harness to bound a fan-out would record the child as a clean
# success. fanout-decompose.sh splits the traps for the same reason.
trap 'sy_fanout_slot_release "$slot"; rm -rf "$work"' EXIT
trap 'sy_fanout_slot_release "$slot"; rm -rf "$work"; exit 130' INT
trap 'sy_fanout_slot_release "$slot"; rm -rf "$work"; exit 143' TERM

# Inside the work directory, not a predictable /tmp/fanout-brief-<bead>.md: the
# old path was symlink-followable and took `../` from an attacker-influenced
# bead id. A caller that wants to keep the brief passes --brief-out.
[ -n "$brief" ] || brief="$work/brief.md"
refusal_log="${SY_FANOUT_REFUSAL_LOG:-$brief.refusals}"

status="refused"
reason=""
brief_bytes=0
confined=0
refusals=0
launcher_name="-"
slot="-"
slot_state="none"

# The concurrency cap this child runs under, resolved BEFORE the first refusal
# path so every report line carries it — a child refused for a wrong branch
# still says what the box would have allowed. See lib/fanout.sh.
cap="$(sy_fanout_cap "$rig")"
cap_source="${cap#* }"
cap="${cap%% *}"

# The report goes to STDERR. The child's own output — LLM prose, under the
# default launcher — owns stdout, and a child that merely PRINTS the words
# "status=refused" would otherwise be indistinguishable from this line to
# anything parsing the stream. Parsers should anchor on `^fanout-child-run:`
# and take the LAST match.
emit_and_exit() {
	_rc="$1"
	trace_fate
	printf 'fanout-child-run: child=%s status=%s reason=%s worktree=%s branch=%s brief_bytes=%s confined=%s refusals=%s launcher=%s cap=%s cap_source=%s slot=%s\n' \
		"$bead" "$status" "${reason:--}" "$wt" "$branch" "$brief_bytes" \
		"$confined" "$refusals" "$launcher_name" "$cap" "$cap_source" \
		"$slot_state" >&2
	exit "$_rc"
}

# ---------------------------------------------------------------------------
# The trace (switchyard PRD #372, crit:cc901595a33b). A child's fate is legible
# to a successor only if it outlives this process: the report line above dies
# with the terminal it was printed to, and the parent may be a session that is
# itself about to be reclaimed. So every terminal path also records the fate to
# the fan-out's ledger, from which the parent builds the handoff that names its
# unfinished children.
#
# Best-effort BY CONSTRUCTION. A fan-out that has not configured a ledger is the
# pack's ordinary path and must not start failing because this exists — so a
# missing ledger, parent or script is a silent no-op here, and only here. Where
# the ledger IS configured, fanout-trace.sh reports its own failures rather than
# swallowing them.
# ---------------------------------------------------------------------------
trace_script="$script_dir/fanout-trace.sh"
trace_parent="${parent:-${SY_FANOUT_PARENT_BEAD:-}}"
traced=0

trace_record() {
	[ -n "${SY_FANOUT_LEDGER:-}" ] || return 0
	[ -n "$trace_parent" ] || return 0
	[ -x "$trace_script" ] || return 0
	# stdout is discarded; STDERR IS NOT. The trace script's one report line —
	# `fanout-trace: ... posted=... post_reason=...` — is its only way to say
	# the cloud half did not happen (`posted=0 post_reason=no-agent|
	# no-lease-seconds|post-failed`), and swallowing it here made exactly that
	# failure invisible in production: the harness reported the child's fate
	# while the parent-bead trace silently never fired. It flows to this
	# harness's own stderr, next to the report line below.
	"$trace_script" record --parent "$trace_parent" --child "$bead" \
		--status "$1" --reason "${2:--}" --ledger "$SY_FANOUT_LEDGER" \
		>/dev/null || :
}

# trace_fate — the terminal record, exactly once. Guarded because a signal that
# arrives DURING emit_and_exit would otherwise re-enter and write the child's
# fate twice, which reads downstream as two children.
trace_fate() {
	[ "$traced" -eq 0 ] || return 0
	traced=1
	case "${reason:-}" in
	timeout) trace_record timeout "${reason:--}" ;;
	*) trace_record "$status" "${reason:--}" ;;
	esac
}

# ---------------------------------------------------------------------------
# The signal traps are RE-SET here, now that emit_and_exit and trace_fate
# exist. Until this line a signal could only clean up: the original pair ran
# `rm -rf "$work"; exit 143` and left through it WITHOUT a report line, so a
# child harness killed by a caller's timeout — or by the lease keeper reaping a
# dead parent — was indistinguishable from one still working. That silence is
# the failure this criterion is named after.
#
# Signals are still RE-RAISED as a nonzero exit, never absorbed: a bare
# `trap ... TERM` that falls through to 0 would record a killed child as a
# clean success, which is worse than the silence it replaced.
# ---------------------------------------------------------------------------
trap 'status=failed; reason=timeout; rm -rf "$work"; emit_and_exit 130' INT
trap 'status=failed; reason=timeout; rm -rf "$work"; emit_and_exit 143' TERM

# ---------------------------------------------------------------------------
# Preflight: the parent's worktree, on the parent's branch. Fails closed. Each
# refusal names a DISTINCT reason because "the child did not run" is useless to
# a parent deciding whether to retry serially or stop.
# ---------------------------------------------------------------------------
if [ ! -d "$wt" ]; then
	reason="no-worktree"
	printf 'fanout-child-run: %s is not a directory; the parent worktree must exist before a child runs in it\n' "$wt" >&2
	emit_and_exit "$REFUSED_EXIT"
fi

if ! git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	reason="not-a-worktree"
	printf 'fanout-child-run: %s is not a git worktree\n' "$wt" >&2
	emit_and_exit "$REFUSED_EXIT"
fi

# A DETACHED head is refused before the name comparison. `rev-parse
# --abbrev-ref HEAD` prints the literal string "HEAD" when detached, so a parent
# that derived its own branch with that same command passes `--branch HEAD`,
# the two strings match, and every child would commit onto a detached HEAD —
# unreachable objects the parent's pull request does not contain. Mid-rebase, a
# bisect, or a checkout of a sha all produce this.
if ! git -C "$wt" symbolic-ref -q HEAD >/dev/null 2>&1; then
	reason="detached-head"
	printf 'fanout-child-run: %s has a detached HEAD; a child would commit unreachable objects\n' "$wt" >&2
	emit_and_exit "$REFUSED_EXIT"
fi

actual_branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" || actual_branch=""
if [ "$actual_branch" != "$branch" ]; then
	reason="wrong-branch"
	printf 'fanout-child-run: %s is on %s, not the parent branch %s; refusing rather than\n' \
		"$wt" "${actual_branch:-<detached>}" "$branch" >&2
	printf '  building a fragment of one criterion onto a branch the parent will not publish\n' >&2
	emit_and_exit "$REFUSED_EXIT"
fi

# ---------------------------------------------------------------------------
# The launcher. An unresolvable one is REFUSED loudly rather than skipped: a
# fan-out that quietly ran no children looks exactly like a fan-out that ran
# them all and found nothing to do.
# ---------------------------------------------------------------------------
launcher_cmd="${SY_FANOUT_CHILD_LAUNCHER:-claude -p}"
# Deliberate word splitting: this is a command LINE (`claude -p`), not a path.
# `set -f` first, so a launcher line is split on whitespace WITHOUT also being
# glob-expanded against the current directory.
set -f
# shellcheck disable=SC2086
set -- $launcher_cmd
set +f
if [ "$#" -eq 0 ] || ! command -v "$1" >/dev/null 2>&1; then
	reason="no-launcher"
	printf 'fanout-child-run: cannot resolve a child launcher from %s\n' "$launcher_cmd" >&2
	emit_and_exit "$REFUSED_EXIT"
fi
launcher_name="$(basename "$1")"

# ---------------------------------------------------------------------------
# The digest brief. Head first — identity, the shared worktree and branch, and
# the rules — then as much of the item as the budget leaves. The order IS the
# guarantee: the rules are written before there is any budget left to run out
# of, so truncation can only ever eat the item.
# ---------------------------------------------------------------------------
budget="${SY_FANOUT_BRIEF_MAX_BYTES:-$FANOUT_BRIEF_DEFAULT_BYTES}"
case "$budget" in
'' | *[!0-9]*) budget="$FANOUT_BRIEF_DEFAULT_BYTES" ;;
esac

head_file="$work/head"
{
	printf '# Fan-out child brief — %s\n\n' "$bead"
	printf 'You are ONE child of a fan-out. A parent brakeman holds the switchyard\n'
	printf 'cloud claim for the criterion below and is building its other parts in\n'
	printf 'this same worktree, right now.\n\n'
	# Written as `printf '%s\n' "- ..."` rather than `printf '- ...%s\n'`:
	# a format string beginning with a dash is parsed as OPTIONS, so the
	# obvious spelling emitted nothing and complained on stderr — every
	# identity line vanished from the brief while the brief still looked
	# well-formed. Caught by the digest cases in scripts/fanout-one-pr.test.sh.
	printf '%s\n' "- child bead: $bead"
	[ -n "$parent" ] && printf '%s\n' "- parent bead: $parent"
	[ -n "$crit" ] && printf '%s\n' "- criterion: $crit"
	[ -n "$prd" ] && printf '%s\n' "- PRD: #$prd"
	printf '%s\n' "- worktree: $wt (shared — do not create another)"
	printf '%s\n\n' "- branch: $branch (shared — commit here, do not cut a branch)"
	printf '## The rules, which the harness enforces\n\n'
	printf '1. **Do not open a pull request.** This criterion has exactly one\n'
	printf '   deliverable and the parent publishes it. `gh pr create` is refused.\n'
	printf '2. **Do not claim a cloud bead**, and do not touch the parent claim —\n'
	printf '   no claim, no heartbeat, no complete, no PR attachment. The lease is\n'
	printf '   the parent'\''s for the whole fan-out; those calls are refused.\n'
	printf '3. Commit your work on `%s` and stop. The parent integrates.\n\n' "$branch"
	printf 'These are not requests. Your environment carries NO GitHub, GitLab or\n'
	printf 'switchyard credential — a publish or claim will fail authentication\n'
	printf 'however you spell it, and refusal shims explain why. That is the\n'
	printf 'harness, not a fault to work around: report what you did and stop.\n\n'
	printf '## Your item\n\n'
} >"$head_file"

head_bytes="$(wc -c <"$head_file" 2>/dev/null | tr -d ' ')"
[ -n "$head_bytes" ] || head_bytes=0

# --item-file, and why it is not a convenience. Linux caps a SINGLE argument at
# MAX_ARG_STRLEN (128 KiB); macOS has no per-argument cap. So a caller that
# interpolated a long plan item — `--item "$(cat item.txt)"` — runs everywhere
# its author tests and fails to exec on the Linux box that runs it for real,
# with E2BIG and NO report line, which is the one outcome this pack refuses to
# ship: a failure indistinguishable from a run that did nothing. Reading the
# item from a file has no such limit. Found by CI on this criterion's own suite.
item_file="$work/item"
if [ -n "$item_path" ]; then
	if [ ! -r "$item_path" ]; then
		reason="no-item-file"
		printf 'fanout-child-run: cannot read the item file %s\n' "$item_path" >&2
		emit_and_exit "$REFUSED_EXIT"
	fi
	cat "$item_path" >"$item_file"
else
	printf '%s\n' "$item" >"$item_file"
fi
item_bytes="$(wc -c <"$item_file" 2>/dev/null | tr -d ' ')"
[ -n "$item_bytes" ] || item_bytes=0

remaining=$((budget - head_bytes))
[ "$remaining" -lt 200 ] && remaining=200

cp "$head_file" "$brief" 2>/dev/null || {
	printf 'fanout-child-run: cannot write the brief to %s\n' "$brief" >&2
	reason="no-brief"
	emit_and_exit "$REFUSED_EXIT"
}

if [ "$item_bytes" -gt "$remaining" ]; then
	dd bs="$remaining" count=1 <"$item_file" >>"$brief" 2>/dev/null
	printf '\n\n_(item truncated to the %s-byte digest budget — this brief is a digest,\n' "$budget" >>"$brief"
	printf 'not the parent'\''s full context. Ask the parent if you need more.)_\n' >>"$brief"
else
	cat "$item_file" >>"$brief"
fi

brief_bytes="$(wc -c <"$brief" 2>/dev/null | tr -d ' ')"
[ -n "$brief_bytes" ] || brief_bytes=0

# ---------------------------------------------------------------------------
# Run it. The confinement goes first on PATH, the worktree is the cwd, and the
# brief is the child's stdin.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# The confinement is VERIFIED, not asserted. `confined=1` used to be a literal,
# so a checkout that never shipped the directory — `cp scripts/*.sh dest/` does
# not copy one — reported a confined child that had no confinement at all. It
# fails CLOSED: running a child unconfined is the outcome this criterion exists
# to prevent, so a missing shim refuses the child rather than proceeding.
# ---------------------------------------------------------------------------
if [ ! -d "$confine" ]; then
	reason="no-confinement"
	printf 'fanout-child-run: no confinement directory at %s; refusing to run an unconfined child\n' "$confine" >&2
	emit_and_exit "$REFUSED_EXIT"
fi
for _shim in gh glab switchyard-mcp switchyard-companion gc; do
	if [ ! -x "$confine/$_shim" ]; then
		reason="no-confinement"
		printf 'fanout-child-run: %s/%s is missing or not executable; refusing to run a partly confined child\n' \
			"$confine" "$_shim" >&2
		emit_and_exit "$REFUSED_EXIT"
	fi
done

: >>"$refusal_log" 2>/dev/null || {
	reason="no-refusal-log"
	printf 'fanout-child-run: cannot write the refusal log at %s\n' "$refusal_log" >&2
	emit_and_exit "$REFUSED_EXIT"
}

# The refusal count is a DELTA. The log is opened append-only and the documented
# default is a shared path, so a bare count reports every refusal the box has
# ever recorded — the third child of a fan-out would report refusals=3 having
# attempted nothing.
refusals_before="$(grep -c . "$refusal_log" 2>/dev/null)"
[ -n "$refusals_before" ] || refusals_before=0

confined=1

# ---------------------------------------------------------------------------
# The concurrency slot, taken LAST — after every refusal path, and immediately
# before the launch. Order matters in both directions: a child that is going to
# be refused for a wrong branch must not first occupy a slot a runnable sibling
# is waiting for, and a slot taken any earlier would be held across the
# preflight rather than across the work.
#
# This is where the cap becomes real. Resolving it and printing it would leave
# a number nothing obeys; the gate is here, in the one script the pack
# documents as "one invocation per child", so the cap binds whatever drives the
# fan-out — a serial loop, backgrounded jobs, or a future runner — without any
# of them having to know it exists.
# ---------------------------------------------------------------------------
slot_dir="$(sy_fanout_slot_dir "$wt")"
_acq="$(sy_fanout_slot_acquire "$slot_dir" "$cap")"
slot_state="${_acq#* }"
slot="${_acq%% *}"
if [ "$slot_state" = "overrun" ]; then
	printf 'fanout-child-run: waited out SY_FANOUT_SLOT_WAIT for one of %s slot(s) in %s; running %s anyway\n' \
		"$cap" "$slot_dir" "$bead" >&2
	printf '  Exceeding the cap briefly costs throughput; dropping the child would ship the criterion short.\n' >&2
fi

# The brief arrives on STDIN and its path in SY_FANOUT_BRIEF — it is NOT
# appended to the launcher's argv. The default launcher is `claude -p`, which
# takes its prompt from an argument when it gets one: passing the path there
# would make the child's whole prompt the string "/tmp/fanout-brief-sw-1.md",
# with nothing telling it to open the file, and stdin ignored. A launcher that
# wants the file reads SY_FANOUT_BRIEF.

# An empty config home for every credentialed client the child could reach. It
# is a real directory rather than /dev/null so a client that wants to WRITE its
# config finds somewhere to put it and still finds no token there.
empty_home="$work/no-creds"
mkdir -p "$empty_home" 2>/dev/null || :

# BOTH switchyard env spellings are emptied, and the PLURAL matters most:
# resolveToken() (cmd/switchyard-mcp/token_source.go) reads
# SWITCHYARD_API_TOKENS FIRST, and docs/mcp-auth-provisioning.md lists it as
# credential source #1 — ahead of the singular and of both token files this
# block redirects away. Emptying only the singular therefore withholds
# NOTHING on a rig provisioned the documented multi-workspace way: the child
# keeps a working credential, can take a cloud claim under the SHARED
# brakeman ref, and the next sibling brakeman is refused 409 by a WIP seat a
# child is sitting in (PRD #372, crit:6982797ca9ba).
#
# Keep every assignment on its own continued line with NO comment between
# them: a comment inside a backslash-continued command TERMINATES it, which
# silently drops the remaining assignments AND the launcher, and the harness
# still reports status=ok because `env` with no command exits 0.
#
# The child is recorded as `started` BEFORE it is launched, and that ordering is
# the point: a SIGKILLed harness runs no trap and reports nothing at all, so a
# ledger of failures alone could not tell that child from one that never ran.
# Recording the start makes "unfinished" derivable from the ABSENCE of a
# terminal record — a fact no dying process can suppress.
trace_record started launched
(
	cd "$wt" || exit 127
	exec env \
		PATH="$confine:$PATH" \
		GH_TOKEN= \
		GITHUB_TOKEN= \
		GH_CONFIG_DIR="$empty_home" \
		GITLAB_TOKEN= \
		GLAB_TOKEN= \
		SWITCHYARD_API_TOKENS= \
		SWITCHYARD_API_TOKEN= \
		SWITCHYARD_CONFIG_HOME="$empty_home" \
		SY_FANOUT_CHILD=1 \
		SY_FANOUT_BEAD="$bead" \
		SY_FANOUT_BRANCH="$branch" \
		SY_FANOUT_WORKTREE="$wt" \
		SY_FANOUT_BRIEF="$brief" \
		SY_FANOUT_REFUSAL_LOG="$refusal_log" \
		"$@" <"$brief"
)
child_rc=$?

refusals_after="$(grep -c . "$refusal_log" 2>/dev/null)"
[ -n "$refusals_after" ] || refusals_after=0
refusals=$((refusals_after - refusals_before))
[ "$refusals" -ge 0 ] || refusals=0

# ---------------------------------------------------------------------------
# "On the parent's branch" is checked AFTER the child too. `git` is not a
# credentialed operation and cannot be withheld, so a child can cut its own
# branch and commit there; checking only beforehand let that pass with the
# report still naming the parent's branch. It is worse than one lost child: the
# worktree is shared, so the NEXT sibling is refused wrong-branch and the whole
# remaining fan-out fails for a reason no line explains.
# ---------------------------------------------------------------------------
branch_after="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" || branch_after=""
if [ "$branch_after" != "$branch" ]; then
	status="failed"
	reason="branch-drift"
	printf 'fanout-child-run: child %s left %s on %s, not %s — the shared worktree is now wrong\n' \
		"$bead" "$wt" "${branch_after:-<detached>}" "$branch" >&2
	printf '  for every sibling still to run. Restore the branch before continuing the fan-out.\n' >&2
	emit_and_exit "$CHILD_FAILED_EXIT"
fi

if [ "$child_rc" -ne 0 ]; then
	status="failed"
	reason="child-failed"
	printf 'fanout-child-run: child %s exited %s\n' "$bead" "$child_rc" >&2
	emit_and_exit "$CHILD_FAILED_EXIT"
fi

status="ok"
reason="ok"
emit_and_exit 0
