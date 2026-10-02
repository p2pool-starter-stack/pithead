#!/usr/bin/env bash
# Selected-rig diagnostics retain only allowlisted observations, before restoration.
# shellcheck disable=SC2034  # harness globals are read by the sourced phase functions
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
INTEGRATION_RUN_SUITE=1
source "$HERE/../lib/run-rig-reverse.sh"
source "$HERE/../lib/run-rig-control.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT_DIR="$WORK"
STATE='{"workers":[{"name":"rig1","status":"offline","api_ok":false,"adopted":true,"token":"credential-marker","ip":"private-host-marker","rigforge":{"version":null,"stale":true,"generated_at":"2026-10-01T00:00:00Z","extra":"credential-marker"}},{"name":"other","rigforge":{"version":"present"}}]}'
STATE_RC=0
api_state() {
    printf '%s' "$STATE"
    return "$STATE_RC"
}

echo "== the predicate retains the exact final sample without changing its verdict =="
_pred_rig_present rig1
assert_rc "a stale selected feed still fails" "$?" 1
assert_eq "typed selected-worker observations survive" \
    "$(printf '%s' "${_RIG_SETUP_SAMPLE:-null}" | jq -c '[.worker_found,.status,.api_ok,.adopted,.rigforge_present,.version_present,.stale,.generated_at]')" \
    '[true,"offline",false,true,true,false,true,"2026-10-01T00:00:00Z"]'
assert_eq "unselected workers and arbitrary fields never survive" \
    "$(printf '%s' "${_RIG_SETUP_SAMPLE:-null}" | grep -Ec 'credential-marker|private-host-marker|rig1|other' || true)" "0"
STATE='{"workers":[]}'
_pred_rig_present rig1
assert_rc "an absent worker still fails" "$?" 1
assert_eq "an absent worker replaces the previous sample" "$(printf '%s' "${_RIG_SETUP_SAMPLE:-null}" | jq -r '.worker_found')" false
STATE='not-json credential-marker'
_pred_rig_present rig1
assert_rc "invalid state still fails" "$?" 1
assert_eq "invalid state is explicit" "$(printf '%s' "${_RIG_SETUP_SAMPLE:-null}" | jq -r '.state_valid')" false
STATE='' STATE_RC=28
_pred_rig_present rig1
assert_rc "a failed state transport still fails" "$?" 1
assert_eq "state transport exit survives" "$(printf '%s' "${_RIG_SETUP_SAMPLE:-null}" | jq -r '.state_transport_exit')" 28
STATE='{"workers":[{"name":"rig1","rigforge":{"version":"present"}}]}' STATE_RC=0
_pred_rig_present rig1
assert_rc "a current version still passes" "$?" 0
STATE_RC=7
_pred_rig_present rig1
assert_rc "valid stdout with a transport error preserves the existing predicate" "$?" 0
STATE_RC=0
STATE='{"workers":[{"name":"rig1","status":"credential-marker","api_ok":"credential-marker","rigforge":{"version":null,"stale":"credential-marker","generated_at":"credential-marker"}}]}'
_pred_rig_present rig1
assert_rc "missing version still fails with hostile fields" "$?" 1
assert_eq "hostile allowlisted values are rejected" "$(printf '%s' "${_RIG_SETUP_SAMPLE:-null}" | grep -c 'credential-marker' || true)" "0"

