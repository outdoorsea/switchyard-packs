#!/bin/sh
#
# fanout-lease.sh — hold the parent's cloud criterion lease for the whole of a
# fan-out, and guarantee that when the parent dies its children die with it
# while the bead goes back to the pool the ordinary way.
#
# switchyard PRD #372, crit:b88fa1dc2620.
#
# WHY A SHELL-SIDE KEEPER AND NOT THE SESSION'S OWN HEARTBEAT
#
# A brakeman normally heartbeats over MCP between turns. A fan-out removes that
# opportunity: the parent is blocked in ONE long tool call while its children
# build, and a blocked session sends nothing. The fan-out is therefore the
# longest quiet stretch a brakeman ever has, and the stretch where the lease is
# most likely to lapse unnoticed. So the lease is kept by a process that is not
# the session — this script, wrapped around the fan-out the way `sy_timeout`
# wraps a command.
#
# WHY lease_seconds IS SPELLED ON EVERY BEAT
#
# The bug runs the opposite way to intuition. In `internal/api/api_v1_beads.go`
# the heartbeat handler reads:
#
#     lease := defaultClaimLease          // 5 * time.Minute
#     if req.LeaseSeconds > 0 { lease = ...; if lease > maxClaimLease { ... } }
#
# So a claim taken at the one-hour cap and then heartbeated WITHOUT
# lease_seconds is not left alone — it is DOWNGRADED to five minutes, by the
# call sent to keep it alive. A bare beat is worse than no beat at all, and its
# damage shows up much later, as a 409 on some unrelated call, after another
# lane has already claimed the same criterion. Every beat this script sends
# carries the value; a non-numeric configuration falls back to the cap rather
# than to the empty string, because the empty string IS the downgrade.
#
# WHY THE REAPER OUTLIVES THE PARENT
#
# "A dead parent's children are reaped" cannot be done from the parent's own
# EXIT trap: SIGKILL runs no trap, and SIGKILL is what an OOM killer, a `kill
# -9` and a controller replacing a wedged session all send. Reaping is
# therefore owned by a SUPERVISOR in its own session, which polls the parent
# and, finding it gone, signals the child's whole process group. A grandchild
# matters as much as a child here: the real child is an LLM session that spawns
# compilers and test runners, and leaving those behind in the shared worktree
# corrupts the next fan-out rather than merely wasting a core.
#
# WHY THE DEATH PATH FILES NOTHING
#
# The criterion says the bead reclaims "exactly as an ordinary abandoned
# claim", and that is a requirement to do NOTHING special. The supervisor stops
# beating and exits; the lease expires; the pool's ordinary sweep takes the
# bead back. No bespoke call, no new endpoint, no protocol change — this PRD's
# done_means is that nothing about the cloud protocol changes.
#
# The subtle half is that the keeper MUST die with the parent. A keeper that
# survives is worse than one that never ran: it renews the only mutex
# switchyard has on behalf of a worker that no longer exists, so the bead never
# returns to the pool at all — and nothing anywhere reports it, because a
# heartbeated claim looks perfectly healthy from every dashboard.
#
# CONFIGURATION
#   SY_FANOUT_LEASE_SECONDS    lease length requested on every beat. Default
#                              3600, the server's cap; a larger value is
#                              clamped there, a non-numeric one falls back.
#   SY_FANOUT_HEARTBEAT_INTERVAL  seconds between beats. Default 900, matching
#                              the 15-minute floor the build workflow already
#                              documents. Clamped to a third of the lease so a
#                              missed beat still has two more chances.
#   SY_FANOUT_HEARTBEAT_CMD    command line that sends ONE beat. It is invoked
#                              with `--bead <id> --agent <ref> --lease-seconds
#                              <n>` appended, and the same three values in the
#                              environment as SY_FANOUT_BEAD, SY_FANOUT_AGENT
#                              and SY_FANOUT_LEASE_SECONDS. Unset uses the
#                              built-in API beat, which needs a tenant, a
#                              project and a token.
#   SY_FANOUT_REAP_GRACE       seconds between TERM and KILL when reaping.
#                              Default 5.
#   SY_FANOUT_LEASE_LOG        optional path; the report line is appended.
#
# USAGE
#   fanout-lease.sh --bead <id> --agent <ref> [--lease-seconds N] [--interval N]
#                   [--grace N] [--crit L] [--prd N]
#                   [--tenant T] [--project P] [--work-dir D]
#                   -- <command> [args...]
#
# Exit 0 when the fan-out command succeeded, its own status when it failed, 2
# on a usage fault, and 3 when the fan-out was REFUSED — which happens when no
# heartbeat can be sent at all. Refusing there is the safe direction: the
# parent's fallback is to build serially, where the session heartbeats over MCP
# itself, and running a fan-out with no keeper is precisely the silent
# lease-loss this script exists to prevent.

