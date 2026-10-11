#!/usr/bin/env bash
# Pure host recovery controls; fake systemd/Podman, real API decoder and clock window.
set -euo pipefail
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
[ "$*" = 'exec -i dashboard python -' ] || exit 99
[ "${API_FAIL:-0}" = 0 ] || exit 1
exec python3 -
SH
cat >"$work/python/mining_dashboard/helper/http.py" <<'PY'
import json
import os
class Response:
    def raise_for_status(self):
        if os.environ.get("HTTP_FAIL") == "1":
            raise RuntimeError("unavailable")
    def json(self):
        return json.loads(os.environ["PROXY_SUMMARY"])
def bounded_get(url, headers, timeout):
    assert url == "http://xmrig-proxy:3344/1/summary"
    assert headers == {"Authorization": "Bearer fixture-token"}
    assert timeout == 5
    return Response()
PY
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" PYTHONPATH="$work/python"
export PITHEAD_DIR="$work/stack" PITHEAD_MINER_RECOVERY_STATE="$work/state"
export PITHEAD_MINER_RECOVERY_UPTIME="$work/uptime" RECOVERY_CALLS="$work/calls"
export MINER_ACTIVE=true PROXY_AUTH_TOKEN=fixture-token PROXY_SUMMARY='{"miners":{"now":0}}'
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
    missing) export PROXY_SUMMARY='{}' ;;
    malformed) export PROXY_SUMMARY='invalid' ;;
    string) export PROXY_SUMMARY='{"miners":{"now":"0"}}' ;;
    boolean) export PROXY_SUMMARY='{"miners":{"now":false}}' ;;
    negative) export PROXY_SUMMARY='{"miners":{"now":-1}}' ;;
    connected) export PROXY_SUMMARY='{"miners":{"now":1}}' ;;
    esac
    tick 1400
    no_restart
    [ ! -e "$work/state" ]
    export MINER_ACTIVE=true PROXY_SUMMARY='{"miners":{"now":0}}'
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
printf '%s\n' 'PASS: guest share proof rejects non-share progress and strips ANSI after journal cursor'

# Failure after suspension must release the injected fault even after main's locals unwind.
cat >"$work/guest-cleanup.sh" <<'SH'
cd() { :; }
jq() { :; }
systemctl() { if [[ "$*" == *MainPID* ]]; then echo 123; fi; }
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
[ "$(cat "$work/signals")" = "$(printf '%s\n' '-STOP 123' '-CONT 123')" ]
printf '%s\n' 'PASS: failed guest recreation releases suspended miner after scope unwinds'
