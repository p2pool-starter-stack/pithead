#!/usr/bin/env bash
# Pure host recovery controls; fake systemd/Podman, real API decoder and clock window.
set -euo pipefail
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:?}}"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:?}/miner-recovery.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/stack" "$work/python/mining_dashboard/helper"
cat >"$work/bin/systemctl" <<'SH'
#!/bin/bash
case "$*" in
'is-active --quiet xmrig.service') [ "$MINER_ACTIVE" = true ] ;;
'--no-block try-restart xmrig.service') echo restart >>"$RECOVERY_CALLS"; exit "${RESTART_RC:-0}" ;;
*) exit 99 ;;
esac
SH
cat >"$work/bin/podman" <<'SH'
#!/bin/bash
[ "$1 $2 $3 $4 $5 $6" = 'exec -i dashboard python - fixture-local' ] || exit 99
shift 5
[ "${API_FAIL:-0}" = 0 ] || exit 1
exec python3 - "$@"
SH
cat >"$work/python/mining_dashboard/helper/http.py" <<'PY'
import json
import os
class Response:
    def raise_for_status(self):
        if os.environ.get("HTTP_FAIL") == "1":
            raise RuntimeError("unavailable")
    def json(self):
        return json.loads(os.environ["PROXY_WORKERS"])
def bounded_get(url, headers, timeout):
    assert url == "http://xmrig-proxy:3344/1/workers"
    assert headers == {"Authorization": "Bearer fixture-token"}
    assert timeout == 5
    return Response()
PY
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" PYTHONPATH="$work/python"
export PITHEAD_DIR="$work/stack" PITHEAD_MINER_RECOVERY_STATE="$work/state"
export PITHEAD_MINER_RECOVERY_UPTIME="$work/uptime" RECOVERY_CALLS="$work/calls"
export MINER_ACTIVE=true PROXY_AUTH_TOKEN=fixture-token PROXY_WORKERS='{"mode":"rig_id","workers":[]}'
export PROXY_HOST=xmrig-proxy PROXY_API_PORT=3344
export PITHEAD_MINER_RECOVERY_CONFIG="$work/worker.json"
printf '{"pools":[{"user":"fixture-local"}]}\n' >"$work/worker.json"
printf '{"local_miner":{"enabled":true}}\n' >"$work/stack/config.json"
tick() {
    printf '%s.00 0\n' "$1" >"$work/uptime"
    bash "$ROOT/os/overlay/pithead-miner-recovery" >"$work/output"
}
no_restart() { [ ! -s "$work/calls" ]; }
tick 100
tick 399
no_restart
tick 400
[ "$(cat "$work/calls")" = restart ]
grep -Fq 'disconnected for 300 seconds; restarting xmrig' "$work/output"
[ ! -e "$work/state" ]
rm "$work/calls"
tick 401
tick 700
no_restart
rm -f "$work/state"
# Every unavailable/healthy/intentional-stop reading discards accumulated evidence.
for condition in active disabled rig busy api http missing malformed string boolean negative connected; do
    tick 1000
    case "$condition" in
    active) export MINER_ACTIVE=false ;;
    disabled) printf '{"local_miner":{"enabled":false}}\n' >"$work/stack/config.json" ;;
    rig) echo rig >"$work/stack/machine-role" ;;
    busy)
        exec 8>"$work/stack/.pithead.lock"
        flock 8
        ;;
    api) export API_FAIL=1 ;;
    http) export HTTP_FAIL=1 ;;
    missing) export PROXY_WORKERS='{}' ;;
    malformed) export PROXY_WORKERS='invalid' ;;
    string) export PROXY_WORKERS='{"mode":"rig_id","workers":[["fixture-local","fixture","0"]]}' ;;
    boolean) export PROXY_WORKERS='{"mode":"rig_id","workers":[["fixture-local","fixture",false]]}' ;;
    negative) export PROXY_WORKERS='{"mode":"rig_id","workers":[["fixture-local","fixture",-1]]}' ;;
    connected) export PROXY_WORKERS='{"mode":"rig_id","workers":[["fixture-local","fixture",1],["fixture-rig","fixture",1]]}' ;;
    esac
    tick 1400
    no_restart
    [ ! -e "$work/state" ]
    export MINER_ACTIVE=true PROXY_WORKERS='{"mode":"rig_id","workers":[]}'
    unset API_FAIL HTTP_FAIL
    rm -f "$work/stack/machine-role"
    printf '{"local_miner":{"enabled":true}}\n' >"$work/stack/config.json"
    if [ "$condition" = busy ]; then
        flock -u 8
        exec 8>&-
    fi
    tick 1500
    no_restart
    rm -f "$work/state"