set -u

. "$(dirname "$0")/../lib/roster.sh"
sy_load_conf

LEASE_DEFAULT_SECONDS=3600
LEASE_DEFAULT_INTERVAL=900
LEASE_DEFAULT_GRACE=5
REFUSED_EXIT=3

usage() {
	cat >&2 <<'USAGE'
usage: fanout-lease.sh --bead <id> --agent <ref> [--lease-seconds N]
                      [--interval N] [--grace N] [--crit L] [--prd N]
                      [--tenant T] [--project P] [--work-dir D]
                      -- <command> [args...]
USAGE
	exit 2
}

bead=""
agent=""
lease=""
interval=""
grace=""
crit=""
prd=""
tenant=""
project=""
work_dir=""
have_cmd=0

while [ $# -gt 0 ]; do
	case "$1" in
	--bead) [ $# -ge 2 ] || usage; bead="$2"; shift 2 ;;
	--agent) [ $# -ge 2 ] || usage; agent="$2"; shift 2 ;;
	--lease-seconds) [ $# -ge 2 ] || usage; lease="$2"; shift 2 ;;
	--interval) [ $# -ge 2 ] || usage; interval="$2"; shift 2 ;;
	--grace) [ $# -ge 2 ] || usage; grace="$2"; shift 2 ;;
	--crit) [ $# -ge 2 ] || usage; crit="$2"; shift 2 ;;
	--prd) [ $# -ge 2 ] || usage; prd="$2"; shift 2 ;;
	--tenant) [ $# -ge 2 ] || usage; tenant="$2"; shift 2 ;;
	--work-dir) [ $# -ge 2 ] || usage; work_dir="$2"; shift 2 ;;
	--project) [ $# -ge 2 ] || usage; project="$2"; shift 2 ;;
	--) shift; have_cmd=1; break ;;
	-h | --help) usage ;;
	*)
		printf 'fanout-lease: unknown argument %s\n' "$1" >&2
		usage
		;;
	esac
done

[ -n "$bead" ] || usage
[ -n "$agent" ] || usage
[ "$have_cmd" -eq 1 ] || usage
[ $# -ge 1 ] || usage

# The two identity values are spliced into a JSON body and a URL path by the
# built-in beat, so their alphabets are checked HERE, once, before anything is
# started. An agent ref carrying a quote or backslash does not error — it makes
# every beat's body invalid JSON, the server 400s each one non-fatally, and the
# fan-out runs to completion having renewed nothing. A bead id outside the slug
# alphabet builds a URL path this script never meant to call (`..` normalizes).
case "$agent" in
*'"'* | *'\'*)
	printf 'fanout-lease: --agent %s contains a JSON metacharacter; refusing\n' "$agent" >&2
	exit 2
	;;
esac
case "$bead" in
'' | *[!A-Za-z0-9._-]* | *..* | .)
	printf 'fanout-lease: --bead %s is not a bead id; refusing\n' "$bead" >&2
	exit 2
	;;
esac

# ---------------------------------------------------------------------------
# Configuration, sanitised. A garbage knob behaves as the default rather than
# refusing to run, exactly as fanout-decompose.sh treats its threshold: this
# runs on someone else's box from a city config, and a typo must not take the
# builder lane down. The ONE value that is never allowed to degrade to empty is
# the lease, for the reason in the header.
#
# norm_num strips LEADING ZEROS, and that is not cosmetic. `0300` is all-digits
# so the pattern guard passes it, and then `$((0300 / 3))` is OCTAL in a POSIX
# shell — `0900` is not even a legal octal, and dash aborts the whole script on
# the arithmetic, before the traps exist and before any report line. `0300`
# survives as 64 (192/3) and then lands in the beat body as `lease_seconds:0300`
# — invalid JSON, so every beat 400s, non-fatally, for the length of the
# fan-out. Stripped with sed rather than arithmetic for exactly that octal
# reason, the same treatment conductor.sh gives its lease.
# ---------------------------------------------------------------------------
norm_num() { # VALUE DEFAULT — a base-10 integer on stdout, DEFAULT when not one
	_v="$1"
	case "$_v" in
	'' | *[!0-9]*)
		printf '%s' "$2"
		return 0
		;;
	esac
	_v="$(printf '%s' "$_v" | sed 's/^0*//')"
	[ -n "$_v" ] || _v=0
	printf '%s' "$_v"
}

