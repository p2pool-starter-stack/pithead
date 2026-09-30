#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Exercise the real readiness loop without a clock delay or Docker daemon.
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-onion-targets.sh
source "$HERE/../lib/run-onion-targets.sh"
now_s() { echo "$clock"; }
sleep() { clock=$((clock + $1)); }
it_step() { :; }
it_warn() { :; }
it_pass() { passes=$((passes + 1)); }
it_fail() { failures=$((failures + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then it_pass "$1"; else it_fail "$1"; fi; }
env_on_box() {
    case "$1" in
    NETWORK_PREFIX) echo 192.0.2 ;;
    P2POOL_PORT) echo "$port" ;;
    *) return 1 ;;
    esac
}
rx() {
    case "$1" in
    "docker exec tor grep -Fxq 'HiddenServicePort $port 192.0.2.28:$port' /tmp/torrc") return 0 ;;
    "docker exec tor grep -Fxq 'HiddenServicePort 18080 192.0.2.26:18084' /tmp/torrc") return 0 ;;
    "docker exec tor nc -z -w 3 192.0.2.28 $port")
        pool_calls=$((pool_calls + 1))
        [ "$pool_calls" -gt "$pool_refusals" ]
        ;;
    "docker exec tor nc -z -w 3 192.0.2.26 18084")
        node_calls=$((node_calls + 1))
        [ "$node_calls" -gt "$node_refusals" ]
        ;;
    *)
        echo "unexpected probe: $1" >&2
        exit 1
        ;;
    esac
}
run_case() {
    local pool="$1" mode="$2" pool_refusals="$3" node_refusals="$4" expected_failures="$5"
    local clock=0 passes=0 failures=0 pool_calls=0 node_calls=0 port
    case "$pool" in
    main) port=37889 ;;
    mini) port=37888 ;;
    nano) port=37890 ;;
    esac
    assert_onion_targets "$mode" "$pool"
    [ "$failures" -eq "$expected_failures" ]
    if [ "$mode" = local ]; then
        [ "$((passes + failures))" -eq 5 ]
    else
        [ "$((passes + failures))" -eq 3 ] && [ "$node_calls" -eq 0 ]
    fi
    # The production deadline must terminate a permanent refusal; it must also retry.
    [ "$clock" -le 480 ] && [ "$pool_calls" -ge 1 ]
    [ "$pool_refusals" -eq 0 ] || [ "$pool_calls" -gt 1 ]
}
echo "== onion target listener readiness (#2936) =="
for pool in main mini nano; do
    run_case "$pool" local 0 0 0
    run_case "$pool" local 2 3 0
    run_case "$pool" remote 2 0 0
    run_case "$pool" local 1000 0 1
    run_case "$pool" local 0 1000 1
done
echo 'selftest-onion-targets: PASS'