done
# A live rig must not mask the disconnected local miner, including a stale zero row.
for workers in '[["fixture-rig","fixture",1]]' '[["fixture-local","fixture",0],["fixture-rig","fixture",1]]'; do
    export PROXY_WORKERS="{\"mode\":\"rig_id\",\"workers\":$workers}"
    tick 1600
    tick 1899
    no_restart
    tick 1900
    [ "$(cat "$work/calls")" = restart ]
    rm "$work/calls"
done
# Rig IDs and user grouping both follow the real emitted pool identity.
printf '{"pools":[{"user":"fixture-local","rig-id":"fixture-id"}]}\n' >"$work/worker.json"
export PROXY_WORKERS='{"mode":"rig_id","workers":[["fixture-id","fixture",1]]}'
tick 1600
tick 1900
no_restart
export PROXY_WORKERS='{"mode":"user","workers":[["fixture-local","fixture",1]]}'
tick 1600
tick 1900
no_restart
export PROXY_WORKERS='{"mode":"none","workers":[]}'
tick 1600
tick 1900
no_restart
printf '{"pools":[{"user":"fixture-local"}]}\n' >"$work/worker.json"
export PROXY_WORKERS='{"mode":"rig_id","workers":[]}'
# A future/corrupt timestamp cannot request immediate recovery; a failed restart is visible.
echo 9999 >"$work/state"
tick 2000
no_restart
[ "$(cat "$work/state")" = 2000 ]
echo invalid >"$work/state"
tick 2001
no_restart
export RESTART_RC=1
if tick 2301; then
    echo 'FAIL: restart failure hidden'
    exit 1
fi
[ -e "$work/state" ]
# The image must ship, execute and enable the guard, not merely carry a source file.
for name in pithead-miner-recovery.service pithead-miner-recovery.timer; do
    grep -Fq "$name" "$ROOT/os/rootfs/Dockerfile"
done
grep -Fq '/usr/local/sbin/pithead-miner-recovery' "$ROOT/os/rootfs/Dockerfile"
grep -Fq 'ExecStart=/usr/local/sbin/pithead-miner-recovery' "$ROOT/os/overlay/pithead-miner-recovery.service"
grep -Fq 'OnUnitInactiveSec=30s' "$ROOT/os/overlay/pithead-miner-recovery.timer"
printf '%s\n' 'PASS: miner recovery debounce, refusals, decoder, failure and image wiring'

