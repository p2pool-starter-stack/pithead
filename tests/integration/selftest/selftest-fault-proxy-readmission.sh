#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
export INTEGRATION_RUN_SUITE=1
source "$HERE/../lib/run-lifecycle.sh"
source "$HERE/../lib/run-faults.sh"

CLOCK="$(mktemp)"
trap 'rm -f "$CLOCK"' EXIT

drive_fault() (
    local fault="$1" recovery="$2" proxy_ready_at=10 node_state='running healthy' tor_state='running healthy'
    local egress='' stopped_ready='' rc=0
    IT_FAIL=0
    printf '0\n' >"$CLOCK"
    now_s() { cat "$CLOCK"; }
    sleep() { printf '%s\n' "$(($(now_s) + $1))" >"$CLOCK"; }
    service_state() {
        case "$1" in
        monerod) printf '%s' "$node_state" ;;
        tor) printf '%s' "$tor_state" ;;
        xmrig-proxy)
            if [ "$recovery" != never ] && [ "$(now_s)" -ge "$proxy_ready_at" ]; then
                printf 'running healthy'
            else
                printf 'exited none'
            fi
            ;;
        *) return 2 ;;
        esac
    }
    api_state() {
        if [ "$(svc_state_of "$(service_state xmrig-proxy)")" = running ]; then
            printf '{"sync":{"monero":{"state":"done"}},"badges":[]}'
        else
            printf '{"sync":{"monero":{"state":"done"}},"badges":[{"text":"Miner held (sync)"}]}'
        fi
    }
    pithead() {
        case "$1" in
        doctor)
            printf 'Tor is down'
            return 1
            ;;
        status) [ "$node_state" != missing ] ;;
        *) return 2 ;;
        esac
    }
    wait_status_ok() { return 0; }
    rx() {
        case "$1" in
        'docker compose rm -sf monerod') node_state=missing ;;
        'docker compose up -d monerod') node_state='running healthy' ;;
        'docker compose stop tor')
            stopped_ready="$(svc_state_of "$(service_state xmrig-proxy)")"
            tor_state='exited none'
            ;;
        'docker compose start tor')
            tor_state='running healthy'
            proxy_ready_at=$(($(now_s) + 10))
            ;;
        *)
            printf 'unexpected target command\n' >&2
            return 2
            ;;
        esac
    }
    assert_egress_posture() { egress="${egress}$(svc_state_of "$(service_state xmrig-proxy)") "; }
    "$fault" >/dev/null 2>&1 || rc=$?
    printf '%s|%s|%s|%s|%s' "$rc" "$IT_FAIL" "$(now_s)" "$stopped_ready" "$egress"
)

echo "== fault recovery waits for the proxy rather than status alone (#2590) =="
assert_eq 'recreated healthy monerod does not finish recovery while the proxy is held' \
    "$(drive_fault fault_missing delayed)" '0|0|10||'
assert_eq 'a proxy that never returns records a binding recovery failure' \
    "$(drive_fault fault_missing never)" '0|1|240||'
assert_eq 'Tor stops only after readmission; both egress observations have a running proxy' \
    "$(drive_fault fault_tor_down delayed)" '0|0|20|running|running running '
assert_eq 'proxy timeouts fail both Tor readiness rows without suppressing the egress checks' \
    "$(drive_fault fault_tor_down never)" '0|2|480|exited|exited exited '

printf 'selftest-fault-proxy-readmission: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
