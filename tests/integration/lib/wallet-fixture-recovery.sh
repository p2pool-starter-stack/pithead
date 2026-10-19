#!/usr/bin/env bash
# shellcheck shell=bash
# The shell-only steps of wallet_fixture_recovery.py: verify the runner's lock, start the baseline stack
# through the command e2e.sh's restore uses, and run the same payout-wallet readiness gate.
set -uo pipefail
RECOVERY_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECOVERY_ROOT="$(cd "$RECOVERY_LIB/.." && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$RECOVERY_ROOT/lib.sh" || exit $?
# shellcheck source=tests/integration/lib/parent-lock.sh
source "$RECOVERY_LIB/parent-lock.sh" || exit $?
# shellcheck source=tests/integration/lib/chain-keep.sh
source "$RECOVERY_LIB/chain-keep.sh" || exit $?
# shellcheck source=tests/integration/lib/restore-mining-ready.sh
source "$RECOVERY_LIB/restore-mining-ready.sh" || exit $?

# shellcheck disable=SC2034  # lib.sh transport globals consumed by rx and api_state
IT_MODE=local
on_bench() { bash -c "$1"; }
ok() { printf ' ✓ %s\n' "$*"; }
warn() { printf ' ! %s\n' "$*" >&2; }
step() { printf '  → %s\n' "$*"; }

recovery_wait_synced() { # <timeout_s>
    local deadline=$(($(date +%s) + $1)) st
    while :; do
        st="$(jq_get "$(api_state)" '"\(.sync.monero.state)/\(.sync.tari.state)"')"
        [ "$st" = "done/done" ] && return 0
        [ "$(date +%s)" -ge "$deadline" ] && {
            warn "sync panels still '$st' after ${1}s"
            return 1
        }
        sleep 8
    done
}

recovery_wait_healthy() { # <timeout_s>
    local deadline=$(($(date +%s) + $1))
    while :; do
        on_bench "cd '$RESTORE_DIR' && ./pithead status >/dev/null 2>&1" && return 0
        [ "$(date +%s)" -ge "$deadline" ] && return 1
        sleep 10
    done
}

recovery_start() { # <baseline>
    local restore_cmd="./pithead apply -y && ./pithead up"
    RESTORE_DIR="$1"
    # shellcheck disable=SC2034  # read by chain_restore_prepare
    E2E_DIR="${E2E_DIR:-/srv/code/pithead-e2e}"
    IT_REMOTE_DIR="$1"
    chain_restore_prepare
    [ ! -f "$RESTORE_DIR/dashboard/Dockerfile" ] || restore_cmd="./pithead upgrade"
    on_bench "cd '$RESTORE_DIR' && { $restore_cmd; }" || {
        warn "baseline start failed in the baseline checkout"
        return 1
    }
    recovery_wait_synced 1500 && recovery_wait_healthy 300 && wait_restore_mining_ready 1500
}

recovery_ready() { # <baseline>
    # shellcheck disable=SC2034  # lib.sh transport and assertion globals consumed by the reused gate
    IT_REMOTE_DIR="$1" INTEGRATION_RUN_SUITE=1 IT_FAIL=0 IT_CURRENT_SCENARIO=wallet-fixture-recovery
    # shellcheck source=tests/integration/lib/run-tari-wallet.sh
    source "$RECOVERY_LIB/run-tari-wallet.sh" || return 1
    assert_payout_wallet_ready confirmed Monero
    [ "$IT_FAIL" = 0 ]
}

recovery_lock_verify() {
    [ -z "${RIG_LOCK_PARENT_ACTOR:-}${RIG_LOCK_PARENT_NONCE:-}" ] || rig_lock_parent_verify
}

main() {
    exec 1>&2
    case "${1:-}" in
    lock-verify) recovery_lock_verify ;;
    start) recovery_start "${2:?baseline checkout}" ;;
    ready) recovery_ready "${2:?baseline checkout}" ;;
    *) exit 2 ;;
    esac
}
[ "${BASH_SOURCE[0]}" != "$0" ] || main "$@"
