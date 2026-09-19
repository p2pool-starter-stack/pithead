# shellcheck shell=bash
# --harness-arg: bench-ci#46 forwards a hand-picked run.sh phase selection this way. Allowlisted
# ONLY — never built into a shell string from the raw value (#2179) — and refused up front, before
# any bench work, exactly like the --scenario mode restriction next to its call site: --mode check
# runs nothing but --check, so a destructive addition here would join a run the mode promises never
# touches anything.
validate_harness_args() { # reads HARNESS_ARGS[]; sets HARNESS_PHASE_ARGS
    HARNESS_PHASE_ARGS=""
    [ "${#HARNESS_ARGS[@]}" -eq 0 ] && return 0
    [ "$MODE" != "check" ] || die "--harness-arg is not supported with --mode check."
    local i=0 arg next
    while [ "$i" -lt "${#HARNESS_ARGS[@]}" ]; do
        arg="${HARNESS_ARGS[$i]}"
        case "$arg" in
        --lifecycle | --fault-injection | --auth-fail-closed | --hardening | --subnet | --safety-backup | --rigforge | --rigforge-control | --xvb-routing-smoke)
            HARNESS_PHASE_ARGS="$HARNESS_PHASE_ARGS $arg"
            i=$((i + 1))
            ;;
        --scenario)
            next="${HARNESS_ARGS[$((i + 1))]:-}"
            [[ "$next" =~ ^[a-z0-9-]+$ ]] || die "--harness-arg --scenario needs a name matching ^[a-z0-9-]+\$ as the NEXT --harness-arg (got '$next')."
            HARNESS_PHASE_ARGS="$HARNESS_PHASE_ARGS --scenario $(quote_arg "$next")"
            i=$((i + 2))
            ;;
        *)
            die "--harness-arg does not accept '$arg' — allowed: --lifecycle, --fault-injection, --auth-fail-closed, --hardening, --subnet, --safety-backup, --rigforge, --rigforge-control, --xvb-routing-smoke, --scenario <name>."
            ;;
        esac
    done
}