[ -n "$lease" ] || lease="${SY_FANOUT_LEASE_SECONDS:-$LEASE_DEFAULT_SECONDS}"
lease="$(norm_num "$lease" "$LEASE_DEFAULT_SECONDS")"
[ "$lease" -gt 0 ] 2>/dev/null || lease="$LEASE_DEFAULT_SECONDS"
# The server clamps anything past its cap anyway. Clamping here too keeps the
# report honest: it states the lease the bead actually got, not the one asked
# for, so a fan-out sized against a two-hour lease is caught here rather than
# by its own expiry.
[ "$lease" -le "$LEASE_DEFAULT_SECONDS" ] || lease="$LEASE_DEFAULT_SECONDS"

[ -n "$interval" ] || interval="${SY_FANOUT_HEARTBEAT_INTERVAL:-$LEASE_DEFAULT_INTERVAL}"
interval="$(norm_num "$interval" "$LEASE_DEFAULT_INTERVAL")"
[ "$interval" -gt 0 ] 2>/dev/null || interval="$LEASE_DEFAULT_INTERVAL"

# An interval at or past the lease cannot renew in time BY CONSTRUCTION — the
# lease has already expired when the next beat comes due. A third of the lease
# leaves room for two missed beats, which is the difference between a slow box
# and a lost criterion. Clamped rather than refused, and reported either way:
# a silently corrected knob is a knob the operator never fixes.
interval_clamped=0
max_interval=$((lease / 3))
[ "$max_interval" -ge 1 ] || max_interval=1
if [ "$interval" -gt "$max_interval" ]; then
	interval="$max_interval"
	interval_clamped=1
fi

[ -n "$grace" ] || grace="${SY_FANOUT_REAP_GRACE:-$LEASE_DEFAULT_GRACE}"
grace="$(norm_num "$grace" "$LEASE_DEFAULT_GRACE")"

# The log path is configured in roster.conf, whose plain assignments are
# NON-exported shell variables — but the death-path log line is written by the
# SUPERVISOR, a separately-spawned process that only sees the environment. An
# unexported path would mean every normal fan-out logs and the SIGKILLed one —
# the record most worth having — silently does not.
[ -z "${SY_FANOUT_LEASE_LOG:-}" ] || export SY_FANOUT_LEASE_LOG

# A caller may name the work directory to keep it after the run, exactly as
# the child harness's --brief-out exists so a brief can be inspected. It is
# for debugging a beat that is being refused: the generated hook, the JSON it
# posts and the beat's own stderr all live here. The CREDENTIAL never survives
# either way — see the shred in the exit path.
if [ -n "$work_dir" ]; then
	mkdir -p "$work_dir" 2>/dev/null || {
		printf 'fanout-lease: cannot create the work directory %s\n' "$work_dir" >&2
		exit 2
	}
	work="$work_dir"
	keep_work=1
else
	work="$(mktemp -d "${TMPDIR:-/tmp}/fanout-lease.XXXXXX")" || {
		printf 'fanout-lease: cannot create a work directory\n' >&2
		exit 2
	}
	keep_work=0
fi
chmod 700 "$work" 2>/dev/null || :

status="refused"
reason=""
rc=0
reaped=0
reclaim="held"

