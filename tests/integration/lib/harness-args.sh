# shellcheck shell=bash
# --harness-arg: bench-ci#46 forwards a hand-picked run.sh phase selection this way. Allowlisted
# ONLY — never built into a shell string from the raw value (#2179) — and refused up front, before
# any bench work, exactly like the --scenario mode restriction next to its call site: --mode check
# runs nothing but --check, so a destructive addition here would join a run the mode promises never
# touches anything.
validate_harness_args() { # reads HARNESS_ARGS[]; sets HARNESS_PHASE_ARGS, HARNESS_SSH_FAULT
    HARNESS_PHASE_ARGS=""
    HARNESS_SSH_FAULT=0
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
        # #2000: drive the fault-injection phase itself over SSH (rx()'s ssh branch, lib.sh) instead
        # of the detached runner's usual --local, proving the remote quoting the phase relies on.
        # Translated to the plain --fault-injection run.sh flag; HARNESS_SSH_FAULT is what switches
        # the detached runner's transport, not run.sh's own flag surface.
        --fault-injection-ssh)
            HARNESS_PHASE_ARGS="$HARNESS_PHASE_ARGS --fault-injection"
            # shellcheck disable=SC2034 # read by e2e.sh's run_harness, not in this file
            HARNESS_SSH_FAULT=1
            i=$((i + 1))
            ;;
        --scenario)
            next="${HARNESS_ARGS[$((i + 1))]:-}"
            [[ "$next" =~ ^[a-z0-9-]+$ ]] || die "--harness-arg --scenario needs a name matching ^[a-z0-9-]+\$ as the NEXT --harness-arg (got '$next')."
            HARNESS_PHASE_ARGS="$HARNESS_PHASE_ARGS --scenario $(quote_arg "$next")"
            i=$((i + 2))
            ;;
        *)
            die "--harness-arg does not accept '$arg' — allowed: --lifecycle, --fault-injection, --fault-injection-ssh, --auth-fail-closed, --hardening, --subnet, --safety-backup, --rigforge, --rigforge-control, --xvb-routing-smoke, --scenario <name>."
            ;;
        esac
    done
}