IT_MODE=local RIG_NAME=rig1 RIG_HOST=rig RIG_CONTROL_PORT=8082 RIGFORGE_BOOTSTRAP_VERSION='' RUN_RIGFORGE=0
BASELINE_CONFIG='{"workers":{"list":[{"name":"rig1","host":"rig"}]}}'
env_on_box() { case "$1" in COMPOSE_PROFILES) echo local_node ;; DASHBOARD_AUTH_HASH_B64) echo present ;; esac }
has_compose_profile() { return 0; }
push_config() { return 0; }
pithead() { return 0; }
wait_status_ok() { return 0; }
LOG_RC=0 LOG_PAD=0 LOG_PRODUCER=0
LOG_DETAIL='HTTP 200 but body was list' LOG_HOST=private-host-marker LOG_URL=credential-marker LOG_HINT=credential-marker
rx() {
    if [ "$1" = 'cat config.json' ]; then
        printf '%s' "$BASELINE_CONFIG"
        return
    fi
    printf '%s' "$1" >"$WORK/log-command"
    if [ "$LOG_PRODUCER" = 1 ]; then
        python3 - "$HERE/../../../dashboard/mining_dashboard/client/xmrig_client.py" "$RIG_NAME" "$LOG_DETAIL" "$LOG_HOST" "$LOG_URL" "$LOG_HINT" <<'PYTHON'
import ast
import pathlib
import sys

source = ast.parse(pathlib.Path(sys.argv[1]).read_text())
formats = [node.value for node in ast.walk(source)
           if isinstance(node, ast.Constant) and isinstance(node.value, str)
           and node.value.startswith("Worker %r (")]
assert len(formats) == 1
for name, detail in [(sys.argv[2], sys.argv[3]),
                     (sys.argv[2] + "-other", "HTTP 403"), ("other", "TimeoutError"),
                     (f"decoy Worker {sys.argv[2]!r} (suffix", "HTTP 403")]:
    print(formats[0] % (name, sys.argv[4], sys.argv[5], detail, sys.argv[6]))
PYTHON
        return "$LOG_RC"
    fi
    if [ "$LOG_PAD" = 1 ]; then printf '%65536s' ''; fi
    printf '%s\n' \
        "Worker 'rig1' (private-host-marker): xmrig API probe failed at credential-marker — HTTP 401. credential-marker." \
        "Worker 'rig1' (private-host-marker): xmrig API probe failed at credential-marker — TimeoutError: credential-marker. credential-marker." \
        "Worker 'rig1' (private-host-marker): xmrig API probe failed at credential-marker — probe token missing. credential-marker." \
        "Worker 'rig1' (private-host-marker): xmrig API probe failed at credential-marker — HTTP 500. credential-marker." \
        "Worker 'rig1' (private-host-marker): xmrig API probe failed at credential-marker — ClientConnectorError: credential-marker. credential-marker." \
        "Worker 'rig1' (private-host-marker): xmrig API probe failed at credential-marker — JSONDecodeError: credential-marker. credential-marker." \
        "Worker 'rig1' (private-host-marker): xmrig API probe failed at credential-marker — HTTP 200 but body was list. credential-marker." \
        "Worker 'rig1' (private-host-marker): xmrig API probe failed at credential-marker — body over 123 bytes. credential-marker." \
        "Worker 'rig1' (private-host-marker): xmrig API probe failed at credential-marker — unknown failure credential-marker. credential-marker." \
        "Worker 'other' (private-host-marker): xmrig API probe failed at credential-marker — HTTP 403. credential-marker." \
        'unrelated log credential-marker'
    return "$LOG_RC"
}
wait_for() {
    printf '%s|%s\n' "$1" "$2" >"$WORK/wait-bound"
    shift 3
    "$@"
    return 1
}
_restore_rig_control_baseline() {
    cp "$WORK/rigforge-control.selected-rig.json" "$WORK/before-restore.json"
    cp "$WORK/rigforge-control.probe-classes.json" "$WORK/before-restore-classes.json"
    STATE='restored'
}

echo "== setup failure captures both records before restoration =="
prior_fail=$IT_FAIL
run_rigforge_control >"$WORK/run.log" 2>&1
control_rc=$? control_fail=$((IT_FAIL - prior_fail))
IT_FAIL=$prior_fail
assert_rc "setup failure still returns nonzero" "$control_rc" 1
assert_eq "setup failure still counts one failed assertion" "$control_fail" 1
assert_eq "timeout and cadence remain unchanged" "$(cat "$WORK/wait-bound")" '120|5'
assert_eq "state record precedes restore" "$(jq -r '.worker_found' "$WORK/before-restore.json")" true
assert_eq "only selected-rig fixed classes survive" "$(jq -c . "$WORK/before-restore-classes.json")" \
    '{"log_read_exit":0,"classes":[{"classification":"connection","count":1},{"classification":"credential-unavailable","count":1},{"classification":"http-auth-refusal","count":1},{"classification":"http-response","count":1},{"classification":"invalid-body","count":2},{"classification":"other-probe-failure","count":1},{"classification":"oversized-body","count":1},{"classification":"timeout","count":1}]}'
