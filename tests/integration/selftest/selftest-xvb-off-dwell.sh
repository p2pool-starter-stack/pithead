#!/usr/bin/env bash
# Fake transport and clock; no daemon, network or real sleep.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/lib.sh"
export INTEGRATION_RUN_SUITE=1
source "$HERE/lib/run-scenario.sh"
td="$(mktemp -d)"
trap 'rm -rf "$td"' EXIT
export OUT_DIR="$td/evidence"
fixture() {
    local arm="$1" want="$2" out
    out="$(
        it_pass() { echo "[PASS] $1"; }
        it_fail() { echo "[FAIL] $1 ${2:-}"; }
        it_skip_leg() { echo "[SKIP] $1 $2 $3"; }
        echo 10000030 >"$td/clock"
        echo 0 >"$td/polls"
        env_on_box() {
            case "$arm" in
            enabled) echo true ;;
            failed-enabled)
                echo true
                return 1
                ;;
            failed-disabled) return 1 ;;
            *) echo false ;;
            esac
        }
        mkdir() { [ "$arm" != failed-evidence ] && command mkdir "$@"; }
        sleep() { echo "$(($(cat "$td/clock") + $1))" >"$td/clock"; }
        rx() {
            case "$1" in
            *'XVB_TIME_ALGO_MS'*)
                case "$arm" in
                bad-dwell) echo nonsense ;;
                short-dwell) echo 60000 ;;
                failed-dwell)
                    echo 600000
                    return 1
                    ;;
                *) echo 600000 ;;
                esac
                ;;
            *'docker inspect'*)
                if [ "$arm" = restart ] && [ "$(cat "$td/clock")" -gt 10000060 ]; then
                    echo 'replacement started'
                else
                    echo 'container started'
                    if [ "$arm" = failed-final-inspect ] && [ "$(cat "$td/clock")" -gt 10000060 ]; then return 1; fi
                fi
                ;;
            'date -d '*) echo 10000000 ;;
            'date +%s')
                if [ "$arm" = bad-clock ]; then echo nonsense; else cat "$td/clock"; fi
                ;;
            *'docker logs'*'--until'*)
                case "$arm" in
                churn) printf '%s\n' 'ending P2Pool dwell early' 'Switched Proxy to mode: P2POOL' 'ending P2Pool dwell early' 'Switched Proxy to mode: P2POOL' 'ending P2Pool dwell early' 'Switched Proxy to mode: P2POOL' ;;
                early-only) echo 'ending P2Pool dwell early' ;;
                switches-only) printf '%s\n' 'Switched Proxy to mode: P2POOL' 'Switched Proxy to mode: P2POOL' ;;
                boundary) echo 'Switched Proxy to mode: P2POOL' ;;
                failed-window)
                    echo 'Switched Proxy to mode: P2POOL'
                    return 1
                    ;;
                *) echo 'normal collection cycle' ;;
                esac
                ;;
            *'docker logs'*)
                case "$arm" in
                never-started) echo 'Web server started' ;;
                failed-startup)
                    echo 'Service Started: Algorithm Control Loop'
                    return 1
                    ;;
                *) echo 'Service Started: Algorithm Control Loop' ;;
                esac
                ;;
            *)
                echo "unexpected command: $1" >&2
                return 1
                ;;
            esac
        }
        api_state() {
            local n
            n="$(($(cat "$td/polls") + 1))"
            echo "$n" >"$td/polls"
            case "$arm" in
            bad-state) echo '{}' ;;
            failed-state)
                echo '{"badges":[]}'
                return 1
                ;;
            paused) echo '{"badges":[{"text":"Workers rejected"}]}' ;;
            paused-midway)
                if [ "$n" = 10 ]; then echo '{"badges":[{"text":"Workers rejected"}]}'; else echo '{"badges":[]}'; fi
                ;;
            *) echo '{"badges":[]}' ;;
            esac
        }
        assert_xvb_off_no_dwell_churn
    )"
    if [[ "$out" != *"[$want]"* ]]; then
        echo "FAIL: $arm expected $want: $out" >&2
        exit 1
    fi
    if [ "$want" = PASS ]; then
        [[ "$out" == *'XVB_TIME_ALGO_MS=600000; window=95s;'* ]] || exit 1
        [ "$(cat "$td/clock")" = 10000155 ] || {
            echo 'FAIL: observation began before 60s uptime'
            exit 1
        }
    fi
    echo "PASS: $arm -> $want"
}
fixture quiet PASS
fixture boundary PASS
fixture churn FAIL
fixture early-only FAIL
fixture switches-only FAIL
fixture enabled SKIP
fixture never-started SKIP
fixture paused SKIP
fixture paused-midway SKIP
fixture failed-enabled FAIL
fixture failed-disabled FAIL
fixture bad-dwell FAIL
fixture short-dwell FAIL
fixture failed-dwell FAIL
fixture bad-clock FAIL
fixture bad-state FAIL
fixture failed-state FAIL
fixture failed-startup FAIL
fixture failed-window FAIL
fixture restart FAIL
fixture failed-final-inspect FAIL
fixture failed-evidence FAIL
# Exercise both callers, so an unhooked assertion cannot silently pass CI.
assert_running_state() { :; }
assert_lan_guard_live() { :; }
pithead() { echo 'No configuration changes detected'; }
assert_xvb_off_no_dwell_churn() { echo called >>"$td/calls"; }
assert_egress_posture() { :; }
assert_xvb_over_tor() { :; }
assert_metrics_via_caddy() { :; }
assert_share_stats_live() { :; }
assert_telemetry_tables_present() { :; }
assert_doctor_ok() { :; }
export BASELINE_CONFIG='{}'
assert_scenario fixture '{}'
assert_current_state || true
[ "$(wc -l <"$td/calls" | tr -d ' ')" = 2 ]
echo 'PASS: deploying scenario and read-only check execute the dwell assertion'
