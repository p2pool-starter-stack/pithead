#!/usr/bin/env bash
# Synced remote-node guest: fresh shares through proxy recreation and a stalled active miner.
set -Eeuo pipefail
umask 077
trap 'printf "FAIL: miner recovery proof line %s exited %s\n" "$LINENO" "$?" >&2' ERR
miner_share_cursor() {
    local cursor
    cursor=$(journalctl -u xmrig.service -n 1 --show-cursor --no-pager -o cat |
        sed -n 's/^-- cursor: //p')
    [ -n "$cursor" ] || return 1
    printf '%s' "$cursor"
}
wait_miner_share() {
    local cursor=$1 unit=${2:-xmrig.service} end=$((SECONDS + 900))
    while [ "$SECONDS" -lt "$end" ]; do
        if [ "${3:-0}" = 1 ] && ! proxy_companion_connected; then
            printf '%s\n' 'FAIL: companion disconnected during local-miner recovery'
            return 1
        fi
        if journalctl -u "$unit" --after-cursor "$cursor" --no-pager -o cat |
            sed 's/\x1b\[[0-9;]*m//g' |
            grep -E 'accepted \([1-9][0-9]*/[0-9]+\)' >/dev/null; then
            return 0
        fi
        sleep 10
    done
    printf '%s\n' 'FAIL: no fresh accepted share within 900 seconds'
    return 1
}
wait_local_miner_ready() {
    local end=$((SECONDS + 1200))
    while [ "$SECONDS" -lt "$end" ]; do
        if systemctl is-active --quiet xmrig.service; then return 0; fi
        sleep 5
    done
    printf '%s\n' 'FAIL: local miner did not finish provisioning within 1200 seconds'
    return 1
}
proxy_companion_connected() {
    timeout 20 podman exec -i dashboard python - <<'PYTHON'
import os
import sys
from mining_dashboard.client.xmrig_proxy_client import XMRigProxyClient
try:
    client = XMRigProxyClient(os.environ["PROXY_HOST"], int(os.environ["PROXY_API_PORT"]),
                             os.environ.get("PROXY_AUTH_TOKEN"))
    workers = client.get_workers()["workers"]
    sys.exit(0 if any(row[0] == "kvm-companion-miner" and row[2] > 0 for row in workers) else 1)
except Exception:
    sys.exit(1)
PYTHON
}
miner_recovery_cleanup() {
    if [ "${MINER_RECOVERY_STALLED_PID:-0}" -gt 0 ] &&
        [ "$(systemctl show xmrig.service -p MainPID --value)" = "$MINER_RECOVERY_STALLED_PID" ]; then
        kill -CONT "$MINER_RECOVERY_STALLED_PID" 2>/dev/null || true
    fi
    local failed=0
    systemctl stop pithead-miner-recovery-companion.service >/dev/null 2>&1 || failed=1
    if systemctl is-active --quiet pithead-miner-recovery-companion.service; then failed=1; fi
    rm -rf -- "$MINER_RECOVERY_FIXTURE"
    return "$failed"
}
miner_recovery_exit() {
    local result=$?
    if ! miner_recovery_cleanup; then
        printf '%s\n' 'FAIL: companion miner cleanup failed' >&2
        if [ "$result" = 0 ]; then result=1; fi
    fi
    exit "$result"
}
miner_recovery_guest_main() {
    cd /data/pithead
    jq -e '.local_miner.enabled == true' config.json >/dev/null
    systemctl is-active --quiet pithead-miner-recovery.timer
    wait_local_miner_ready
    wait_miner_share "$(miner_share_cursor)"
    printf '%s\n' 'PASS: local miner accepts fresh shares before proxy recreation'
    # The published-port lifetime change that backup causes; no miner intervention.
    local before cursor pid recovery_cursor
    before=$(podman inspect --format '{{.Id}}' xmrig-proxy)
    docker compose up -d --force-recreate xmrig-proxy >/dev/null 2>&1
    [ "$(podman inspect --format '{{.Id}}' xmrig-proxy)" != "$before" ]
    cursor=$(miner_share_cursor)
    wait_miner_share "$cursor"
    printf '%s\n' 'PASS: local miner accepts fresh shares unattended after proxy recreation'
    # A second real stratum client stands in for the connected rig, using the baked binary.
    # Its own HTTP listener and file log are disabled; it cannot control the host miner.
    MINER_RECOVERY_FIXTURE=$(mktemp -d "${TMPDIR:?}/miner-recovery-companion.XXXXXX")
    MINER_RECOVERY_STALLED_PID=0
    trap miner_recovery_exit EXIT
    jq '.pools[0].user = "kvm-companion-miner" | .pools[0]["rig-id"] = "kvm-companion-miner" |
        .cpu.rx = [0] | .cpu["huge-pages"] = false | .cpu["memory-pool"] = false |
        .randomx["1gb-pages"] = false | .randomx.rdmsr = false | .randomx.wrmsr = false |
        .http.enabled = false | .autosave = false |
        del(."log-file")' /data/rigforge/data/worker/xmrig/build/config.json >"$MINER_RECOVERY_FIXTURE/config.json"
    recovery_cursor=$(journalctl -n 1 --show-cursor --no-pager -o cat | sed -n 's/^-- cursor: //p')
    [ -n "$recovery_cursor" ]
    systemd-run --quiet --collect --unit=pithead-miner-recovery-companion \
        --property=RuntimeMaxSec=30min \
        --property='ReadOnlyPaths=/sys/kernel/mm/hugepages /sys/devices/system/node' \
        /data/rigforge/data/worker/xmrig/build/xmrig --config "$MINER_RECOVERY_FIXTURE/config.json"
    wait_miner_share "$recovery_cursor" pithead-miner-recovery-companion.service
    proxy_companion_connected
    printf '%s\n' 'PASS: companion miner submits accepted shares while the local miner runs'
    # Deterministic active-but-idle control: suspend the client across a second recreation.
    # It cannot re-dial by itself. Only the production timer may replace it and resume shares.
    pid=$(systemctl show xmrig.service -p MainPID --value)
    [ "$pid" -gt 0 ]
    recovery_cursor=$(journalctl -n 1 --show-cursor --no-pager -o cat | sed -n 's/^-- cursor: //p')
    [ -n "$recovery_cursor" ]
    # EXIT cleanup keeps the fault reversible even after function locals unwind.
    MINER_RECOVERY_STALLED_PID=$pid
    kill -STOP "$pid"
    systemctl is-active --quiet xmrig.service
    docker compose up -d --force-recreate xmrig-proxy >/dev/null 2>&1
    cursor=$(miner_share_cursor)
    local companion_deadline=$((SECONDS + 120))
    until proxy_companion_connected; do
        [ "$SECONDS" -lt "$companion_deadline" ] || {
            printf '%s\n' 'FAIL: companion miner did not reconnect after recreation'
            return 1
        }
        sleep 5
    done
    wait_miner_share "$cursor" xmrig.service 1
    [ "$(systemctl show xmrig.service -p MainPID --value)" != "$pid" ]
    MINER_RECOVERY_STALLED_PID=0
    journalctl -u pithead-miner-recovery.service --after-cursor "$recovery_cursor" --no-pager -o cat |
        grep -F 'active local miner disconnected for 300 seconds; restarting xmrig' >/dev/null
    proxy_companion_connected
    wait_miner_share "$cursor" pithead-miner-recovery-companion.service
    miner_recovery_cleanup
    trap - EXIT
    printf '%s\n' 'PASS: production timer recovers stalled local miner with a connected companion and fresh shares'
}
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then miner_recovery_guest_main; fi