# The report goes to STDERR, as the sibling harnesses' do: the fan-out command
# owns stdout, and a child that merely PRINTED a status line would otherwise be
# indistinguishable from this one. Parsers anchor on `^fanout-lease:`.
emit_and_exit() {
	_rc="$1"
	_beats=0
	_beats_failed=0
	[ -r "$work/beats" ] && _beats="$(cat "$work/beats" 2>/dev/null)"
	[ -r "$work/beats_failed" ] && _beats_failed="$(cat "$work/beats_failed" 2>/dev/null)"
	case "$_beats" in '' | *[!0-9]*) _beats=0 ;; esac
	case "$_beats_failed" in '' | *[!0-9]*) _beats_failed=0 ;; esac

	printf 'fanout-lease: bead=%s status=%s reason=%s lease_seconds=%s interval=%s interval_clamped=%s beats=%s beats_failed=%s reaped=%s reclaim=%s rc=%s\n' \
		"$bead" "$status" "${reason:--}" "$lease" "$interval" "$interval_clamped" \
		"$_beats" "$_beats_failed" "$reaped" "$reclaim" "$_rc" >&2

	if [ -n "${SY_FANOUT_LEASE_LOG:-}" ]; then
		printf '%s\tbead=%s\tstatus=%s\treason=%s\tlease_seconds=%s\tinterval=%s\tbeats=%s\tbeats_failed=%s\treaped=%s\treclaim=%s\trc=%s\tcrit=%s\n' \
			"$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)" \
			"$bead" "$status" "${reason:--}" "$lease" "$interval" "$_beats" \
			"$_beats_failed" "$reaped" "$reclaim" "$_rc" "${crit:--}" \
			>>"$SY_FANOUT_LEASE_LOG" 2>/dev/null || :
	fi
	exit "$_rc"
}

# ---------------------------------------------------------------------------
# The beat. A configured command line, or the built-in API call.
#
# The built-in is written out as a script rather than kept as a shell function
# because the supervisor is a separate process: one uniform "command line to
# run" covers both, so there is a single invocation path to audit. The token is
# read by the hook from a 0600 file and never appears in an argv — a bearer
# token on a command line is readable by every process on the box via `ps`.
# ---------------------------------------------------------------------------
hb_cmd="${SY_FANOUT_HEARTBEAT_CMD:-}"

if [ -z "$hb_cmd" ]; then
	[ -n "$tenant" ] || tenant="${SWITCHYARD_TENANT:-}"
	[ -n "$project" ] || project="${SWITCHYARD_PROJECT:-}"

	hb_token=""
	if [ -r "$(dirname "$0")/../lib/switchyard-api.sh" ]; then
		# Sourced only as a RESOLVER. That library is read-only by charter and
		# stays that way: the POST below lives here, not there.
		# shellcheck disable=SC1091
		. "$(dirname "$0")/../lib/switchyard-api.sh"
		hb_token="$(sy_api_token 2>/dev/null)" || hb_token=""
	fi

	if [ -n "$tenant" ] && [ -n "$project" ] && [ -n "$hb_token" ] &&
		command -v curl >/dev/null 2>&1; then
		(umask 077 && printf '%s' "$hb_token" >"$work/token") || :
		hb_base="$(sy_api_base 2>/dev/null)" || hb_base="https://switchyard.work"
		cat >"$work/hb-default" <<HBD
#!/bin/sh
# Built-in fan-out heartbeat: one lease renewal against the bead action
# endpoint. Generated by fanout-lease.sh; not a checked-in script.
set -u
_bead=""; _agent=""; _lease=""
while [ \$# -gt 0 ]; do
	case "\$1" in
	--bead) _bead="\$2"; shift 2 ;;
	--agent) _agent="\$2"; shift 2 ;;
	--lease-seconds) _lease="\$2"; shift 2 ;;
	*) shift ;;
	esac
done
# lease_seconds is ALWAYS in the body, and a beat that cannot carry one is NOT
# sent. Omitting it does not produce a request the server rejects — it produces
# a 200 that silently downgrades the lease to the five-minute default. A beat
# refused here is visible; a beat accepted without a lease is not.
case "\$_lease" in
'' | *[!0-9]*)
	printf 'fanout-lease: refusing to send a beat with no lease_seconds (got %s)\\n' \\
		"\${_lease:-<empty>}" >&2
	exit 2
	;;
esac
printf '{"action":"heartbeat","claimed_by":"%s","lease_seconds":%s}' \\
	"\$_agent" "\$_lease" >"$work/beat.json"
(umask 077 && printf 'header = "Authorization: Bearer %s"\n' \\
	"\$(cat "$work/token")" >"$work/curl.cfg")
curl -sS -f --max-time 20 --config "$work/curl.cfg" \\
	-H 'Content-Type: application/json' \\
	--data @"$work/beat.json" \\
	"$hb_base/api/v1/projects/$tenant/$project/beads/\$_bead/action" >/dev/null
HBD
		chmod 700 "$work/hb-default" 2>/dev/null || :
		hb_cmd="$work/hb-default"
	fi
