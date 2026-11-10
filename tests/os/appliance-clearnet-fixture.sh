# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034
CLEARNET_FIXTURE_DIAG=""

_control_apply_idle() { # [seconds]
    local deadline=$(($(date +%s) + ${1:-60})) SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}"
    while :; do
        _ssh '[ "$(systemctl is-active pithead-control.service)" != activating ] && flock -n /data/pithead/.pithead.lock true' && return 0
        [ "$(date +%s)" -lt "$deadline" ] || break
        sleep 3
    done
    CLEARNET_FIXTURE_DIAG="the control runner or the mutation lock stayed busy for the whole wait"
    return 1
}

reserved_node_clearnet_fixture() {
    CLEARNET_FIXTURE_DIAG=""
    for _ in 1 2; do
        _control_requests_drained && _control_apply_idle || return 1
        CLEARNET_FIXTURE_DIAG=$(approval_restore_step clearnet-apply _ssh 'set -euo pipefail
cd /data/pithead
jq ".p2pool.clearnet = true" config.json >config.json.os2333-clearnet
chmod 600 config.json.os2333-clearnet
mv config.json.os2333-clearnet config.json
./pithead apply -y
jq -e ".p2pool.clearnet == true" config.json >/dev/null') && return 0
    done
    return 1
}

# The fixture waits for an idle control runner, retries one failed apply, and reports the apply's exit and tail.
_clearnet_fixture_self_test() (
    local idle_probes=0 now=0 f=0 count
    count=$(mktemp)
    trap 'rm -f "$count"' RETURN
    date() { echo "$now"; }
    sleep() { now=$((now + 3)); }
    _ssh() { idle_probes=$((idle_probes + 1)); [ "$idle_probes" -gt "$busy_probes" ]; }
    busy_probes=2
    _control_apply_idle 60 || f=$((f + 1))
    busy_probes=999 idle_probes=0 now=0
    _control_apply_idle 9 && f=$((f + 1))
    _control_requests_drained() { return 0; }
    _control_apply_idle() { return 0; }
    approval_restore_step() {
        echo >>"$count"
        [ "$(wc -l <"$count")" -gt "$fail_calls" ] && return 0
        printf 'approval restore operation=clearnet-apply exit=1\n[ERROR] apply conflict\n'
        return 1
    }
    fail_calls=1
    reserved_node_clearnet_fixture || f=$((f + 1))
    [ "$(wc -l <"$count")" -eq 2 ] || f=$((f + 1))
    fail_calls=5
    : >"$count"
    reserved_node_clearnet_fixture && f=$((f + 1))
    [ "$(wc -l <"$count")" -eq 2 ] || f=$((f + 1))
    case "$CLEARNET_FIXTURE_DIAG" in *'exit=1'*'apply conflict'*) ;; *) f=$((f + 1)) ;; esac
    [ "$f" -eq 0 ]
)
