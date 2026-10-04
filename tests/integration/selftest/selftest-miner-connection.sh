#!/usr/bin/env bash
# Endpoint verdict mutations, without a service or network.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/../lib/miner-connection.sh"
echo "== unit: miner connection credential and TLS identity verdict (#3092) =="
fingerprint=$(printf 'a%.0s' {1..64})
body=$(jq -nc --arg fp "$fingerprint" '{url:"stratum+ssl://fixture:3333",password:"fixture-secret",password_set:true,tls:true,fingerprint:$fp}')
miner_connection_matches "$body" fixture-secret true "$fingerprint" 3333 >/dev/null
for mutation in '.password="wrong"' '.password_set=false' '.tls=false' '.fingerprint="wrong"' '.url="stratum+tcp://fixture:3333"' '.url="stratum+ssl://fixture:4444"' 'del(.password)' 'del(.fingerprint)' 'del(.url)'; do
    if miner_connection_matches "$(jq "$mutation" <<<"$body")" fixture-secret true "$fingerprint" 3333 >/dev/null 2>&1; then
        printf 'FAIL: connection verdict accepted %s\n' "$mutation" >&2
        exit 1
    fi
done
body='{"url":"stratum+tcp://fixture:3333","password":"","password_set":false,"tls":false,"fingerprint":""}'
miner_connection_matches "$body" "" false "" 3333 >/dev/null
printf 'PASS: miner connection verdict rejects absent or mismatched credentials and TLS identity\n'