fi

# The heartbeat command line is NEVER split at this scope. `"$@"` holds the
# fan-out command from here to the end of the script, and a bare `set --
# $hb_cmd` would silently replace it with the hook's words — the fan-out would
# then "succeed" having run the heartbeat twice and the actual work not at all.
# Every place that needs the split does it inside a FUNCTION, whose positional
# parameters are its own and are restored on return.
hb_first="${hb_cmd%%[! 	]*}"
hb_first="${hb_cmd#"$hb_first"}"
hb_first="${hb_first%%[ 	]*}"

if [ -z "$hb_first" ] || ! command -v "$hb_first" >/dev/null 2>&1; then
	rm -f "$work/token" "$work/curl.cfg" 2>/dev/null || :
	[ "$keep_work" -eq 1 ] || rm -rf "$work"
	reason="no-heartbeat"
	printf 'fanout-lease: no heartbeat is possible — %s\n' \
		"${hb_cmd:-no SY_FANOUT_HEARTBEAT_CMD, and no tenant/project/token for the built-in}" >&2
	printf '  Refusing the fan-out rather than running one whose lease cannot be renewed.\n' >&2
	printf '  Build this criterion serially: the session heartbeats over MCP itself there.\n' >&2
	emit_and_exit "$REFUSED_EXIT"
fi

# ---------------------------------------------------------------------------
# Detach primitive. macOS ships no setsid; every host that lacks it has perl.
# The same pair, and the same reasoning, as sy_timeout in lib/roster.sh: a new
# session makes the fan-out's whole subtree killable as ONE group, and keeps
# the supervisor out of the group it has to signal.
# ---------------------------------------------------------------------------
if command -v setsid >/dev/null 2>&1; then
	detach_impl=setsid
elif command -v perl >/dev/null 2>&1; then
	detach_impl=perl
else
	rm -f "$work/token" "$work/curl.cfg" 2>/dev/null || :
	[ "$keep_work" -eq 1 ] || rm -rf "$work"
	reason="no-detach"
	printf 'fanout-lease: this host has neither setsid nor perl, so a fan-out subtree\n' >&2
	printf '  cannot be made reapable. Refusing rather than leaking children on a dead parent.\n' >&2
	emit_and_exit "$REFUSED_EXIT"
fi

printf '0' >"$work/beats"
printf '0' >"$work/beats_failed"

# ---------------------------------------------------------------------------
# The supervisor: one detached process, two cadences.
#
# It ticks every second — fast, because a reap that waited out the heartbeat
# interval would leave a dead parent's compilers running for a quarter of an
# hour inside a shared worktree — and beats only once the interval has elapsed.
# One process rather than two, because both jobs key on the single fact of
# whether the parent is still alive.
# ---------------------------------------------------------------------------
cat >"$work/supervise" <<'SUPEOF'
#!/bin/sh
set -u
parent="$1"; work="$2"; interval="$3"; grace="$4"
bead="$5"; agent="$6"; lease="$7"; keep_work="$8"; orig_ppid="$9"
shift 9

# A closed or broken stderr must never cost the reap. The parent's stderr is a
# pipe under a session harness, and a pipe outlives its reader by exactly one
# signal — so SIGPIPE is ignored here, and every announcement in the death
# branch below is made only AFTER the group has actually been signalled.
trap '' PIPE 2>/dev/null || :

bump() {
	_f="$work/$1"
	_n="$(cat "$_f" 2>/dev/null)"
	case "$_n" in '' | *[!0-9]*) _n=0 ;; esac
	printf '%s' "$((_n + 1))" >"$_f" 2>/dev/null || :
}

beat() {
	# lease_seconds on EVERY call, never conditionally. The flags are appended
	# AND the same values exported, so a hook may read whichever it prefers.
	if SY_FANOUT_BEAD="$bead" SY_FANOUT_AGENT="$agent" \
		SY_FANOUT_LEASE_SECONDS="$lease" \
		"$@" --bead "$bead" --agent "$agent" --lease-seconds "$lease" \
		>/dev/null 2>>"$work/beat.err"; then
		bump beats
	else
		# A refused beat is BOOKKEEPING, not a verdict on the build: a 409 means
		# the lease was already swept, and the parent still has to finish and
		# publish what it built. Counted and reported; never fatal.
		bump beats
		bump beats_failed
	fi
}

