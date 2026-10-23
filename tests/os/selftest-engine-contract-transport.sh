#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT_DIR="$ROOT/tests/os"
source "$SCRIPT_DIR/appliance-engine-contract-leg.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
SSH_ERR="$work/ssh.err"
ok() { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; }
_ssh() (
    exec 2>"$SSH_ERR"
    if [ "$mode" = transport ]; then
        printf 'fixture SSH transport refusal\n' >&2
        exit 255
    fi
    bash() {
        if [ "$mode" = guest ]; then
            printf 'fixture guest contract refusal\n' >&2
            return 42
        fi
        printf 'appliance engine contract: PASS\n'
        [ "$mode" != false-pass ]
    }
    eval "$1"
)
for mode in guest transport false-pass; do
    rc=0
    appliance_engine_contract_leg >"$work/$mode.log" 2>&1 || rc=$?
    [ "$rc" -ne 0 ]
    grep -Fq 'FAIL: appliance engine contract failed' "$work/$mode.log"
done
grep -Fq 'fixture guest contract refusal' "$work/guest.log" || {
    echo 'FAIL: guest stderr was not reported' >&2
    exit 1
}
grep -Fq 'fixture SSH transport refusal' "$work/transport.log" || {
    echo 'FAIL: SSH transport stderr was not reported' >&2
    exit 1
}
mode=pass
appliance_engine_contract_leg >"$work/pass.log" 2>&1
grep -Fq 'PASS: all CLI engine forms pass' "$work/pass.log"
printf 'engine contract transport selftest: PASS\n'
