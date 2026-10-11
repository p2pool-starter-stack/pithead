#!/usr/bin/env bash
# Pure convergence/timeout/reset-counter controls for the lifecycle mining post-step.
set -euo pipefail
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
