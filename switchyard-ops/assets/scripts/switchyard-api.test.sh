#!/bin/sh
# switchyard-api.test.sh — hermetic tests for sy_project_for_rig's two-layer
# rig-to-project resolution. No network, no city, no gc.
#
# The fixture is REAL shape, taken from a live `GET /api/v1/projects`: `forge` is
# the project a rig named `switchyard-forge` drives (the names differ, which is
# the whole reason RIG_PROJECTS exists), `switchyard` is the rig whose name does
# equal its slug, and `ideapop` is genuinely duplicated across two tenants.
#
# EVERY STATE IS EXERCISED IN BOTH FIXTURE STATES. State A must reproduce the
# original fault — a green suite that never ran the unmapped path would not show
# that the default behaviour is unchanged, which is the property that lets this
# ship without a roster.conf on every other city.
set -u

. "$(dirname "$0")/../lib/switchyard-api.sh"

P='{"projects":[
  {"id":25,"name":"Switchyard Forge","slug":"forge","tenant_slug":"software-factory"},
  {"id":2,"name":"Switchyard","slug":"switchyard","tenant_slug":"software-factory"},
  {"id":18,"name":"Ideapop!","slug":"ideapop","tenant_slug":"software-factory"},
  {"id":3,"name":"Ideapop!","slug":"ideapop","tenant_slug":"adequate-fit"}
]}'

RC=0
check() { # LABEL EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then printf 'ok       %s\n' "$1"
  else printf 'NOT OK   %s — expected [%s] got [%s]\n' "$1" "$2" "$3"; RC=1; fi
}

# --- A: no RIG_PROJECTS. Behaviour must be byte-identical to the slug-only era.
RIG_PROJECTS=""
check "unmapped: differing names do not match"   ""                            "$(sy_project_for_rig switchyard-forge "$P")"
check "unmapped: equal name binds by slug"       "software-factory/switchyard" "$(sy_project_for_rig switchyard "$P")"
check "unmapped: ambiguous slug is not-found"    ""                            "$(sy_project_for_rig ideapop "$P")"
check "unmapped: unreadable list is empty"       ""                            "$(sy_project_for_rig switchyard "")"

# --- B: declared bindings.
RIG_PROJECTS="switchyard-forge=software-factory/forge ideapop=adequate-fit/ideapop"
check "mapped: differing names resolve"          "software-factory/forge"      "$(sy_project_for_rig switchyard-forge "$P")"
check "mapped: ambiguity resolved by tenant"     "adequate-fit/ideapop"        "$(sy_project_for_rig ideapop "$P")"
check "mapped: unnamed rig still uses slug"      "software-factory/switchyard" "$(sy_project_for_rig switchyard "$P")"
check "mapped: unreadable list still empty"      ""                            "$(sy_project_for_rig switchyard-forge "")"

# --- C: declared but unreachable => rc=3, no output, and NO slug rescue.
RIG_PROJECTS="switchyard-forge=software-factory/typo"
out="$(sy_project_for_rig switchyard-forge "$P")"; rc=$?
check "bad binding: signals rc=3"                "3"                           "$rc"
check "bad binding: emits nothing"               ""                            "$out"

# The rig below WOULD resolve by slug. A wrong binding must not be quietly
# rescued by that coincidence — the operator named a target and it is wrong.
RIG_PROJECTS="switchyard=software-factory/typo"
out="$(sy_project_for_rig switchyard "$P")"; rc=$?
check "bad binding: no rescue by valid slug"     "3"                           "$rc"
check "bad binding: no rescue, emits nothing"    ""                            "$out"

# --- D: a rig name that is a prefix of another must not capture it.
RIG_PROJECTS="switchyard=software-factory/switchyard"
check "no prefix bleed between rig names"        ""                            "$(sy_project_for_rig switchyard-forge "$P")"

[ "$RC" -eq 0 ] && printf 'switchyard-api.test.sh: all checks passed\n'
exit "$RC"
