#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OS_RUN_SUITE=1
# shellcheck source=tests/os/phases/rigkeep.sh
source "$HERE/phases/rigkeep.sh"
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
cases=0
pass_case() {
    _rigkeep_verdict "$1" "$2" "${3:-v2}" || fail "rejected a valid pair: $4"
    cases=$((cases + 1))
}
reject_case() {
    ! _rigkeep_verdict "$1" "$2" "${3:-v2}" || fail "accepted an invalid pair: $4"
    cases=$((cases + 1))
}
before='{"role":"rig","worker":"kvm-rig-share","pool":"192.0.2.5:3333","access_token":"0123456789abcdef0123456789abcdef","miner_token":"0123456789abcdef0123456789abcdef","marker":"v1","containers":"0"}'
after='{"role":"rig","worker":"kvm-rig-share","pool":"192.0.2.5:3333","access_token":"0123456789abcdef0123456789abcdef","miner_token":"0123456789abcdef0123456789abcdef","marker":"v2","containers":"0"}'
pass_case "$before" "$after" v2 kept-identity
pass_case "$(jq -c '.access_token = "" | .miner_token = ""' <<<"$before")" \
    "$after" v2 token-minted-when-absent
for change in \
    '.access_token = "ffffffffffffffffffffffffffffffff"' \
    '.access_token = ""' \
    '.access_token = "0123"' \
    '.access_token |= ascii_upcase' \
    '.miner_token = "ffffffffffffffffffffffffffffffff"' \
    '.worker = "other"' \
    '.worker = null' \
    '.pool = "192.0.2.9:3333"' \
    '.pool = null' \
    '.role = "pithead"' \
    '.marker = "v1"' \
    '.containers = "3"' \
    'del(.access_token)' \
    'del(.miner_token)' \
    'del(.worker)' \
    'del(.pool)'; do
    reject_case "$before" "$(jq -c "$change" <<<"$after")" v2 "after: $change"
done
for change in \
    '.worker = "other"' \
    '.pool = "192.0.2.9:3333"' \
    '.role = "pithead"' \
    'del(.worker)'; do
    reject_case "$(jq -c "$change" <<<"$before")" "$after" v2 "before: $change"
done
for invalid in '' 'null' '{}' 'not-json' '['; do
    reject_case "$invalid" "$after" v2 "malformed before: $invalid"
    reject_case "$before" "$invalid" v2 "malformed after: $invalid"
done
reject_case "$before" "$after" v3 marker-not-built
reject_case "$before" "$before" v1 unchanged-slot
[ "$cases" -ge 30 ] || fail "expected at least 30 cases, ran $cases"
printf 'rigkeep identity verdict self-test: PASS (%d cases)\n' "$cases"
