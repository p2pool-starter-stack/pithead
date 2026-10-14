#!/usr/bin/env bash
# Same-box restore compares durable Tari scope without accepting a new full hold.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/run-tari-background-sync.sh
INTEGRATION_RUN_SUITE=1 source "$HERE/../lib/run-tari-background-sync.sh"
echo "== durable Tari marker reads for same-box restore =="
fixture="$(mktemp -d "${TMPDIR:-${RUNNER_TEMP:?}}/tari-marker-selftest.XXXXXX")" || exit 1
trap 'rm -rf "$fixture"' EXIT
env_on_box() { printf '%s' "$fixture"; }
rx() { bash -c "${1#sudo }"; }
marker="$fixture/sync-gate-reset"
assert_eq "absent marker is readable" "$(sync_gate_marker_state)" absent
printf 'tari-only\n' >"$marker"
assert_eq "typed background scope is readable" "$(sync_gate_marker_state)" tari-only
assert_eq "reading leaves the durable marker unchanged" "$(cat "$marker")" tari-only
for shape in full unknown overlong symlink fifo directory; do
    rm -rf "$marker"
    case "$shape" in
    full) : >"$marker" ;;
    unknown) printf 'other\n' >"$marker" ;;
    overlong) printf 'tari-only\nextra' >"$marker" ;;
    symlink)
        printf 'tari-only\n' >"$fixture/target"
        ln -s "$fixture/target" "$marker"
        ;;
    fifo) mkfifo "$marker" ;;
    directory) mkdir "$marker" ;;
    esac
    rc=0
    sync_gate_marker_state >/dev/null 2>&1 || rc=$?
    assert_eq "$shape marker fails without blocking" "$rc" 1
done
env_on_box() { :; }
rc=0
sync_gate_marker_state >/dev/null 2>&1 || rc=$?
assert_eq "missing marker path fails closed" "$rc" 1
printf 'Tari restore marker selftest: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" = 0 ]