# The opening beat is sent by the parent before the child starts, so the first
# sleep here is a full interval.
elapsed=0
while :; do
	sleep 1
	if [ -e "$work/stop" ]; then
		exit 0
	fi

	# Liveness by polling, which cannot distinguish a dead parent from a reused
	# pid. Over a fan-out that is a narrow window on a busy box, and erring
	# toward "still alive" only delays a reap — but it is a real limit of this
	# approach, not an oversight.
	#
	# TWO death signals, not one. The keeper's liveness key is the WRAPPER's pid
	# — but the wrapper is one level below the brakeman session, and a controller
	# SIGKILLing the session by pid leaves the wrapper alive, reparented to init,
	# still blocked in `wait`. Polling the wrapper alone then renews the mutex
	# for a worker whose session no longer exists — the exact keeper-outlives-
	# parent hazard the header forbids, moved one level up the tree. So a wrapper
	# whose OWN parent has become init (when it did not start that way) is
	# treated as dead too: the fan-out's owner is gone, and nobody is left to
	# integrate or publish what the children build.
	dead=""
	if ! kill -0 "$parent" 2>/dev/null; then
		dead="parent-died"
	elif [ "$orig_ppid" != "1" ] && [ -n "$orig_ppid" ]; then
		cur_ppid="$(ps -o ppid= -p "$parent" 2>/dev/null | tr -d '[:space:]')"
		[ "$cur_ppid" = "1" ] && dead="parent-orphaned"
	fi
	if [ -n "$dead" ]; then
		# The parent is gone. Reap the subtree, say so where an operator can
		# find it, and STOP BEATING. Nothing is filed against the bead: it
		# reclaims by lease expiry, exactly as any other abandoned claim does.
		#
		# The REASON is announced BEFORE the reap, and the ordering is
		# load-bearing on the orphan path: the reap's first TERM unblocks a
		# still-living wrapper's `wait`, whose exit trap TERMs this supervisor —
		# an announcement after the reap loses that race often enough to be
		# missing from real logs. Announcing first is safe because PIPE is
		# ignored above: a dead stderr makes the printf fail, never this process.
		pgid="$(cat "$work/child.pgid" 2>/dev/null)"
		case "$pgid" in '' | *[!0-9]*) pgid="" ;; esac
		printf 'fanout-lease: parent %s gone (%s); reaping the fan-out subtree (pgid %s).\n' \
			"$parent" "$dead" "${pgid:-none}" >&2
		_reaped=0
		if [ -n "$pgid" ] && kill -0 "-$pgid" 2>/dev/null; then
			kill -TERM "-$pgid" 2>/dev/null
			_g=0
			while [ "$_g" -lt "$grace" ]; do
				kill -0 "-$pgid" 2>/dev/null || break
				sleep 1
				_g=$((_g + 1))
			done
			kill -KILL "-$pgid" 2>/dev/null
			_reaped=1
		fi
		printf '  The lease is no longer renewed, so the pool reclaims this bead on its\n' >&2
		printf '  ordinary expiry sweep. Nothing was filed against it.\n' >&2
		# The SAME keyed line every other path emits. A death that only printed
		# prose would be the one outcome most worth finding — a fan-out that
		# stopped without publishing — and the only one a parser anchored on
		# `status=` could not see.
		_b="$(cat "$work/beats" 2>/dev/null)"
		_bf="$(cat "$work/beats_failed" 2>/dev/null)"
		case "$_b" in '' | *[!0-9]*) _b=0 ;; esac
		case "$_bf" in '' | *[!0-9]*) _bf=0 ;; esac
		printf 'fanout-lease: bead=%s status=reaped reason=%s lease_seconds=%s interval=%s interval_clamped=- beats=%s beats_failed=%s reaped=%s reclaim=lease-expiry rc=-\n' \
			"$bead" "$dead" "$lease" "$interval" "$_b" "$_bf" "$_reaped" >&2
		if [ -n "${SY_FANOUT_LEASE_LOG:-}" ]; then
			printf '%s\tbead=%s\tstatus=reaped\treason=%s\tlease_seconds=%s\tinterval=%s\tbeats=%s\tbeats_failed=%s\treaped=%s\treclaim=lease-expiry\trc=-\n' \
				"$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)" \
				"$bead" "$dead" "$lease" "$interval" "$_b" "$_bf" "$_reaped" \
				>>"$SY_FANOUT_LEASE_LOG" 2>/dev/null || :
		fi
		# The CREDENTIAL is always shredded — a token left in a debugging
		# directory is a token nobody remembers is there. The directory itself is
		# removed only when this script created it: an operator-named --work-dir
		# is the one place the beat evidence survives a death, and the death path
		# is precisely when that evidence is most worth reading.
		rm -f "$work/token" "$work/curl.cfg" 2>/dev/null || :
		[ "$keep_work" = "1" ] || rm -rf "$work" 2>/dev/null || :
		exit 0
	fi

	elapsed=$((elapsed + 1))
	if [ "$elapsed" -ge "$interval" ]; then
		beat "$@"
		elapsed=0
	fi
