#!/usr/bin/env bash
#
# Pithead end-to-end integration test runner (issue #54).
#
# Drives a REAL, already-provisioned Pithead server through the config matrix and asserts the
# stack behaves — containers healthy, nodes synced, miners mining, the dashboard reading the
# right live state, status exit codes correct, and secrets preserved across re-applies.
#
# The box is assumed already deployed and synced with miners connected; the harness moves
# between scenarios with non-interactive `pithead apply -y` (recreates only changed
# containers, reuses the synced chain data dirs — never re-syncs, never re-provisions Tor).
# It saves the box's original config.json up front and restores it at the end.
#
#   ./run.sh --host user@1.2.3.4 [--dir ~/pithead] [options]
#   ./run.sh --local             [--dir /path/to/stack] [options]
#
# Read-only against the canonical chain data dirs; safe to run against the live box. See
# docs/dev/integration-testing.md for provisioning, the safety model, and CI/release wiring.
#
set -uo pipefail # NOT -e: we deliberately continue-on-error to collect the whole matrix.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh" || exit $?
# shellcheck source=tests/integration/scenarios.sh
source "$HERE/scenarios.sh" || exit $?
source "$HERE/lib/rigforge-apply-settle.sh" || exit $?
# shellcheck source=tests/integration/lib/rig-key-ledger.sh
source "$HERE/lib/rig-key-ledger.sh" || exit $? # must precede any module that marks a write (#1379)
# shellcheck source=tests/integration/lib/rigforge-writable-keys.sh
source "$HERE/lib/rigforge-writable-keys.sh" || exit $?
# shellcheck source=tests/integration/lib/rigforge-upgrade.sh
source "$HERE/lib/rigforge-upgrade.sh" || exit $?
# shellcheck source=tests/integration/lib/borrow-rearm.sh
source "$HERE/lib/borrow-rearm.sh" || exit $?
# shellcheck source=tests/integration/lib/zmq-probe.sh
source "$HERE/lib/zmq-probe.sh" || exit $?
# shellcheck source=tests/integration/lib/mergemine-probe.sh
source "$HERE/lib/mergemine-probe.sh" || exit $?

# --- Defaults / globals -----------------------------------------------------
IT_MODE="ssh"
IT_SSH_DEST=""
IT_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
IT_REMOTE_DIR="pithead"
IT_PITHEAD="./pithead"
IT_CURRENT_SCENARIO=""
ONLY_SCENARIO=""
CHECK_ONLY=0
READINESS=0
RUN_LIFECYCLE=0
RUN_FAULTS=0
RUN_AUTH_FAIL_CLOSED=0
RUN_HARDENING=0
RUN_RIGFORGE=0
RUN_RIGFORGE_CONTROL=0
RUN_SUBNET=0
RUN_IMAGE_UPGRADE=0
IMAGE_UPGRADE_FROM_SHA=""
IMAGE_UPGRADE_TO_SHA=""
RUN_XVB_ROUTING=0
RIG_HOST=""
RIG_NAME=""
RIGFORGE_BOOTSTRAP_VERSION=""
RIG_CONTROL_PORT="8082"
SAFETY_BACKUP=0
SAFETY_ARCHIVE=""
SAFETY_RESTORE_FAILED=0
_SAFETY_RESTORE_ARMED=0
_SAFETY_FOREIGN_TRAP=""
KEEP_STATE=0
EXPECTED_WORKERS=2
SKIP_MINING_ASSERTS=0
REMOTE_MONERO_HOST=""
REMOTE_MONERO_RPC_PORT=""
REMOTE_MONERO_ZMQ_PORT=""
REMOTE_TARI_HOST=""
PRUNED_DATA_DIR=""
FULL_DATA_DIR=""
OUT_DIR="$HERE/results"
BASELINE_CONFIG=""
BASELINE_PRUNE=""
BASELINE_SECRET_FP=""
BASELINE_EXACT_SECRET_FP=""

INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-cli.sh
source "$HERE/lib/run-cli.sh" || exit $?
# shellcheck source=tests/integration/lib/run-matrix.sh
source "$HERE/lib/run-matrix.sh" || exit $?
# shellcheck source=tests/integration/lib/run-state.sh
source "$HERE/lib/run-state.sh" || exit $?
# shellcheck source=tests/integration/lib/run-scenario.sh
source "$HERE/lib/run-scenario.sh" || exit $?
# shellcheck source=tests/integration/lib/run-lifecycle.sh
source "$HERE/lib/run-lifecycle.sh" || exit $?
# shellcheck source=tests/integration/lib/run-faults.sh
source "$HERE/lib/run-faults.sh" || exit $?
# shellcheck source=tests/integration/lib/run-hardening.sh
source "$HERE/lib/run-hardening.sh" || exit $?
# shellcheck source=tests/integration/lib/run-safety.sh
source "$HERE/lib/run-safety.sh" || exit $?
# shellcheck source=tests/integration/lib/run-rigforge.sh
source "$HERE/lib/run-rigforge.sh" || exit $?
# shellcheck source=tests/integration/lib/run-rig-control.sh
source "$HERE/lib/run-rig-control.sh" || exit $?
# shellcheck source=tests/integration/lib/run-rig-reverse.sh
source "$HERE/lib/run-rig-reverse.sh" || exit $?
# shellcheck source=tests/integration/lib/live-gates.sh
source "$HERE/lib/live-gates.sh" || exit $?
# --- Main -------------------------------------------------------------------

