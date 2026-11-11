#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-onion-targets.sh
source "$HERE/../lib/run-onion-targets.sh"
onion=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.onion
mode=
checks=0
env_on_box() { printf '%s\n' placeholder; }
quote_arg() { printf '%q' "$1"; }
rx() {
    case "$1" in
    docker\ build*) [ "$mode" != image-build ] ;;
    *)
        case "$mode" in
        reachable)
            printf '%s\n' 'PROBE-OK: reachable RAW-SECRET-SENTINEL'
            return 0
            ;;
        http-unreachable)
            printf '%s\n' 'PROBE-FAIL: HTTP 000 RAW-SECRET-SENTINEL'
            return 1
            ;;
        bootstrap)
            printf '%s\n' 'PROBE-FAIL: bootstrap RAW-SECRET-SENTINEL'
            return 2
            ;;
        credentials)
            printf '%s\n' 'RAW-SECRET-SENTINEL'
            return 4
            ;;
        *)
            printf '%s\n' 'RAW-SECRET-SENTINEL'
            return 3
            ;;
        esac
        ;;
    esac
}
run_case() {
    local expected_rc="$1" expected_stage="$2" case_mode="$3" auth="${4:-required}" address="${5:-$onion}" saved_env="${6:-}"
    local output rc
    mode="$case_mode"
    output="$(mktemp)"
    set +e
    _onion_reachable_external "$address" "$saved_env" "$auth" >"$output" 2>&1
    rc=$?
    set -e
    [ "$rc" -eq "$expected_rc" ]
    [ "$ONION_EXTERNAL_PROBE_STAGE" = "$expected_stage" ]
    [ ! -s "$output" ]
    rm -f "$output"
    checks=$((checks + 1))
}

echo "== external onion probe stages =="
run_case 2 address-not-ready unused required placeholder
run_case 3 invalid unused required invalid.onion
run_case 3 image-build image-build
run_case 0 reachable reachable
run_case 1 http-unreachable http-unreachable
run_case 2 bootstrap bootstrap
run_case 3 client-error client-error
run_case 4 credentials credentials
run_case 3 client-error credentials auto
run_case 3 invalid unused none "$onion" saved.env
run_case 0 reachable reachable
run_case 3 client-error unexpected
printf 'selftest-onion-probe-stage: PASS (%s checks)\n' "$checks"
