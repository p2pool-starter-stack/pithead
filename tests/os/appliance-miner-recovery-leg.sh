#!/usr/bin/env bash
# Synced remote-node guest: fresh shares through proxy recreation and a stalled active miner.
set -euo pipefail
miner_share_cursor() {
    local cursor
    cursor=$(journalctl -u xmrig.service -n 1 --show-cursor --no-pager -o cat |
        sed -n 's/^-- cursor: //p')
    [ -n "$cursor" ] || return 1
    printf '%s' "$cursor"
}
wait_miner_share() {
    local cursor=$1 end=$((SECONDS + 900))
    while [ "$SECONDS" -lt "$end" ]; do
        if journalctl -u xmrig.service --after-cursor "$cursor" --no-pager -o cat |
            sed 's/\x1b\[[0-9;]*m//g' |
            grep -E 'accepted \([1-9][0-9]*/[0-9]+\)' >/dev/null; then
            return 0
        fi
        sleep 10
    done
    printf '%s\n' 'FAIL: no fresh accepted local-miner share within 900 seconds'
    return 1
}
miner_recovery_guest_main() {
    cd /data/pithead
    jq -e '.local_miner.enabled == true' config.json >/dev/null
    systemctl is-active --quiet pithead-miner-recovery.timer
    systemctl is-active --quiet xmrig.service
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
    # Deterministic active-but-idle control: suspend the client across a second recreation.
    # It cannot re-dial by itself. Only the production timer may replace it and resume shares.
    pid=$(systemctl show xmrig.service -p MainPID --value)
    [ "$pid" -gt 0 ]
    recovery_cursor=$(journalctl -n 1 --show-cursor --no-pager -o cat | sed -n 's/^-- cursor: //p')
    [ -n "$recovery_cursor" ]
    # On failure release the injected stall, without manually restarting the service.
    # Capture now: EXIT runs after the function's local variables have unwound.
    # shellcheck disable=SC2064
    trap "kill -CONT '$pid' 2>/dev/null || true" EXIT
    kill -STOP "$pid"
    systemctl is-active --quiet xmrig.service
    docker compose up -d --force-recreate xmrig-proxy >/dev/null 2>&1
    cursor=$(miner_share_cursor)
    wait_miner_share "$cursor"
    [ "$(systemctl show xmrig.service -p MainPID --value)" != "$pid" ]
    journalctl -u pithead-miner-recovery.service --after-cursor "$recovery_cursor" --no-pager -o cat |
        grep -F 'active local miner disconnected for 300 seconds; restarting xmrig' >/dev/null
    trap - EXIT
    printf '%s\n' 'PASS: production timer replaces stalled active miner and resumes accepted shares unattended'
}
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then miner_recovery_guest_main; fi
