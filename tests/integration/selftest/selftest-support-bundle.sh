#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$HERE/test_support_bundle_check.py"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-cli.sh
source "$HERE/../lib/run-cli.sh"
# shellcheck source=tests/integration/lib/run-support-bundle.sh
source "$HERE/../lib/run-support-bundle.sh"
IT_MODE=local RIG_NAME="" RIGFORGE_BOOTSTRAP_VERSION="" RUN_IMAGE_UPGRADE=0 RUN_ROTATE_SECRETS=0 SKIP_MINING_ASSERTS=0 SAFETY_BACKUP=0
validate_live_gate_args() { :; }
parse_args --lifecycle
assert_eq "lifecycle automatically takes a safety backup" "$SAFETY_BACKUP" 1

drive_bundle() {
    (
        local scenario="$1" temp rc=0
        temp="$(mktemp -d)"
        trap 'rm -rf "$temp"' EXIT
        IT_FAIL=0 IT_PASS=0 SAFETY_ARCHIVE=safety BASELINE_CONFIG='{}' _SAFETY_RESTORE_ARMED=1 SAFETY_RESTORE_FAILED=0
        push_config() { printf '%s' "$1" >"$temp/config"; }
        pithead() {
            case "$1" in
            apply) [ "$scenario" != apply-fails ] ;;
            support-bundle) printf 'Support bundle written: /fixture/support-bundle-test.tar.gz\n' ;;
            esac
        }
        wait_status_ok() { return 0; }
        rx() {
            cat >/dev/null
            [ "$scenario" != check-fails ]
        }
        safety_restore_exact() {
            touch "$temp/restored"
            [ "$scenario" != restore-fails ] || return 1
            _SAFETY_RESTORE_ARMED=0
        }
        run_support_bundle >/dev/null 2>&1 || rc=$?
        [ -f "$temp/restored" ] || exit 9
        if [ "$scenario" = success ]; then
            [ "$rc:$_SAFETY_RESTORE_ARMED:$IT_FAIL" = 0:1:0 ] || exit 10
        else
            [ "$rc" != 0 ] && [ "$IT_FAIL" -gt 0 ] || exit 11
        fi
        [ "$scenario" != restore-fails ] || [ "$SAFETY_RESTORE_FAILED" = 1 ]
    )
}
for scenario in success apply-fails check-fails restore-fails; do
    rc=0
    drive_bundle "$scenario" || rc=$?
    assert_rc "support-bundle $scenario preserves its restoration contract" "$rc" 0
done
[ "$IT_FAIL" -eq 0 ]