done
SUPEOF
chmod 700 "$work/supervise" 2>/dev/null || :

# ---------------------------------------------------------------------------
# The three places that need the hook's words, each splitting inside its own
# function so `"$@"` — the fan-out command — is never disturbed.
# ---------------------------------------------------------------------------
open_beat() {
	set -f
	# shellcheck disable=SC2086
	set -- $hb_cmd --bead "$bead" --agent "$agent" --lease-seconds "$lease"
	set +f
	SY_FANOUT_BEAD="$bead" SY_FANOUT_AGENT="$agent" SY_FANOUT_LEASE_SECONDS="$lease" \
		"$@" >/dev/null 2>>"$work/beat.err"
}

start_supervisor() {
	# The wrapper's own parent at start time, so the supervisor can tell "this
	# wrapper was orphaned by its session dying" apart from "it started under
	# init legitimately". Best-effort: an unreadable ppid disables only the
	# orphan check, never the pid-liveness one.
	orig_ppid="$(ps -o ppid= -p "$$" 2>/dev/null | tr -d '[:space:]')"
	case "$orig_ppid" in '' | *[!0-9]*) orig_ppid=1 ;; esac
	set -f
	# shellcheck disable=SC2086
	set -- "$work/supervise" "$$" "$work" "$interval" "$grace" \
		"$bead" "$agent" "$lease" "$keep_work" "$orig_ppid" $hb_cmd
	set +f
	# Its OWN session, so that signalling the child's process group — or the
	# parent's — cannot take out the process responsible for the reaping.
	if [ "$detach_impl" = setsid ]; then
		setsid sh "$@" &
	else
		perl -MPOSIX -e 'POSIX::setsid() >= 0 or exit 126; exec("/bin/sh", @ARGV); exit 127' \
			-- "$@" &
	fi
	sup_pid=$!
}

start_child() {
	# The new group leader prints its OWN pgid. Reading `$!` would be an
	# assumption — setsid forks when it is already a group leader — and a wrong
	# pgid here means the reap signals a group that is not the fan-out's.
	if [ "$detach_impl" = setsid ]; then
		setsid sh -c 'printf %s "$$" >"$1"; shift; exec "$@"' sh "$work/child.pgid" "$@" &
	else
		perl -MPOSIX -e 'POSIX::setsid() >= 0 or exit 126;
			my $f = shift @ARGV;
			if (open(my $h, ">", $f)) { print $h $$; close $h; }
			exec @ARGV; exit 127' -- "$work/child.pgid" "$@" &
	fi
	child_pid=$!
}

# reap_subtree — signal the fan-out's process group, TERM then KILL. Used on
# every exit path the parent itself controls; the supervisor owns the path the
# parent does not survive.
#
# The pgid is written by the DETACHED child inside its new session, so there is
# a window — start_child has forked, the file is not yet written — in which a
# signal would otherwise find an empty file, return 0, and leak the whole
# subtree with the supervisor already stopped. So when a child was started but
# no pgid is readable yet, this waits briefly for the write, and failing that
# falls back to signalling the spawned pid directly: cruder than the group, but
# a TERM to the session leader beats abandoning its session entirely.
reap_subtree() {
	_pgid="$(cat "$work/child.pgid" 2>/dev/null)"
	case "$_pgid" in '' | *[!0-9]*) _pgid="" ;; esac
	if [ -z "$_pgid" ] && [ -n "${child_pid:-}" ]; then
		_w=0
		while [ "$_w" -lt 3 ]; do
			sleep 1
			_w=$((_w + 1))
			_pgid="$(cat "$work/child.pgid" 2>/dev/null)"
			case "$_pgid" in '' | *[!0-9]*) _pgid="" ;; esac
			[ -n "$_pgid" ] && break
		done
		if [ -z "$_pgid" ]; then
			kill -TERM "$child_pid" 2>/dev/null && reaped=1
			sleep "$grace" 2>/dev/null || :
			kill -KILL "$child_pid" 2>/dev/null || :
			return 0
		fi
	fi
	[ -n "$_pgid" ] || return 0
	kill -0 "-$_pgid" 2>/dev/null || return 0
	kill -TERM "-$_pgid" 2>/dev/null
	_g=0
	while [ "$_g" -lt "$grace" ]; do
		kill -0 "-$_pgid" 2>/dev/null || break
		sleep 1
		_g=$((_g + 1))
	done
	kill -KILL "-$_pgid" 2>/dev/null
	reaped=1
	return 0
}

