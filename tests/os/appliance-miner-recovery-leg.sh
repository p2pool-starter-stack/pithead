#!/usr/bin/env bash
set -euo pipefail
umask 077
T3375=/run/pithead-t3375
BOUND_RECONNECT=${BOUND_RECONNECT:-480}
BOUND_STRAND=${BOUND_STRAND:-480}
BOUND_SHARE=${BOUND_SHARE:-600}
miner_local() { jq -er '.pools[0].user | select(type == "string" and length > 0)' /data/rigforge/data/worker/xmrig/build/config.json; }
miner_workers() {
    timeout 15 podman exec -i dashboard python - <<'PY'
import json, os
from mining_dashboard.helper.http import bounded_get
r = bounded_get("http://{}:{}/1/workers".format(os.environ["PROXY_HOST"], os.environ["PROXY_API_PORT"]),
                headers={"Authorization": "Bearer " + os.environ["PROXY_AUTH_TOKEN"]}, timeout=5)
r.raise_for_status()
body = r.json()
assert type(body["workers"]) is list
for row in body["workers"]:
    assert type(row) is list and len(row) >= 4
    assert type(row[0]) is str and all(type(n) is int and n >= 0 for n in row[2:4])
print(json.dumps(body["workers"]))
PY
}
miner_counts() {
    miner_workers | jq -ce --arg name "$(miner_local)" '[.[] | select(.[0] == $name)] | [([.[].[2]] | add // 0), ([.[].[3]] | add // 0)]'
}
miner_tuples() {
    local port=$1 pid=$2
    ss -Hntp state established "( dst 127.0.0.1 and dport = :$port )" |
        grep -F "pid=$pid," |
        awk '{for(i=1;i<=NF;i++) if ($i ~ /^127[.]0[.]0[.]1:[0-9]+$/) printf "%s ",$i; print ""}'
}
miner_stranded() {
    local port pid
    port=$(cat "$T3375/port") pid=$(systemctl show xmrig -p MainPID --value)
    [ "$pid" -gt 0 ] || return 1
    miner_tuples "$port" "$pid" | grep -Fvx -f "$T3375/before-tuples" >/dev/null || return 1
    ss -Hntl "sport = :$port" | awk '$2 >= 1 {found=1} END {exit !found}'
}
miner_delete_table() {
    if nft list table ip pithead_t3375 >/dev/null 2>&1; then
        nft delete table ip pithead_t3375
    fi
    ! nft list table ip pithead_t3375 >/dev/null 2>&1
}
miner_cleanup() {
    local failed=0 unit
    miner_delete_table || failed=1
    if [ -e "$T3375/watcher" ] && [ "$(systemctl show pithead-t3375-watcher.service -p LoadState --value)" != not-found ]; then
        systemctl stop pithead-t3375-watcher.service || failed=1
        if systemctl is-active --quiet pithead-t3375-watcher.service; then failed=1; fi
    fi
    if [ -e "$T3375/paused" ]; then
        while read -r unit; do systemctl start "$unit" || failed=1; done <"$T3375/paused"
    fi
    if [ "$failed" = 0 ]; then rm -rf "$T3375"; fi
    return "$failed"
}
miner_diagnostics() {
    local recorded=no
    [ ! -e "$T3375/strand" ] || recorded=yes
    printf 'pithead-t3375: failure phase=%s strand_recorded=%s\n' "${MINER_PHASE:-unknown}" "$recorded"
    printf 'pithead-t3375: local connections/accepted: '
    miner_counts || printf '%s\n' unreadable
    timeout 10 systemctl show pithead-t3375-watcher.service -p LoadState -p ActiveState -p Result -p ExecMainStatus || true
    timeout 10 journalctl --no-pager -n 40 --since '-20 minutes' -u pithead-t3375-watcher.service || true
    timeout 10 journalctl --no-pager -n 40 --since '-20 minutes' \
        -u pithead-miner-recovery.service -u xmrig.service || true
}
miner_guest_exit() {
    local rc=$?
    if [ "$rc" != 0 ]; then miner_diagnostics || true; fi
    local cleanup=verified recovery=no
    if ! miner_cleanup; then
        cleanup=failed
        rc=1
    fi
    if [ "$cleanup" = verified ] && [ "${MINER_BACKUP_APPLIED:-no}" = yes ]; then
        case "${MINER_FAILURE:-}" in reconnect-timeout | share-timeout) recovery=yes ;; esac
    fi
    printf 'pithead-t3375: verdict=%s cleanup=%s recovery_failure=%s\n' "${MINER_FAILURE:-passed}" "$cleanup" "$recovery"
    trap - EXIT
    exit "$rc"
}
miner_watch_restore() {
    local unit failed=0
    miner_delete_table || failed=1
    if [ -e "$T3375/paused" ]; then
        while read -r unit; do systemctl start "$unit" || failed=1; done <"$T3375/paused"
        if [ "$failed" = 0 ]; then rm -f "$T3375/paused"; fi
    fi
    return "$failed"
}
miner_watch() {
    local end=$((SECONDS + 1200))
    touch "$T3375/ready"
    while [ "$SECONDS" -lt "$end" ]; do
        if [ -e "$T3375/armed" ] && [ ! -e "$T3375/strand" ] && miner_stranded; then
            ss -Hntp state established >"$T3375/strand-sockets"
            if [ -n "${2:-}" ]; then
                if ! { miner_workers | jq -e --arg rig "$2" 'any(.[]; .[0] == $rig and .[2] >= 1)' >/dev/null &&
                    timeout 15 podman exec dashboard python -c 'from mining_dashboard.client.xmrig_proxy_client import XMRigProxyClient; import os; c=XMRigProxyClient(os.environ["PROXY_HOST"], int(os.environ["PROXY_API_PORT"]), os.environ["PROXY_AUTH_TOKEN"]); assert c.get_summary()["miners"]["now"] >= 1'; }; then
                    sleep 1
                    continue
                fi
            fi
            miner_delete_table
            printf '%s\n' recorded >"$T3375/strand"
            printf '%s\n' 'pithead-t3375: new miner ESTAB tuple and queued host listener witnessed; injection removed'

        fi
        sleep 1
    done
}

