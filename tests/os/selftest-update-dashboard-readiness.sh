#!/usr/bin/env bash
# Drive the real leg's readiness and presence checks with fake HTTP and clock I/O.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# Retain the phase's actual preconditions, poll and assertion; omit bundle operations.
awk '/^phase_update_dashboard\(\)/ { capture=1 } /# Bench-local release server:/ { exit } capture { print }' \
    "${UPDATE_DASHBOARD_SOURCE:-$HERE/phases/update-dashboard.sh}" >"$scratch/phase.sh"
printf '}\n' >>"$scratch/phase.sh"
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
info() { :; }
ok() { printf '%s\n' "$*" >>"$scratch/pass"; }
bad() { printf '%s\n' "$*" >>"$scratch/fail"; }
_wizard_provision_capture() { return 0; }
_ssh() { printf 'dashboard\ncaddy\n'; }
date() { cat "$scratch/clock"; }
sleep() {
    [ "$1" -gt 0 ] && [ "$1" -le 5 ] || fail 'unexpected polling interval'
    printf '%s\n' "$(($(cat "$scratch/clock") + $1))" >"$scratch/clock"
    printf '%s\n' "$1" >>"$scratch/sleeps"
}
curl() {
    local output='' limit='' login='' url='' calls
    while [ "$#" -gt 0 ]; do
        case "$1" in
        -o)
            output=$2
            shift
            ;;
        -m)
            limit=$2
            shift
            ;;
        -u)
            login=$2
            shift
            ;;
        https://*) url=$1 ;;
        esac
        shift
    done
    [ "$url" = "https://$ip/api/state" ] || fail 'readiness must query the state endpoint'
    [ "$login" = "$DASH_USER:$DASH_PASS" ] || fail 'state poll must use the captured login'
    [ -n "$output" ] || fail 'state response must be retained'
    [ "$limit" -gt 0 ] && [ "$limit" -le 8 ] || fail 'unbounded request'
    [ "$limit" -le "$((120 - $(cat "$scratch/clock")))" ] || fail 'request exceeds deadline'
    printf '%s\n' "$output" >>"$scratch/bodies"
    calls=$(cat "$scratch/calls")
    printf '%s\n' "$((calls + 1))" >"$scratch/calls"
    if [ "$calls" -lt "$unready" ]; then
        printf '%s' "$body" >"$output"
        printf '%s' "$fixture_code"
        if [ "$transport" -ne 0 ]; then
            printf '%s\n' "$(($(cat "$scratch/clock") + limit))" >"$scratch/clock"
        fi
        return "$transport"
    fi
    printf '%s' "$ready_body" >"$output"
    printf '200'
}
# shellcheck disable=SC1091 # generated from the checked-in phase above
source "$scratch/phase.sh"
run_case() {
    local unready=$1 fixture_code=$2 body=$3 transport=$4 ready_body=$5 expected_calls=$6 expected=$7
    local ip=192.0.2.1 DASH_USER=fixture-user DASH_PASS=fixture-password
    local LEG4_PITHEAD_BOOT_PROVED=0
    for file in pass fail sleeps bodies; do : >"$scratch/$file"; done
    printf '0\n' >"$scratch/calls"
    printf '0\n' >"$scratch/clock"
    phase_update_dashboard unused-bundle
    [ "$(cat "$scratch/calls")" -eq "$expected_calls" ] || fail "wrong attempts: $expected"
    [ "$(cat "$scratch/clock")" -le 120 ] || fail 'poll exceeded deadline'
    [ "$LEG4_PITHEAD_BOOT_PROVED" -eq 0 ] || fail 'readiness claimed a boot commit'
    while IFS= read -r file; do
        [ ! -e "$file" ] || fail 'response file was not cleaned up'
    done <"$scratch/bodies"
    if [ "$expected" = ready ]; then
        [ ! -s "$scratch/fail" ] || fail 'ready state failed'
        grep -Fq '/api/state carries the appliance os_update state' "$scratch/pass" || fail 'presence assertion missing'
    elif [ "$expected" = missing ]; then
        grep -Fxq 'leg 4: /api/state has no os_update — the dashboard would never show the OS control' "$scratch/fail" || fail 'missing state did not fail immediately'
    else
        grep -Fq "readiness timed out after 120 s — HTTP $fixture_code; body:" "$scratch/fail" || fail 'timeout lost HTTP diagnostic'
        grep -Fq "$body_excerpt" "$scratch/fail" || fail 'timeout lost body excerpt'
        [ "$(wc -c <"$scratch/fail")" -le 300 ] || fail 'unbounded body diagnostic'
        [ "$(cat "$scratch/clock")" -eq 120 ] || fail 'timeout did not spend its bound'
    fi
}
valid='{"os_update":{"step":"idle"}}'
run_case 0 502 upstream 0 "$valid" 1 ready
run_case 2 502 upstream 0 "$valid" 3 ready
run_case 2 200 '' 0 "$valid" 3 ready
run_case 2 200 '{broken' 0 "$valid" 3 ready
run_case 2 401 refused 0 "$valid" 3 ready
run_case 2 000 '' 28 "$valid" 3 ready
# A partial transfer can report HTTP 200 and valid JSON while curl fails.
run_case 2 200 "$valid" 28 "$valid" 3 ready
run_case 0 200 '' 0 '{}' 1 missing
run_case 0 200 '' 0 '{"os_update":{"step":null}}' 1 missing
body_excerpt=upstream
run_case 99 502 upstream 0 "$valid" 24 timeout
body_excerpt='body:'
run_case 99 200 '' 0 "$valid" 24 timeout
run_case 99 000 '' 28 "$valid" 10 timeout
body_excerpt='{broken'
run_case 99 200 "{broken$(printf '%0500d' 0)" 0 "$valid" 24 timeout
printf 'selftest-update-dashboard-readiness: 13 cases passed\n'
