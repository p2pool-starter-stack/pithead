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
proxy_payload_verdict() {
    (
        TEST_SAMPLE="$1" TEST_RC="${3:-0}"
        rx() {
            printf '%s' "$TEST_SAMPLE"
            return "$TEST_RC"
        }
        it_pass() { printf PASS; }
        it_fail() { printf FAIL; }
        EXPECTED_WORKERS="$2" assert_proxy_workers_payload
    )
}
[ "$(proxy_payload_verdict '234 1 1048576 True' 1)" = PASS ]
[ "$(proxy_payload_verdict '1048576 2 1048576 True' 2)" = PASS ]
[ "$(proxy_payload_verdict '1048577 1 1048576 True' 1)" = FAIL ]
[ "$(proxy_payload_verdict '234 0 1048576 True' 1)" = FAIL ]
[ "$(proxy_payload_verdict '234 1 1048576 True' 2)" = FAIL ]
[ "$(proxy_payload_verdict '234 1 1048576 False' 1)" = FAIL ]
[ "$(proxy_payload_verdict 'not-a-sample' 1)" = FAIL ]
[ "$(proxy_payload_verdict '234 1 1048576 True trailing' 1)" = FAIL ]
[ "$(proxy_payload_verdict '234 1 1048576 True' 1 255)" = FAIL ]
grep -qx '        assert_proxy_workers_payload' "${BASH_SOURCE[0]%/*}/../lib/run-state.sh"
(
    rx() {
        python3 - "$1" <<'PY'
import contextlib
import io
import json
import os
import shlex
import sys
import types

command = shlex.split(sys.argv[1])
assert command[:5] == ["docker", "exec", "dashboard", "python3", "-c"]
assert len(command) == 6
for name in ("mining_dashboard", "mining_dashboard.client", "mining_dashboard.helper",
             "mining_dashboard.client.xmrig_proxy_client", "mining_dashboard.helper.http", "requests"):
    sys.modules[name] = types.ModuleType(name)
os.environ.update({"PROXY_HOST": "fixture", "PROXY_API_PORT": "3344", "PROXY_AUTH_TOKEN": "fixture-token"})
session = object()
calls = []
content = json.dumps({"workers": [{"name": "worker-one"}, {"name": "worker-two"}],
                      "padding": "é" * 90}, ensure_ascii=False).encode()

class Client:
    def __init__(self, host, port, token):
        assert (host, port, token) == ("fixture", 3344, "fixture-token")
        self.base_url = "http://fixture:3344"
        self.session = session

class Response:
    def __init__(self):
        self.content = content

    def raise_for_status(self):
        calls.append("status")

    def json(self):
        return json.loads(self.content)

def bounded_request(method, url, **kwargs):
    assert (method, url) == ("GET", "http://fixture:3344/1/workers")
    assert kwargs == {"timeout": 5, "session": session}
    calls.append("bounded")
    return Response()

sys.modules["mining_dashboard.client.xmrig_proxy_client"].XMRigProxyClient = Client
helper = sys.modules["mining_dashboard.helper.http"]
helper.MAX_RESPONSE_BYTES = 1048576
helper.bounded_request = bounded_request
output = io.StringIO()
with contextlib.redirect_stdout(output):
    exec(command[5], {})
assert calls == ["bounded", "status"]
assert output.getvalue() == f"{len(content)} 2 1048576 True\n"
print(output.getvalue(), end="")
PY
    }
    it_pass() { printf PASS; }
    it_fail() { printf FAIL; }
    [ "$(EXPECTED_WORKERS=2 assert_proxy_workers_payload)" = PASS ]
)
printf 'PASS: miner connection identity and bounded real-worker payload verdicts\n'

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
