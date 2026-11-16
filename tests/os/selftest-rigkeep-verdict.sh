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
    _rigkeep_verdict "$1" "$2" || fail "rejected a valid pair: $3"
    cases=$((cases + 1))
}
reject_case() {
    ! _rigkeep_verdict "$1" "$2" || fail "accepted an invalid pair: $3"
    cases=$((cases + 1))
}
before='{"role":"rig","worker":"kvm-rig-share","pool":"192.0.2.5:3333","access_token":"0123456789abcdef0123456789abcdef","miner_token":"0123456789abcdef0123456789abcdef","rig_id":"fixture-rig-01","containers":"0"}'
after='{"role":"rig","worker":"kvm-rig-share","pool":"192.0.2.5:3333","access_token":"0123456789abcdef0123456789abcdef","miner_token":"0123456789abcdef0123456789abcdef","rig_id":"fixture-rig-01","containers":"0"}'
pass_case "$before" "$after" kept-identity
pass_case "$(jq -c '.access_token = "" | .miner_token = ""' <<<"$before")" \
    "$after" token-minted-when-absent
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
    '.containers = "3"' \
    'del(.access_token)' \
    'del(.miner_token)' \
    'del(.worker)' \
    'del(.pool)'; do
    reject_case "$before" "$(jq -c "$change" <<<"$after")" "after: $change"
done
for change in \
    '.worker = "other"' \
    '.pool = "192.0.2.9:3333"' \
    '.role = "pithead"' \
    'del(.worker)'; do
    reject_case "$(jq -c "$change" <<<"$before")" "$after" "before: $change"
done
pass_case "$(jq -c '.access_token = "" | .miner_token = ""' <<<"$before")" "$before" token-kept-when-absent-before-equal
for invalid in '' 'null' '{}' 'not-json' '['; do
    reject_case "$invalid" "$after" "malformed before: $invalid"
    reject_case "$before" "$invalid" "malformed after: $invalid"
done
reject_case "$before" "$(jq -c '.miner_token = "0123456789abcdef0123456789abcdef0123456789" ' <<<"$after")" miner-token-diverges
pass_case "$(jq -c '.rig_id = ""' <<<"$before")" "$after" rig-id-minted-when-absent
pass_case "$(jq -c 'del(.rig_id)' <<<"$before")" "$after" rig-id-minted-when-field-absent
reject_case "$before" "$(jq -c '.rig_id = ""' <<<"$after")" rig-id-lost
reject_case "$before" "$(jq -c '.rig_id = "other-rig-02"' <<<"$after")" rig-id-drifted
reject_case "$before" "$(jq -c 'del(.rig_id)' <<<"$after")" rig-id-deleted-after
reject_case "$(jq -c '.rig_id = ""' <<<"$before")" "$(jq -c '.rig_id = ""' <<<"$after")" rig-id-still-absent
reject_case "$(jq -c '.rig_id = 7' <<<"$before")" "$after" rig-id-before-not-string
[ "$cases" -ge 30 ] || fail "expected at least 30 cases, ran $cases"
printf 'rigkeep identity verdict self-test: PASS (%d cases)\n' "$cases"
