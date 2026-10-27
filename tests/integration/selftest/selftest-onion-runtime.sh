#!/usr/bin/env bash
set -euo pipefail
echo "== unit: dashboard onion runtime witness and restoration =="
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
source "$ROOT/tests/integration/lib.sh"
INTEGRATION_RUN_SUITE=1
source "$ROOT/tests/integration/lib/run-onion-targets.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
cd "$fixture"
printf 'DASHBOARD_ONION_ADDRESS=new.onion\n' >.env
export CURRENT_ENV="$fixture/runtime.json"
docker() { cat "$CURRENT_ENV"; }
export -f docker
rx() { bash -c "$1"; }
for shape in matching stale missing malformed empty; do
    case "$shape" in
    matching) printf '["DASHBOARD_ONION_ADDRESS=new.onion","SECRET=fixture-secret"]' >"$CURRENT_ENV" ;;
    stale) printf '["DASHBOARD_ONION_ADDRESS=old.onion"]' >"$CURRENT_ENV" ;;
    missing) printf '[]' >"$CURRENT_ENV" ;;
    malformed) printf 'invalid' >"$CURRENT_ENV" ;;
    empty) : >"$CURRENT_ENV" ;;
    esac
    rc=0
    dashboard_onion_runtime_matches >output 2>&1 || rc=$?
    if [ "$shape" = matching ]; then [ "$rc" -eq 0 ]; else [ "$rc" -ne 0 ]; fi
    if grep -q fixture-secret output; then exit 1; fi
    printf 'PASS %s\n' "$shape"
done

source "$ROOT/tests/integration/lib/run-rotate-onion.sh"
wait_for() {
    shift 3
    "$@"
}
if (
    ROTATE_ONION_RESTORE_ARMED=1 ROTATE_ONION_HS_DIR=/fixture/dashboard
    ROTATE_ONION_BACKUP_DIR=/fixture/preserve ROTATE_ONION_ENV_BACKUP=/fixture/env
    ROTATE_ONION_OLD_ADDRESS=old.onion ROTATE_ONION_OLD_KEY_FP=keys ROTATE_ONION_OLD_ENV_FP=envs
    rx() { case "$1" in *"sudo -n cat"*) printf 'old.onion\n' ;; esac }
    rotate_onion_key_fingerprint() { printf 'keys\n'; }
    rotate_onion_env_fingerprint() { printf 'envs\n'; }
    pithead() { :; }
    wait_status_ok() { :; }
    dashboard_onion_runtime_matches() { return 1; }
    ! rotate_onion_restore && [ "$ROTATE_ONION_RESTORE_ARMED" = 1 ]
); then
    printf 'PASS restore remains armed on runtime mismatch\n'
else
    printf 'FAIL restore disarmed with stale runtime\n'
    exit 1
fi