# The guest share assertion must reject health/job messages and consume only post-cursor logs.
# shellcheck source=tests/os/appliance-miner-recovery-leg.sh
source "$ROOT/tests/os/appliance-miner-recovery-leg.sh"
journalctl() {
    case "$*" in
    *'--show-cursor'*) printf 'old accepted (9/0)\n-- cursor: fixture-cursor\n' ;;
    *)
        [[ "$*" == *'--after-cursor fixture-cursor'* ]] || return 99
        printf '%b\n' "$SHARE_LOG"
        ;;
    esac
}
sleep() { SECONDS=$((SECONDS + 1000)); }
[ "$(miner_share_cursor)" = fixture-cursor ]
SHARE_LOG='new job; speed 1000; rejected (1/1)'
if wait_miner_share fixture-cursor >"$work/no-share"; then exit 1; fi
SHARE_LOG='accepted \033[1;32m(1/0)\033[0m'
wait_miner_share fixture-cursor
# Companion presence must be required throughout the recovery wait, even if shares exist.
proxy_companion_connected() { [ "$COMPANION_CONNECTED" = true ]; }
COMPANION_CONNECTED=false
if wait_miner_share fixture-cursor xmrig.service 1 >"$work/companion-lost"; then exit 1; fi
COMPANION_CONNECTED=true
wait_miner_share fixture-cursor xmrig.service 1
printf '%s\n' 'PASS: guest share proof enforces cursor, ANSI stripping and companion continuity'

# Failure after suspension must release the injected fault even after main's locals unwind.
cat >"$work/guest-cleanup.sh" <<'SH'
cd() { :; }
jq() { :; }
systemd-run() { :; }
timeout() { shift; "$@"; }
systemctl() {
    if [[ "$*" == *MainPID* ]]; then echo 123
    elif [ "$*" = 'is-active --quiet pithead-miner-recovery-companion.service' ]; then return 1; fi
}
journalctl() {
    if [[ "$*" == *--after-cursor* ]]; then
        printf '%s\n' 'accepted (1/0)' 'active local miner disconnected for 300 seconds; restarting xmrig'
    else echo '-- cursor: fixture-cursor'; fi
}
podman() {
    if [ -e "$CLEANUP_ROOT/inspected" ]; then echo new; else
        touch "$CLEANUP_ROOT/inspected"; echo old
    fi
}
docker() {
    if [ -e "$CLEANUP_ROOT/recreated" ]; then return 1; fi
    touch "$CLEANUP_ROOT/recreated"
}
kill() { printf '%s\n' "$*" >>"$CLEANUP_ROOT/signals"; }
SH
export GUEST_LEG="$ROOT/tests/os/appliance-miner-recovery-leg.sh" CLEANUP_ROOT="$work"
if BASH_ENV="$work/guest-cleanup.sh" bash -s <"$GUEST_LEG" >"$work/cleanup-output" 2>&1; then exit 1; fi
if [ ! -e "$work/signals" ]; then
    cat "$work/cleanup-output" >&2
    exit 1
fi
[ "$(cat "$work/signals")" = "$(printf '%s\n' '-STOP 123' '-CONT 123')" ]
printf '%s\n' 'PASS: failed guest recreation releases suspended miner after scope unwinds'

# Cleanup must not signal a replaced PID or accept a running companion after stop.
MINER_RECOVERY_STALLED_PID=123
MINER_RECOVERY_FIXTURE="$work/cleanup-fixture"
mkdir -p "$MINER_RECOVERY_FIXTURE"
COMPANION_ACTIVE=true
systemctl() {
    case "$*" in
    'show xmrig.service -p MainPID --value') echo 456 ;;
    'stop pithead-miner-recovery-companion.service') return 0 ;;
    'is-active --quiet pithead-miner-recovery-companion.service') [ "$COMPANION_ACTIVE" = true ] ;;
    esac
}
kill() {
    echo 'FAIL: cleanup signalled a replaced PID' >&2
    return 99
}
if miner_recovery_cleanup; then
    echo 'FAIL: cleanup accepted an active companion'
    exit 1
fi
[ ! -e "$work/wrong-pid-signal" ]
COMPANION_ACTIVE=false
miner_recovery_cleanup
# Readiness waits for provisioning and fails when the bounded wait expires.
READY=false
systemctl() { [ "$READY" = true ]; }
if wait_local_miner_ready >"$work/not-ready"; then exit 1; fi
READY=true
wait_local_miner_ready
printf '%s\n' 'PASS: cleanup rejects a live companion and readiness is bounded'