stop_supervisor() {
	: >"$work/stop" 2>/dev/null || :
	[ -n "${sup_pid:-}" ] || return 0
	kill -TERM "$sup_pid" 2>/dev/null || :
	wait "$sup_pid" 2>/dev/null || :
}

# Signal exits carry non-success codes (130/143, the shell's signal-exit
# convention) rather than falling through a bare handler to 0: a controller
# terminating this fan-out must never record it as a clean success, or the
# criterion would read as built. The handlers reap FIRST and stop the
# supervisor second, so the one process able to catch a missed reap is still
# standing while the reap happens.
sup_pid=""
child_pid=""
# The token and the header file it is written into are removed on EVERY exit,
# including the one that keeps the work directory: a credential left behind in
# a debugging directory is a credential nobody remembers is there.
cleanup_work() {
	rm -f "$work/token" "$work/curl.cfg" 2>/dev/null || :
	[ "$keep_work" -eq 1 ] || rm -rf "$work"
}
trap 'reap_subtree; stop_supervisor; cleanup_work' EXIT
trap 'reap_subtree; stop_supervisor; status=failed; reason=interrupted; reclaim=lease-expiry; emit_and_exit 130' INT
trap 'reap_subtree; stop_supervisor; status=failed; reason=terminated; reclaim=lease-expiry; emit_and_exit 143' TERM

# The opening beat, BEFORE the fan-out starts. A keeper whose first beat waits
# out an interval leaves the opening stretch uncovered — and that stretch is
# where a claim taken some minutes ago is already closest to expiry.
#
# ...and a FAILED opening beat, retried once, REFUSES the fan-out. This beat
# runs before any child exists, so its failure is free to act on — and it is
# the deterministic failures (revoked token, wrong tenant/project, a mangled
# lease) that fail here, the ones under which every later beat fails the same
# way. Proceeding would run the whole fan-out with a keeper that renews
# nothing: exactly the silent lease-loss the header promises this script
# prevents. A single transient blip is absorbed by the retry; a persistent
# failure folds the parent back to serial, where the session heartbeats over
# MCP itself. Mid-run failures stay counted-not-fatal — by then the work is
# running and a 409 there means the lease is already lost, not losable.
if open_beat; then
	printf '1' >"$work/beats"
else
	sleep 5
	if open_beat; then
		printf '2' >"$work/beats"
		printf '1' >"$work/beats_failed"
	else
		printf '2' >"$work/beats"
		printf '2' >"$work/beats_failed"
		reason="heartbeat-failed"
		printf 'fanout-lease: the opening beat failed twice. Last error:\n' >&2
		# Inlined, because the temp work directory is removed on exit — pointing
		# at a file the next statement deletes would be no evidence at all.
		tail -3 "$work/beat.err" 2>/dev/null | sed 's/^/    /' >&2 || :
		printf '  Refusing the fan-out rather than running one whose lease cannot be renewed.\n' >&2
		printf '  Build this criterion serially: the session heartbeats over MCP itself there.\n' >&2
		emit_and_exit "$REFUSED_EXIT"
	fi
fi

start_supervisor
start_child "$@"

wait "$child_pid" 2>/dev/null
rc=$?

stop_supervisor
# Stragglers: the fan-out command may have exited while a child of its own is
# still running in the group. Leaving those behind in the shared worktree is
# how the NEXT fan-out inherits a dirty tree it did not create.
reap_subtree

if [ "$rc" -eq 0 ]; then
	status="ok"
	reason="ok"
else
	status="failed"
	reason="fanout-failed"
fi
emit_and_exit "$rc"