miner_arm() {
    local port
    port=$(jq -er '.pools[0].url | capture("^127[.]0[.]0[.]1:(?<port>[0-9]+)$").port' /data/rigforge/data/worker/xmrig/build/config.json)
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
    if ! ss -Hntl "sport = :$port" | grep -q .; then
        printf '%s\n' 'SKIP: by-design: no host LISTEN socket for the loopback strand'
        return 77
    fi
    [ ! -e "$T3375" ]
    mkdir "$T3375"
    trap miner_guest_exit EXIT
    printf '%s\n' "$port" >"$T3375/port"
    {
        printf '%s\n' 'set -euo pipefail' 'T3375=/run/pithead-t3375'
        declare -f miner_workers miner_tuples miner_stranded miner_delete_table miner_watch miner_watch_restore
        printf '%s\n' 'case "$1" in restore) miner_watch_restore ;; watch) miner_watch "$@" ;; esac'

    } >"$T3375/leg.sh"
    chmod 700 "$T3375/leg.sh"
    miner_tuples "$port" "$(systemctl show xmrig -p MainPID --value)" >"$T3375/before-tuples" || true
    touch "$T3375/watcher"
    systemd-run --quiet --collect --unit=pithead-t3375-watcher --property=RuntimeMaxSec=1200 \
        --property="ExecStopPost=/bin/bash $T3375/leg.sh restore" \
        bash "$T3375/leg.sh" watch "${1:-}" || return 1
    local end=$((SECONDS + 10))
    until [ -e "$T3375/ready" ]; do
        [ "$SECONDS" -lt "$end" ] || return 1
        sleep 1
    done
    nft -f - <<NFT || return 1
add table ip pithead_t3375
add chain ip pithead_t3375 output { type nat hook output priority -150; policy accept; }
add rule ip pithead_t3375 output ip daddr 127.0.0.1 tcp dport $port dnat to 127.0.0.1:$port
NFT
    touch "$T3375/armed"
    trap - EXIT

}
miner_precondition() {
    local before now end=$((SECONDS + 1200))
    jq -e '.local_miner.enabled == true' /data/pithead/config.json >/dev/null || return 1
    while ! systemctl is-active --quiet xmrig; do
        [ "$SECONDS" -lt "$end" ] || return 1
        sleep 5
    done
    before=$(miner_counts | jq -er '.[1]') || return 1
    end=$((SECONDS + 600))
    while [ "$SECONDS" -lt "$end" ]; do
        now=$(miner_counts) || now='[0,0]'
        if jq -e --argjson old "$before" '.[0] >= 1 and .[1] > $old' <<<"$now" >/dev/null; then return; fi
        sleep 5
    done
    return 1
}
miner_fidelity() {
    local unit end count current
    trap miner_guest_exit EXIT
    : >"$T3375/paused"
    for unit in pithead-miner-recovery.timer pithead-miner-recovery.service; do
        if systemctl is-active --quiet "$unit"; then
            printf '%s\n' "$unit" >>"$T3375/paused"
            systemctl stop "$unit"
        fi
    done
    systemctl restart xmrig
    end=$((SECONDS + 60))
    until [ -e "$T3375/strand" ]; do
        [ "$SECONDS" -lt "$end" ] || return 1
        sleep 1
    done
    miner_stranded
    count=$(miner_counts)
    end=$((SECONDS + 180))
    while [ "$SECONDS" -lt "$end" ]; do
        miner_stranded
        current=$(miner_counts)
        [ "$current" = "$count" ] && [ "$(jq -r '.[0]' <<<"$current")" = 0 ] || return 1
        sleep 5
    done
    printf '%s\n' 'PASS: fidelity strand persisted for 180 seconds with recovery paused'
    miner_cleanup
    trap - EXIT
    systemctl restart xmrig
    miner_precondition
}
miner_failure() {
    MINER_FAILURE=$1
    printf 'pithead-t3375: failure_reason=%s\n' "$MINER_FAILURE"
    return 1
}
miner_watchdog_receipt() {
    local unit load active enabled digest=absent
    if [ -e /usr/local/sbin/pithead-miner-recovery ]; then
        digest=$(sha256sum /usr/local/sbin/pithead-miner-recovery) || return 1
        digest=${digest%% *}
        [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    fi
    printf 'pithead-t3375: watchdog_sha256=%s\n' "$digest"
    for unit in pithead-miner-recovery.service pithead-miner-recovery.timer; do
        load=$(systemctl show "$unit" -p LoadState --value) || return 1
        active=$(systemctl show "$unit" -p ActiveState --value) || return 1
        enabled=$(systemctl is-enabled "$unit" 2>/dev/null) || true
        case "$load" in loaded | not-found | masked) ;; *) return 1 ;; esac
        case "$active" in active | inactive | activating | deactivating | failed) ;; *) return 1 ;; esac
        case "$enabled" in enabled | disabled | static | masked | not-found) ;; *) return 1 ;; esac
        printf 'pithead-t3375: watchdog_unit=%s load=%s active=%s enabled=%s\n' "$unit" "$load" "$active" "$enabled"
        if [ "$digest" = absent ]; then
            [ "$load:$active:$enabled" = not-found:inactive:not-found ] || return 1
        else
            [ "$load" = loaded ] || return 1
            if [ "$unit" = pithead-miner-recovery.timer ]; then
                [ "$active:$enabled" = active:enabled ] || return 1
            fi
        fi
    done
    if [ "$digest" = absent ]; then
        printf '%s\n' 'pithead-t3375: watchdog_absence=verified'
    fi
}
miner_verdict() {
    local before=$1 end=$((SECONDS + BOUND_STRAND)) counts='' connected=0
    MINER_FAILURE=incomplete
    MINER_BACKUP_APPLIED=no
    trap miner_guest_exit EXIT
    [ -e "$T3375/backup-applied" ] || {
        miner_failure backup-not-applied
        return 1
    }
    MINER_BACKUP_APPLIED=yes
    printf '%s\n' 'pithead-t3375: backup=applied'
    miner_watchdog_receipt || {
        miner_failure watchdog-state-unreadable
        return 1
    }
    until [ -e "$T3375/strand" ]; do
        [ "$SECONDS" -lt "$end" ] || {
            miner_failure strand-timeout
            return 1
        }
        sleep 1
    done
    printf '%s\n' 'pithead-t3375: strand=observed'
    [ "$(podman inspect --format '{{.Id}}' xmrig-proxy)" = "$(cat "$T3375/proxy-id")" ] || {
        miner_failure proxy-identity-changed
        return 1
    }
    [ "$(podman inspect --format '{{.State.StartedAt}}' xmrig-proxy)" != "$before" ] || {
        miner_failure proxy-not-restarted
        return 1
    }
    printf '%s\n' 'pithead-t3375: proxy_identity=same proxy_start=changed'
    end=$((SECONDS + BOUND_RECONNECT))
    while [ "$SECONDS" -lt "$end" ]; do
        counts=$(miner_counts) || counts=''
        if [ -n "${2:-}" ]; then
            miner_workers | jq -e --arg rig "$2" 'any(.[]; .[0] == $rig and .[2] >= 1)' >/dev/null || {
                miner_failure rig-disconnected
                return 1
            }
        fi
        if [ -n "$counts" ] && [ "$(jq -r '.[0]' <<<"$counts")" -ge 1 ]; then
            connected=1
            break
        fi
        sleep 5
    done
    [ -n "$counts" ] || {
        miner_failure workers-unreadable
        return 1
    }
    [ "$connected" = 1 ] || {
        miner_failure reconnect-timeout
        return 1
    }
    printf '%s\n' 'pithead-t3375: local_reconnection=observed'
    end=$((SECONDS + BOUND_SHARE))
    while [ "$SECONDS" -lt "$end" ]; do
        counts=$(miner_counts) || counts=''
        if [ -n "${2:-}" ]; then
            miner_workers | jq -e --arg rig "$2" 'any(.[]; .[0] == $rig and .[2] >= 1)' >/dev/null || {
                miner_failure rig-disconnected
                return 1
            }
        fi
        if jq -e '.[0] >= 1 and .[1] >= 1' <<<"$counts" >/dev/null; then
            MINER_FAILURE=passed
            printf '%s\n' 'pithead-t3375: accepted_share=observed'
            return 0
        fi
        sleep 5
    done
    [ -n "$counts" ] || {
        miner_failure workers-unreadable
        return 1
    }
    miner_failure share-timeout
}
miner_guest_dispatch() {
    MINER_PHASE=${1:-unknown}
    case "${1:-}" in
    precondition)
        if miner_precondition; then
            printf '%s\n' 'pithead-t3375: precondition=verified'
        else
            miner_failure precondition-failed
        fi
        ;;
    arm)
        trap 'miner_delete_table' ERR
        miner_arm "${2:-}"
        ;;
    watch) miner_watch "$@" ;;
    fidelity) miner_fidelity ;;
    identity) podman inspect --format '{{.Id}} {{.State.StartedAt}}' xmrig-proxy ;;
    backup-ready)
        podman inspect --format '{{.Id}}' xmrig-proxy >"$T3375/proxy-id"
        ;;
    backup-applied) touch "$T3375/backup-applied" ;;
    verdict) miner_verdict "$2" "${3:-}" ;;
    cleanup) miner_cleanup ;;
    *) exit 64 ;;
    esac
}
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then miner_guest_dispatch "$@"; fi
