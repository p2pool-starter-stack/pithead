#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
source "$ROOT/tests/integration/lib/miner-connection.sh"
if [ "$#" -gt 0 ]; then
    # shellcheck source=/dev/null
    source "$1"
fi
echo "== stratum client channel selection (#3078) =="
HERE="$ROOT/tests/integration"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
quote_arg() { printf '%q' "$1"; }
it_pass() { IT_PASS=$((IT_PASS + 1)); }
it_fail() { IT_FAIL=$((IT_FAIL + 1)); }
rx() {
    case "$1" in
    *' controls'*)
        printf '%s\n' "$1" >>"$fixture/probes"
        return 0
        ;;
    esac
    if [ "$transport" -ne 0 ]; then return "$transport"; fi
    case "$unknown" in
    true)
        printf 'unknown\n'
        return 0
        ;;
    empty) return 0 ;;
    esac
    (cd "$fixture" && bash -c "$1")
}
run_case() {
    local name="$1" expected="$2" miner="$3"
    IT_PASS=0 IT_FAIL=0
    : >"$fixture/probes"
    assert_stratum_client_controls
    if [ "$expected" = fail ]; then
        if [ "$IT_FAIL" -ne 1 ] || [ "$IT_PASS" -ne 0 ] || [ -s "$fixture/probes" ]; then
            printf 'FAIL: %s downgraded the control\n' "$name" >&2
            exit 1
        fi
    else
        [ "$IT_FAIL" -eq 0 ]
        [ "$IT_PASS" -eq 1 ]
        [ "$(wc -l <"$fixture/probes")" -eq 1 ]
        if [ "$miner" = appliance ]; then
            grep -Fq 'TMPDIR=/data/pithead/data timeout' "$fixture/probes"
            grep -Fq 'controls /opt/rigforge/prebuilt/xmrig/build/xmrig' "$fixture/probes"
        else
            if grep -Fq 'xmrig/build/xmrig' "$fixture/probes"; then exit 1; fi
        fi
    fi
    printf 'PASS: %s\n' "$name"
}
transport=0 unknown=false
printf 'is_appliance() { return 0; }\n' >"$fixture/pithead"
run_case 'appliance requires shipped XMRig' pass appliance
printf 'is_appliance() { return 1; }\n' >"$fixture/pithead"
run_case 'DIY uses raw client controls' pass diy
transport=255
run_case 'transport failure runs no probe' fail ''
transport=0
printf 'return 1\n' >"$fixture/pithead"
run_case 'CLI source failure runs no probe' fail ''
printf 'is_appliance() { return 2; }\n' >"$fixture/pithead"
run_case 'unexpected detector exit runs no probe' fail ''
printf ':\n' >"$fixture/pithead"
run_case 'missing detector runs no probe' fail ''
unknown=true
run_case 'unknown channel runs no probe' fail ''
unknown=empty
run_case 'empty channel runs no probe' fail ''