main() {
    parse_args "$@"

    # Bench coordination (#430): take the shared-rig flock ON THE TARGET before the first
    # service/API-touching action (preflight already reads the box), and hold it for the whole
    # run — rigforge's gates and pithead runs on the same box refuse (exit 75, holder named)
    # instead of colliding. Read-only modes take a SHARED lock so concurrent readers coexist;
    # everything else mutates the stack, so it takes the EXCLUSIVE one. RIG_LOCK_WAIT=1 queues
    # instead of failing. In --host mode the lock is held on the remote via a long-lived ssh
    # that dies with this process (see lib.sh:rig_lock_remote).
    local lock_suite="run.sh matrix" lock_shared=""
    if [ "$READINESS" = "1" ]; then
        lock_suite="run.sh --readiness" lock_shared="shared"
    elif [ "$CHECK_ONLY" = "1" ]; then
        lock_suite="run.sh --check" lock_shared="shared"
    fi
    if [ -n "${RIG_LOCK_PARENT_ACTOR:-}" ] || [ -n "${RIG_LOCK_PARENT_NONCE:-}" ]; then
        rig_lock_parent_use || exit 1
    elif [ "$IT_MODE" = "local" ]; then
        rig_lock pithead "$lock_suite" "$lock_shared"
    else
        rig_lock_remote pithead "$lock_suite" "$lock_shared" "$IT_SSH_DEST" "${IT_SSH_OPTS[@]}"
    fi

    preflight

    # Non-destructive release-server fitness assessment.
    if [ "$READINESS" = "1" ]; then
        assert_release_readiness
        summary
        return
    fi

    # Non-destructive health check: assert the current live state and stop.
    if [ "$CHECK_ONLY" = "1" ]; then
        assert_current_state
        summary
        return
    fi

    # Optional rollback net for the destructive phases that follow.
    if ! safety_backup; then
        summary
        return
    fi
    [ -z "$SAFETY_ARCHIVE" ] || arm_safety_abort_restore

    # Upgrade first: old images are still running when the harness starts, and every later phase
    # then exercises the declared candidate image set. Do not mutate further after a failed
    # upgrade/provenance check; go straight through the existing rollback/restore path.
    if [ "$RUN_IMAGE_UPGRADE" = "1" ]; then
        local upgrade_fails_before="$IT_FAIL"
        run_image_upgrade
        if [ "$IT_FAIL" -gt "$upgrade_fails_before" ]; then
            if [ "$_UPGRADE_RESTORE_ARMED" = "1" ]; then
                restore_upgrade_baseline
            else
                safety_rollback_if_failed
                restore_baseline
            fi
            [ "$SAFETY_RESTORE_FAILED" = 0 ] && _SAFETY_RESTORE_ARMED=0
            safety_cleanup
            summary
            return
        fi
    fi

    local name rest
    if [ -n "$ONLY_SCENARIO" ]; then
        rest="$(scenario_overrides "$ONLY_SCENARIO")" || {
            it_err "Unknown scenario: $ONLY_SCENARIO"
            exit 2
        }
        run_scenario "$ONLY_SCENARIO" "$rest"
    else
        while IFS=$'\t' read -r name rest; do
            [ -z "$name" ] && continue
            # </dev/null: never let a child (ssh inside run_scenario) drain the loop's stdin and
            # silently skip the remaining scenarios. rx already uses `ssh -n`; this is belt-and-suspenders.
            run_scenario "$name" "$rest" </dev/null
        done < <(scenario_matrix)
    fi

    local rig_control_ok=1
    if [ "$RUN_RIGFORGE_CONTROL" = "1" ]; then
        run_rigforge_control || rig_control_ok=0
        [ "$rig_control_ok" = 1 ] && wait_borrow_rearm || rig_control_ok=0
    elif [ "$RUN_RIGFORGE" = "1" ]; then
        run_rigforge_integration
    fi
    [ "$rig_control_ok" = 1 ] && [ "$RUN_LIFECYCLE" = "1" ] && run_lifecycle
    [ "$rig_control_ok" = 1 ] && [ "$RUN_FAULTS" = "1" ] && run_fault_injection
    [ "$rig_control_ok" = 1 ] && [ "$RUN_AUTH_FAIL_CLOSED" = "1" ] && run_auth_fail_closed
    [ "$rig_control_ok" = 1 ] && [ "$RUN_HARDENING" = "1" ] && run_hardening
    [ "$rig_control_ok" = 1 ] && [ "$RUN_XVB_ROUTING" = "1" ] && run_xvb_routing_smoke
    # Subnet last among the destructive phases: it does a full down/up, so it re-establishes the
    # baseline stack cleanly before the end-of-run restore.
    [ "$rig_control_ok" = 1 ] && [ "$RUN_SUBNET" = "1" ] && run_subnet_scenario

    # An image gate always returns the exact old release and its quiesced writable state. Other runs
    # roll back only on failure, then put config.json back where it started. Drop the archive only
    # after verification.
    if [ "$_UPGRADE_RESTORE_ARMED" = "1" ]; then
        restore_upgrade_baseline
    else
        safety_rollback_if_failed
        restore_baseline
    fi
    [ "$SAFETY_RESTORE_FAILED" = 0 ] && _SAFETY_RESTORE_ARMED=0
    safety_cleanup
    summary
}

main "$@"
