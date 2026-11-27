#!/usr/bin/env bash
# Exercise the actual rig provenance wait with scripted feed replies; no guest or real sleeps.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/os/rig-config-meta-wait.sh
source "$HERE/rig-config-meta-wait.sh"
grep -Fq '. "$SCRIPT_DIR/rig-config-meta-wait.sh"' "$HERE/run.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fail() {
    echo "FAIL: $*" >&2
    exit 1
}
token=00000000000000000000000000000001
cid=0123456789abcdef
fresh='{"rigforge":{"config_meta":{"revision":"aaff4ef89d1ec3e6","last_change_id":"0123456789abcdef"}}}'
stale='{"rigforge":{"config_meta":{"revision":"aaff4ef89d1ec3e6","last_change_id":null}}}'
other='{"rigforge":{"config_meta":{"revision":"1111111111111111","last_change_id":"1111111111111111"}}}'
expected='{"revision":"aaff4ef89d1ec3e6","last_change_id":"0123456789abcdef"}'
_ssh() {
    local n
    n=$(cat "$scratch/calls")
    printf '%s\n' "$((n + 1))" >"$scratch/calls"
    [[ "$*" == *"Authorization: Bearer $token"* ]] || fail 'missing authentication'
    [[ "$*" == *'/2/summary' ]] || fail 'wrong feed'
    sed -n "$((n + 1))p" "$scratch/replies"
}
sleep() {
    [ "$1" = 5 ] || fail 'wrong retry interval'
    echo x >>"$scratch/sleeps"
}
run_case() { # expected ID, replies, expected attempts, expected sleeps, expected outcome
    local id=$1 replies=$2 calls=$3 sleeps=$4 outcome=$5 result rc=0
    printf '%s\n' "$replies" >"$scratch/replies"
    printf '0\n' >"$scratch/calls"
    : >"$scratch/sleeps"
    result=$(rig_config_meta_wait "$token" "$id") || rc=$?
    [ "$(cat "$scratch/calls")" = "$calls" ] || fail "wrong attempts: $calls"
    [ "$(wc -l <"$scratch/sleeps")" -eq "$sleeps" ] || fail "wrong sleeps: $sleeps"
    if [ "$outcome" = pass ]; then
        [ "$rc" = 0 ] && [ "$result" = "$expected" ] || fail 'valid metadata rejected'
    else
        [ "$rc" = 1 ] && [ -z "$result" ] || fail 'missing metadata passed'
    fi
}
run_case "$cid" "$fresh" 1 0 pass
run_case "$cid" "${stale}
${other}
${fresh}" 3 2 pass
run_case "$cid" "not json
{}
${fresh}" 3 2 pass
run_case "$cid" '{"rigforge":{"config_meta":{"revision":null,"last_change_id":null}}}' 12 11 fail
run_case "$cid" "$other" 12 11 fail
run_case '' "$fresh" 1 0 pass
run_case 'quote-bearing-invalid-id' "$fresh" 0 0 fail
printf 'selftest-rig-config-meta-wait: 7 cases passed\n'
