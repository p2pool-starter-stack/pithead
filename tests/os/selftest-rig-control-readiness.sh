#!/usr/bin/env bash
# Execute the rig phase's control probes with fake transport and no guest.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# Keep the actual loop and both verdicts; stop before the unrelated container assertions.
awk '
    /case "\$pcode" in 401/ { capture=1; next }
    /# THE assertion of this phase/ { capture=0 }
    capture { print }
' "$HERE/phases/rig.sh" >"$scratch/probes.sh"
[ -s "$scratch/probes.sh" ]
fail() {
    echo "FAIL: $*" >&2
    exit 1
}
_rig_http() {
    [ "$*" = http://127.0.0.1:8082/ ] || fail "unexpected loopback probe"
    local calls
    calls=$(cat "$scratch/calls")
    printf '%s\n' "$((calls + 1))" >"$scratch/calls"
    if [ "$calls" -lt "$unready" ]; then
        printf '%s' "$unready_code"
    else
        printf '401'
    fi
}
curl() {
    [ "$*" = "-s -m 5 -o /dev/null -w %{http_code} http://$ip:8082/" ] || fail "unexpected unpinned-source probe"
    echo x >>"$scratch/external"
    printf '%s' "$external_code"
}
sleep() {
    [ "$1" = 5 ] || fail "wrong retry interval"
    echo x >>"$scratch/sleeps"
}
ok() { printf '%s\n' "$*" >>"$scratch/pass"; }
bad() { printf '%s\n' "$*" >>"$scratch/fail"; }
run_case() {
    local unready=$1 unready_code=$2 external_code=$3 expected_calls=$4 expected_sleeps=$5
    # shellcheck disable=SC2034 # the extracted phase uses these locals
    local pcode ptries=12 ip=192.0.2.1
    printf '0\n' >"$scratch/calls"
    for file in sleeps external pass fail; do : >"$scratch/$file"; done
    # shellcheck disable=SC1091 # extracted directly from the real phase above
    source "$scratch/probes.sh"
    [ "$(cat "$scratch/calls")" = "$expected_calls" ] || fail "wrong attempt count ($*)"
    [ "$(wc -l <"$scratch/sleeps")" -eq "$expected_sleeps" ] || fail "wrong sleep count ($*)"
    [ "$(wc -l <"$scratch/external")" -eq 1 ] || fail "unpinned-source check retried"
    if [ "$unready" -lt 12 ]; then
        grep -Fxq 'the control port listens (loopback answers 401)' "$scratch/pass" || fail "ready listener failed"
    else
        grep -Fxq "the control port does not answer even on loopback ('${unready_code}')" "$scratch/fail" || fail "absent listener passed"
    fi
    if [ "$external_code" = 000 ]; then
        grep -Fxq 'the control port is unreachable from an unpinned source (this host)' "$scratch/pass" || fail "refusal failed"
    else
        grep -Fxq "the control port answered '$external_code' from an unpinned source" "$scratch/fail" || fail "exposed listener passed"
    fi
    local expected_fail=0
    [ "$unready" -lt 12 ] || expected_fail=$((expected_fail + 1))
    [ "$external_code" = 000 ] || expected_fail=$((expected_fail + 1))
    [ "$(wc -l <"$scratch/fail")" -eq "$expected_fail" ] || fail "unexpected verdicts"
    [ "$(wc -l <"$scratch/pass")" -eq "$((2 - expected_fail))" ] || fail "missing verdicts"
}
run_case 0 000 000 1 0
run_case 2 000 000 3 2
run_case 2 '' 000 3 2
run_case 11 000 000 12 11
run_case 12 000 000 12 12
run_case 12 '' 000 12 12
run_case 2 000 200 3 2
printf 'selftest-rig-control-readiness: 7 cases passed\n'
