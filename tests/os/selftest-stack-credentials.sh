#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
FIXTURE_ROOT="$(cd "$HERE/../.." && pwd)"
export FIXTURE_ROOT
export FIXTURE_PASSWORD='fixture-metrics-42"\tail'
export FIXTURE_CAPTURE="$scratch/argv"
mkdir -p "$scratch/os" "$scratch/integration"
cat >"$scratch/integration/run.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
source "$FIXTURE_ROOT/tests/integration/lib.sh" || exit 1
eval "$(sed -n '/^assert_metrics_via_caddy() {/,/^}/p' "$FIXTURE_ROOT/tests/integration/lib/run-scenario.sh")"
printf '%s\n' "$@" >"$FIXTURE_CAPTURE"
env_on_box() {
    case "$1" in
    HOST_IP) printf dashboard.invalid ;;
    DASHBOARD_SECURE) printf true ;;
    HOST_PORT) printf 443 ;;
    DASHBOARD_AUTH_HASH_B64) printf configured ;;
    DASHBOARD_AUTH_USER) printf fixture-user ;;
    *) return 1 ;;
    esac
}
rx() {
    local auth
    printf '%s\n' "$@" >>"$FIXTURE_CAPTURE"
    auth=$(sed -n 's/^user = //p' | jq -r .) || return 1
    if [ "$auth" = "fixture-user:$FIXTURE_PASSWORD" ]; then
        printf 'pithead_up 1\n'
    else
        printf 'Unauthorized\n'
        return 22
    fi
}
assert_metrics_via_caddy
[ "$IT_FAIL" -eq 0 ] || exit 1
[ "$IT_SKIPPED_MISSING" -eq 0 ] || exit 2
exit "${FIXTURE_EXIT:-0}"
SH
chmod +x "$scratch/integration/run.sh"
OS_RUN_SUITE=1
# shellcheck source=tests/os/phases/stack.sh
source "$HERE/phases/stack.sh" || exit 1
SCRIPT_DIR="$scratch/os" ip=fixture.invalid KEY=fixture-key
ok() { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; }
info() { printf 'INFO: %s\n' "$*"; }
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
export IT_DASHBOARD_PASSWORD=stale-fixture-value
export FIXTURE_EXIT=0
for fixture_case in correct missing wrong harness-failure; do
    case "$fixture_case" in
    correct) dash_pass="$FIXTURE_PASSWORD" expected=0 ;;
    missing)
        unset dash_pass
        expected=2
        ;;
    wrong) dash_pass=incorrect-fixture-value expected=1 ;;
    harness-failure) dash_pass="$FIXTURE_PASSWORD" expected=23 FIXTURE_EXIT=23 ;;
    esac
    _stack_run_integration "$fixture_case" --check >"$scratch/output" 2>&1
    actual=$?
    [ "$actual" -eq "$expected" ] || fail "$fixture_case returned $actual, expected $expected"
    [ "$IT_DASHBOARD_PASSWORD" = stale-fixture-value ] || fail 'fixture password escaped invocation scope'
    if grep -Fq -e "$FIXTURE_PASSWORD" -e incorrect-fixture-value "$scratch/argv" "$scratch/output"; then
        fail 'credential entered arguments or output'
    fi
    if [ "$fixture_case" = correct ]; then
        grep -Fq 'PASS: DIY gate vs. appliance channel: correct' "$scratch/output" || fail 'successful harness did not pass battery row'
        grep -Fxq -- '--check' "$scratch/argv" || fail 'harness arguments were lost'
    else
        grep -Fq "FAIL: DIY gate vs. appliance channel: $fixture_case (exit $expected)" "$scratch/output" || fail 'harness failure did not fail battery row'
    fi
done
printf 'PASS: stack credential forwarding, authenticated metrics, invocation scope and failure propagation\n'
