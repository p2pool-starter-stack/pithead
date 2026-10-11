#!/usr/bin/env bash
# Pure convergence/timeout/reset-counter controls for the lifecycle mining post-step.
set -euo pipefail
echo "== lifecycle mining convergence and reset-counter controls =="
INTEGRATION_RUN_SUITE=1
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck source=tests/integration/lib/run-lifecycle-miners.sh
source "$ROOT/tests/integration/lib/run-lifecycle-miners.sh"
started=old
lifecycle_proxy_started() {
    if [ "${INSPECT_FAIL:-0}" = 1 ] && [ "$started" != old ]; then return 1; fi
    echo "$started"
}
api_state() {
    if [ "$started" = old ]; then
        echo '{"workers":[{"name":"local","status":"online","accepted":99},{"name":"rig","status":"online","accepted":99}]}'
    elif [ "$CASE" = malformed ]; then
        echo '{}'
    elif [ "$CASE" = missing ]; then
        echo '{"workers":[{"name":"rig","status":"online","accepted":1}]}'
    elif [ "$CASE" = shares ]; then
        echo '{"workers":[{"name":"local","status":"online","accepted":0},{"name":"rig","status":"online","accepted":1}]}'
    else echo '{"workers":[{"name":"local","status":"online","accepted":1},{"name":"rig","status":"online","accepted":1}]}'; fi
}
lifecycle_proxy_workers() {
    if [ "${LIVE_ZERO:-0}" = 1 ] && [ "$started" = new ]; then
        echo '[["local","fixture",0,0],["rig","fixture",1,1]]'
    else
        api_state | jq -ce '[.workers[] | [.name,"fixture",(if .status == "online" then 1 else 0 end),.accepted]]'
    fi
}
mutation() { started=new; }
sleep() { SECONDS=$((SECONDS + 601)); }
it_pass() { :; }
it_fail() { :; }
CASE=good
lifecycle_mining_step backup mutation
for CASE in missing shares malformed; do
    started=old
    if lifecycle_mining_step backup mutation; then
        echo "FAIL: $CASE accepted"
        exit 1
    fi
done
# A missing required precondition cannot become an empty-set pass.
unset LIFECYCLE_MINER_NAMES
started=new CASE=malformed
if lifecycle_mining_step backup mutation; then exit 1; fi
# Cached names cannot make malformed live preconditions pass.
LIFECYCLE_MINER_NAMES='["local","rig"]'
if lifecycle_mining_step backup mutation; then exit 1; fi
# A successful command with an unreadable post-step proxy cannot pass.
started=old CASE=good INSPECT_FAIL=1
if lifecycle_mining_step backup mutation; then exit 1; fi
unset INSPECT_FAIL
# The shared CLI hook checks intermediate applies individually, not only final state.
LIFECYCLE_MINING_ACTIVE=1 IT_PITHEAD=fixture
rx() { mutation; }
started=old CASE=missing
if pithead apply -y; then exit 1; fi
started=old CASE=good
pithead apply -y
# Cached dashboard counts cannot mask a disconnected local worker on the new proxy.
started=old CASE=good LIVE_ZERO=1
if pithead backup; then
    echo 'FAIL: cached state masked a live proxy zero'
    exit 1
fi
unset LIVE_ZERO
# An explicit down/up span retains its live worker names.
started=old
pithead down
[ "$LIFECYCLE_MINER_STOPPED" = 1 ]
pithead up
[ "$LIFECYCLE_MINER_STOPPED" = 0 ]
# Real reset/restore downs run in pipelines: retained state must survive the subshell.
work=$(mktemp -d "${TMPDIR:-/tmp}/lifecycle-miners.XXXXXX")
trap 'rm -rf "$work"' EXIT
LIFECYCLE_MINER_STATE="$work/state.json"
started=old CASE=good
pithead down | cat >/dev/null
lifecycle_mining_step restore mutation | cat >/dev/null
[ "$(jq -r .stopped "$LIFECYCLE_MINER_STATE")" = 1 ]
pithead up
[ "$(jq -r .stopped "$LIFECYCLE_MINER_STATE")" = 0 ]
SKIP_MINING_ASSERTS=1
lifecycle_mining_step backup mutation
printf '%s\n' 'PASS: lifecycle worker return, reset counters, refusal and mining opt-out'

# Exercise the real rx shell parsing and Python probe in both target modes.
# Only SSH delivery and container/API access are fake; the failing shell boundary is real.
(
    source "$ROOT/tests/integration/lib.sh"
    source "$ROOT/tests/integration/lib/run-lifecycle-miners.sh"
    mkdir -p "$work/transport space" "$work/python/mining_dashboard/helper" "$work/bin"
    cat >"$work/python/mining_dashboard/helper/http.py" <<'PY'
import json, os
class Response:
    def raise_for_status(self):
        if os.environ.get("PROBE_FAIL") == "1":
            raise RuntimeError("fixture unavailable")
    def json(self):
        return json.loads(os.environ["PROBE_BODY"])
def bounded_get(url, headers, timeout):
    assert url.endswith("/1/workers") and timeout == 5
    assert headers == {"Authorization": "Bearer fixture"}
    return Response()
PY
    cat >"$work/bin/docker" <<'SH'
#!/usr/bin/env bash
[ "$1 $2 $3 $4" = 'compose exec -T dashboard' ] || exit 99
shift 4
exec "$@"
SH
    chmod +x "$work/bin/docker"
    export PATH="$work/bin:$PATH"
    ssh() { bash -c "${!#}"; }
    export PYTHONPATH="$work/python" PROXY_HOST=fixture PROXY_API_PORT=1 PROXY_AUTH_TOKEN=fixture
    export PROBE_BODY='{"workers":[["local","fixture",1,1],["rig","fixture",1,1]]}'
    IT_REMOTE_DIR="$work/transport space" IT_SSH_DEST=fixture IT_SSH_OPTS=()
    for IT_MODE in local ssh; do
        rows=$(lifecycle_proxy_workers)
        [ "$rows" = '[["local", "fixture", 1, 1], ["rig", "fixture", 1, 1]]' ]
        [ "$(lifecycle_worker_set)" = '["local","rig"]' ]
        lifecycle_miners_returned '["local","rig"]' true
        PROBE_FAIL=1
        export PROBE_FAIL
        if lifecycle_proxy_workers >/dev/null 2>&1; then exit 1; fi
        unset PROBE_FAIL
        PROBE_BODY='{"workers":[["local","fixture",true,1]]}'
        if lifecycle_proxy_workers >/dev/null 2>&1; then exit 1; fi
        PROBE_BODY='{"workers":[["local","fixture",1,1],["rig","fixture",1,1]]}'
    done
)
printf '%s\n' 'PASS: real local/SSH probe parsing, fresh rows and strict response refusals'
