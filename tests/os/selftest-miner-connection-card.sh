#!/usr/bin/env bash
# Mutate the required hand-off fields; no browser, guest or network.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/miner-connection-leg.sh"
seed=$(printf 'abcd%.0s' {1..6})
card=$(jq -nc --arg fp "$(printf 'a%.0s' {1..64})" --arg seed "$seed" \
    '{stratum:"stratum+ssl://fixture:3333",stratum_password:$seed,stratum_tls:true,stratum_fingerprint:$fp}')
wizard_miner_connection_card_valid "$card" auto true
for mutation in 'del(.stratum_password)' 'del(.stratum_fingerprint)' 'del(.stratum_tls)' '.stratum_password="auto"' '.stratum_fingerprint=""' '.stratum="stratum+tcp://fixture:3333"'; do
    if wizard_miner_connection_card_valid "$(jq "$mutation" <<<"$card")" auto true; then
        printf 'FAIL: hand-off accepted %s\n' "$mutation" >&2
        exit 1
    fi
done
tls_card="$card"
card='{"stratum":"stratum+tcp://fixture:3333","stratum_password":"","stratum_tls":false,"stratum_fingerprint":""}'
wizard_miner_connection_card_valid "$card" off false
if wizard_miner_connection_card_valid "$(jq 'del(.stratum_password)' <<<"$card")" off false; then
    printf 'FAIL: missing password field is not an explicit off choice\n' >&2
    exit 1
fi
# Exercise the full post-install comparison without running SSH or contacting a dashboard.
# shellcheck disable=SC2034 # the sourced phase reads the runner's ip dynamically.
ip=fixture PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); }
FIXTURE_CERT_DIGEST=$(printf 'a%.0s' {1..64})
_ssh() {
    case "$1" in
    *sed*) printf '%s' "$seed" ;;
    *jq*) printf auto ;;
    *openssl*) printf '%s' "$FIXTURE_CERT_DIGEST" ;;
    *) return 1 ;;
    esac
}
dashboard_curl() {
    printf 'HTTP/1.1 200 OK\r\nCache-Control: no-store\r\n\r\n%s' "$response_body"
}
response_body=$(jq -nc --arg fp "$FIXTURE_CERT_DIGEST" --arg seed "$seed" '{url:"stratum+ssl://fixture:3333",password:$seed,password_set:true,tls:true,fingerprint:$fp}')
phase_miner_connection_installed "$tls_card"
[ "$PASS" = 3 ] && [ "$FAIL" = 0 ]
response_body=$(jq '.password="wrong"' <<<"$response_body")
phase_miner_connection_installed "$tls_card"
[ "$FAIL" = 1 ]
FIXTURE_CERT_DIGEST=$(printf 'b%.0s' {1..64})
phase_miner_connection_installed "$tls_card"
[ "$FAIL" = 3 ] # both carried certificate and endpoint comparison fail.
printf 'PASS: hand-off verdict requires explicit password and TLS identity\n'
