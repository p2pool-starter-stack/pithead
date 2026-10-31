#!/usr/bin/env bash
set -euo pipefail
echo "== lifecycle mining convergence and reset-counter controls =="
INTEGRATION_RUN_SUITE=1
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck source=tests/integration/lib/run-lifecycle-miners.sh
source "$ROOT/tests/integration/lib/run-lifecycle-miners.sh"
# shellcheck source=tests/integration/lib/skip-accounting.sh
source "$ROOT/tests/integration/lib/skip-accounting.sh"
it_warn() { :; }
it_err() { :; }
started=old
lifecycle_proxy_started() {
    if [ -n "${PROXY_ABSENT_FILE:-}" ] && [ -e "$PROXY_ABSENT_FILE" ]; then return 1; fi
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
    if [ "${NO_WORKERS:-0}" = 1 ]; then
        echo '[]'
    elif [ "${LIVE_ZERO:-0}" = 1 ] && [ "$started" = new ]; then
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
unset LIFECYCLE_MINER_NAMES
started=new CASE=malformed
if lifecycle_mining_step backup mutation; then exit 1; fi
LIFECYCLE_MINER_NAMES='["local","rig"]'
if lifecycle_mining_step backup mutation; then exit 1; fi
started=old CASE=good INSPECT_FAIL=1
if lifecycle_mining_step backup mutation; then exit 1; fi
unset INSPECT_FAIL
LIFECYCLE_MINING_ACTIVE=1 IT_PITHEAD=fixture
rx() { mutation; }
started=old CASE=missing
if pithead apply -y; then exit 1; fi
started=old CASE=good
pithead apply -y
started=old CASE=good LIVE_ZERO=1
if pithead backup; then
    echo 'FAIL: cached state masked a live proxy zero'
    exit 1
fi
unset LIVE_ZERO
started=old
pithead down
[ "$LIFECYCLE_MINER_STOPPED" = 1 ]
pithead up
[ "$LIFECYCLE_MINER_STOPPED" = 0 ]
work=$(mktemp -d "${TMPDIR:-/tmp}/lifecycle-miners.XXXXXX")
trap 'rm -rf "$work"' EXIT
LIFECYCLE_MINER_STATE="$work/state.json"
started=old CASE=good
pithead down | cat >/dev/null
lifecycle_mining_step restore mutation | cat >/dev/null
[ "$(jq -r .stopped "$LIFECYCLE_MINER_STATE")" = 1 ]
pithead up
[ "$(jq -r .stopped "$LIFECYCLE_MINER_STATE")" = 0 ]
PROXY_ABSENT_FILE="$work/proxy-absent"
proxy_shutdown() { touch "$PROXY_ABSENT_FILE"; }
proxy_start() {
    rm -f "$PROXY_ABSENT_FILE"
    started=new
}
started=old CASE=good
lifecycle_mining_step config-reset proxy_shutdown | cat >/dev/null
[ "$(jq -r .stopped "$LIFECYCLE_MINER_STATE")" = 1 ]
[ "$(jq -c .names "$LIFECYCLE_MINER_STATE")" = '["local","rig"]' ]
lifecycle_mining_step down mutation
lifecycle_mining_step restore mutation
[ -e "$PROXY_ABSENT_FILE" ]
lifecycle_mining_step up proxy_start
[ ! -e "$PROXY_ABSENT_FILE" ]
[ "$(jq -r .stopped "$LIFECYCLE_MINER_STATE")" = 0 ]
unset PROXY_ABSENT_FILE
NO_WORKERS=1 started=old
skips=$IT_SKIPPED_LEGS
lifecycle_mining_step apply mutation
[ "$started" = new ] && [ "$IT_SKIPPED_LEGS" = "$((skips + 1))" ]
[ "$IT_SKIPPED_BY_DESIGN" = "$IT_SKIPPED_LEGS" ]
[[ "$IT_SKIPPED_NAMES" == *'no online workers before lifecycle mutation'* ]]
mutation_fails() {
    started=new
    return 7
}
if lifecycle_mining_step backup mutation_fails; then exit 1; else rc=$?; fi
[ "$rc" = 7 ] && [ "$IT_SKIPPED_LEGS" = "$((skips + 2))" ]
lifecycle_mining_step down mutation
lifecycle_mining_step restore mutation
[ "$(jq -r .stopped "$LIFECYCLE_MINER_STATE")" = 1 ]
lifecycle_mining_step up mutation
[ "$(jq -r .stopped "$LIFECYCLE_MINER_STATE")" = 0 ]
[ "$IT_SKIPPED_LEGS" = "$((skips + 5))" ]
unset NO_WORKERS
SKIP_MINING_ASSERTS=1
lifecycle_mining_step backup mutation
[ "$IT_SKIPPED_LEGS" = "$((skips + 6))" ]
if lifecycle_mining_step apply mutation_fails; then exit 1; else rc=$?; fi
[ "$rc" = 7 ] && [ "$IT_SKIPPED_LEGS" = "$((skips + 7))" ]
unset SKIP_MINING_ASSERTS
OUT_DIR="$work/results"
mkdir -p "$OUT_DIR"
_run_lifecycle() {
    phase_state=$LIFECYCLE_MINER_STATE
    case "$phase_state" in "$OUT_DIR"/*) return 99 ;; esac
    [ -d "${phase_state%/*}" ]
    LIFECYCLE_MINER_NAMES='["local"]'
    lifecycle_mining_save
    [ -s "$phase_state" ]
    return "$PHASE_RC"
}
export RUNNER_TEMP="$work/scratch"
mkdir -p "$RUNNER_TEMP"
for temporary_source in TMPDIR RUNNER_TEMP; do
    if [ "$temporary_source" = TMPDIR ]; then export TMPDIR="$RUNNER_TEMP"; else unset TMPDIR; fi
    for PHASE_RC in 0 7; do
        if run_lifecycle; then rc=0; else rc=$?; fi
        [ "$rc" = "$PHASE_RC" ] && [ ! -e "${phase_state%/*}" ]
        [[ "$phase_state" == "$RUNNER_TEMP"/* ]]
    done
done
export TMPDIR="$RUNNER_TEMP"
printf '%s\n' 'PASS: lifecycle worker return, reset counters, refusal and mining opt-out'

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
