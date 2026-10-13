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

# Real entrypoint execution is covered by test-xmrig-proxy-entrypoint.sh. Here the
# live verdict must reject Docker .Args (without the appended flag), not bless it.
off='["xmrig-proxy","--donate-level=0"]'
on='["xmrig-proxy","--donate-level=0","--access-password=fixture-secret"]'
empty_env='["PROXY_STRATUM_PASSWORD="]'
set_env='["PROXY_STRATUM_PASSWORD=fixture-secret"]'
proxy_password_matches "$off" "" "$empty_env" >/dev/null
proxy_password_matches "$on" auto "$set_env" >/dev/null
proxy_password_matches "$on" fixture-secret "$set_env" >/dev/null
reject_proxy() {
    if proxy_password_matches "$@" >/dev/null 2>&1; then
        echo 'FAIL: live proxy password verdict accepted a mismatch' >&2
        exit 1
    fi
}
reject_proxy "$off" auto "$set_env"
reject_proxy "$off" fixture-secret "$set_env"
reject_proxy "$on" "" "$empty_env"
reject_proxy "$on" auto "$empty_env"
reject_proxy "$on" wrong "$set_env"
reject_proxy "$on" auto '[]'
reject_proxy "$on" auto '["PROXY_STRATUM_PASSWORD=fixture-secret","PROXY_STRATUM_PASSWORD=fixture-secret"]'
reject_proxy '["xmrig-proxy","--access-password="]' "" "$empty_env"
reject_proxy '["xmrig-proxy","--access-password=wrong"]' auto "$set_env"
reject_proxy '["xmrig-proxy","--access-password=fixture-secret","--access-password=fixture-secret"]' auto "$set_env"
reject_proxy '["sh","--access-password=fixture-secret"]' auto "$set_env"
reject_proxy '[]' "" "$empty_env"
reject_proxy 'invalid JSON' "" "$empty_env"

config='{"p2pool":{"stratum_password":"auto"}}'
failures=0
passes=0
it_fail() { failures=$((failures + 1)); }
it_pass() { passes=$((passes + 1)); }
read_failure=''
rx() {
    case "$1" in
    *'/proc/1/cmdline'*)
        [ "$read_failure" != argv ] || return 1
        # Exercise the exact remote snippet with a fake docker, preserving NULs.
        docker() { printf 'xmrig-proxy\0--donate-level=0\0--access-password=fixture-secret\0'; }
        export -f docker
        bash -c "$1"
        ;;
    *'.Config.Env'*)
        [ "$read_failure" != env ] || return 1
        printf '%s' "$set_env"
        ;;
    *) return 1 ;;
    esac
}
assert_proxy_password_live "$config"
[[ "$passes" = 1 && "$failures" = 0 ]]
for read_failure in argv env; do assert_proxy_password_live "$config"; done
assert_proxy_password_live ""
assert_proxy_password_live '{"p2pool":{"stratum_password":false}}'
[[ "$passes" = 1 && "$failures" = 4 ]]
printf 'PASS: actual daemon argv matches off/auto/literal; mismatches and unavailable reads fail closed\n'
