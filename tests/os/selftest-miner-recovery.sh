#!/usr/bin/env bash
# Pure host recovery controls; fake systemd/Podman, real API decoder and clock window.
set -euo pipefail
export TMPDIR="${TMPDIR:-/tmp}"
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

# Exercise the guest's cleanup and by-design skip decisions with fake kernel/systemd commands.
# shellcheck source=tests/os/appliance-miner-recovery-leg.sh
source "$ROOT/tests/os/appliance-miner-recovery-leg.sh"
T3375="$work/strand"
mkdir "$T3375"
TABLE=true
nft() {
    case "$*" in
    'list table ip pithead_t3375') [ "$TABLE" = true ] ;;
    'delete table ip pithead_t3375') TABLE=false ;;
    *) return 99 ;;
    esac
}
miner_cleanup
[ "$TABLE" = false ] && [ ! -e "$T3375" ]
miner_delete_table
jq() { echo 3333; }
ss() { :; }
rc=0
miner_arm >"$work/skip" || rc=$?
[ "$rc" = 77 ] && grep -Fq 'SKIP: by-design' "$work/skip"
[ ! -e "$T3375" ] && [ "$TABLE" = false ]

# Execute real arming/verdict dispatch failures; kernel/systemd calls are the seams.
systemctl() {
    case "$*" in
    *MainPID*) echo 123 ;;
    *LoadState*) echo not-found ;;
    *) return 0 ;;
    esac
}
ss() { echo 'LISTEN 0 8 127.0.0.1:3333 0.0.0.0:*'; }
systemd-run() { touch "$T3375/ready" "$work/watcher-started"; }
nft() {
    case "$*" in
    '-f -')
        cat >/dev/null
        [ -e "$work/watcher-started" ] || return 99
        touch "$work/table"
        return 1
        ;;
    'list table ip pithead_t3375') [ -e "$work/table" ] ;;
    'delete table ip pithead_t3375')
        rm "$work/table"
        touch "$work/deleted"
        ;;
    *) return 99 ;;
    esac
}
rm -f "$work/deleted"
if (miner_guest_dispatch arm); then
    echo 'FAIL: failed nft arming passed'
    exit 1
fi
[ -e "$work/deleted" ] && [ ! -e "$work/table" ] && [ ! -e "$T3375" ]
mkdir "$T3375"
touch "$work/table"
rm "$work/deleted"
sleep() { SECONDS=$((SECONDS + 601)); }
if (miner_guest_dispatch verdict old); then
    echo 'FAIL: missing strand passed'
    exit 1
fi
[ -e "$work/deleted" ] && [ ! -e "$work/table" ] && [ ! -e "$T3375" ]
printf '%s\n' 'PASS: real arming/verdict failures delete the table; unavailable injection is a skip'
# Failed restoration retains the independent watchdog's recipe and recorded intent.
mkdir "$T3375"
touch "$T3375/watcher" "$T3375/leg.sh" "$work/table"
echo pithead-miner-recovery.timer >"$T3375/paused"
systemctl() {
    case "$*" in
    *LoadState*) echo loaded ;;
    'stop pithead-t3375-watcher.service') return 1 ;;
    'is-active --quiet pithead-t3375-watcher.service') return 0 ;;
    'start pithead-miner-recovery.timer') return 1 ;;
    *) return 99 ;;
    esac
}
if miner_cleanup; then
    echo 'FAIL: failed watchdog shutdown passed'
    exit 1
fi
[ -e "$T3375/leg.sh" ] && [ -e "$T3375/paused" ]
if miner_watch_restore; then
    echo 'FAIL: failed paused-unit restore passed'
    exit 1
fi
[ -e "$T3375/paused" ]
printf '%s\n' 'PASS: failed watchdog restoration retains its control files'