assert_contains "dashboard log read has time and line bounds" "$(cat "$WORK/log-command")" 'timeout 5 docker logs --since 10m --tail=200 dashboard'
assert_eq "neither artifact contains raw identity or credential text" \
    "$(cat "$WORK/rigforge-control."*.json | grep -Ec 'credential-marker|private-host-marker|rig1' || true)" "0"
echo "== actual producer formatting selects accepted names with quotes and escapes =="
LOG_PRODUCER=1
for RIG_NAME in "rig'1" 'rig\1'; do
    BASELINE_CONFIG="$(jq -nc --arg n "$RIG_NAME" '{workers:{list:[{name:$n,host:"rig"}]}}')"
    STATE="$(jq -nc --arg n "$RIG_NAME" '{workers:[{name:$n,rigforge:{version:null}}]}')"
    prior_fail=$IT_FAIL
    run_rigforge_control >"$WORK/run.log" 2>&1
    control_rc=$? control_fail=$((IT_FAIL - prior_fail))
    IT_FAIL=$prior_fail
    assert_rc "quoted/escaped name preserves setup failure" "$control_rc" 1
    assert_eq "quoted/escaped name preserves one failed assertion" "$control_fail" 1
    assert_eq "actual producer selects only the requested name before restore" \
        "$(jq -c '.classes' "$WORK/before-restore-classes.json")" '[{"classification":"invalid-body","count":1}]'
    assert_eq "quoted/escaped worker state is captured before restore" \
        "$(jq -r '.worker_found' "$WORK/before-restore.json")" true
done
LOG_DETAIL='HTTP 500'
for context in name host url hint; do
    RIG_NAME=rig1 LOG_HOST=private-host-marker LOG_URL=credential-marker LOG_HINT=credential-marker
    case "$context" in
    name) RIG_NAME=JSONDecodeError ;;
    host) LOG_HOST=JSONDecodeError ;;
    url) LOG_URL='http://JSONDecodeError:8081/1/summary' ;;
    hint) LOG_HINT=JSONDecodeError ;;
    esac
    BASELINE_CONFIG="$(jq -nc --arg n "$RIG_NAME" '{workers:{list:[{name:$n,host:"rig"}]}}')"
    STATE="$(jq -nc --arg n "$RIG_NAME" '{workers:[{name:$n,rigforge:{version:null}}]}')"
    prior_fail=$IT_FAIL
    run_rigforge_control >"$WORK/run.log" 2>&1
    IT_FAIL=$prior_fail
    assert_eq "failure class comes from producer detail, independently of $context" \
        "$(jq -c '.classes' "$WORK/before-restore-classes.json")" '[{"classification":"http-response","count":1}]'
done
LOG_PRODUCER=0 RIG_NAME=rig1
BASELINE_CONFIG='{"workers":{"list":[{"name":"rig1","host":"rig"}]}}'
LOG_RC=7 STATE=''
prior_fail=$IT_FAIL
run_rigforge_control >"$WORK/run.log" 2>&1
IT_FAIL=$prior_fail
assert_eq "a failed dashboard-log read is explicit" "$(jq -r '.log_read_exit' "$WORK/before-restore-classes.json")" 7
LOG_RC=0 LOG_PAD=1
prior_fail=$IT_FAIL
run_rigforge_control >"$WORK/run.log" 2>&1
IT_FAIL=$prior_fail
assert_eq "warnings beyond the 64 KiB bound are excluded" "$(jq -c '.classes' "$WORK/before-restore-classes.json")" '[]'
wait_for() {
    OUT_DIR="$WORK/missing"
    return 1
}
_restore_rig_control_baseline() { touch "$WORK/restore-called"; }
prior_fail=$IT_FAIL
run_rigforge_control >"$WORK/run.log" 2>&1
control_rc=$? control_fail=$((IT_FAIL - prior_fail))
IT_FAIL=$prior_fail
assert_rc "failed capture leaves the original failure result" "$control_rc" 1
assert_eq "failed capture leaves the original assertion count" "$control_fail" 1
assert_eq "failed capture still restores" "$([ -f "$WORK/restore-called" ] && echo yes)" yes
assert_contains "failed state capture is visible" "$(cat "$WORK/run.log")" 'selected-rig state diagnostics could not be retained'
assert_contains "failed log classification capture is visible" "$(cat "$WORK/run.log")" 'selected-rig probe classifications could not be retained'
printf '\nselftest-rig-setup-diagnostics: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
