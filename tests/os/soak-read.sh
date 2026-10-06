#!/usr/bin/env bash
# Fixed read-only remote collector for soak-probe.sh; streamed inside its one SSH session.
# --library loads pure parsers for the selftest, without collecting anything.
set -uo pipefail
soak_number() { # <key> <value>; never echo arbitrary API strings or secrets
    local v="$2"
    [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] || v='?'
    printf '%s=%s\n' "$1" "$v"
}
soak_memory() { # /proc/meminfo on stdin; KiB, as reported by the kernel
    local key value
    while read -r key value; do soak_number "$key" "$value"; done < <(
        awk 'BEGIN{a["MemTotal"]=a["MemAvailable"]=a["SwapTotal"]=a["SwapFree"]="?"}
            $1 ~ /^(MemTotal|MemAvailable|SwapTotal|SwapFree):$/ {k=$1; sub(/:$/, "", k); a[k]=$2}
            END{print "mem_total_kib", a["MemTotal"]; print "mem_available_kib", a["MemAvailable"];
                print "swap_total_kib", a["SwapTotal"]; print "swap_free_kib", a["SwapFree"]}'
    )
}
soak_firewall_canonical() { # stateless nft JSON on stdin
    # Keep static set elements; only dynamic set contents are observations, not policy.
    jq -ceS 'select(.nftables | type == "array") |
        select(any(.nftables[]; .table?.family == "inet" and .table?.name == "pithead_egress")) |
        .nftables |= map(select(has("metainfo") | not) |
            del(.table.handle, .chain.handle, .rule.handle, .set.handle, .map.handle) |
            if (.set.flags? // [] | index("dynamic")) != null then del(.set.elem) else . end)'
}
soak_sync_exemption() { # <network prefix>; live nft JSON on stdin
    jq -er --arg m "$1.26" --arg t "$1.27" '
        [.nftables[] | .rule? | select(.chain == "forward") | .expr |
            select(any(.[]; has("accept"))) |
            select(any(.[]; .match?.left?.payload?.protocol == "ip" and
                .match?.left?.payload?.field == "saddr" and
                (.match.right == $m or .match.right == $t))) |
            select(all(.[]; .match?.left?.payload?.field != "daddr"))] | length > 0'
}
soak_disk() { # <key> <configured data directory>; do not read outside /data
    local dir size='?'
    dir=$(realpath -e -- "$2" 2>/dev/null) || dir=''
    case "$dir" in /data/*) size=$(timeout 25 du -sx -B1M -- "$dir" 2>/dev/null | awk '{print $1}') ;; esac
    soak_number "$1" "$size"
}
soak_stats_file() { # <key> <file> <jq selector>
    local value
    value=$(jq -er "$3 | select(type == \"number\" and . >= 0)" "$2" 2>/dev/null) || value='?'
    soak_number "$1" "$value"
}
soak_monero() { # get_info JSON on stdin; no API string can forge a later reading
    local reading
    reading=$(jq -r '
        def n: if type == "number" and . >= 0 and . == floor then tostring else "?" end;
        def b: if type == "boolean" then tostring else "?" end;
        "h:\(.height | n) sync:\(.synchronized | b) peers:\(if .restricted == true then "restricted" else "\(.incoming_connections_count | n)/\(.outgoing_connections_count | n)" end)"
    ' 2>/dev/null) || reading=''
    printf 'monero=%s\n' "${reading:-h:? sync:? peers:?/?}"
}
soak_p2pool() { # <resolved data directory>
    soak_stats_file p2pool_hashrate "$1/stats/local/stratum" '.hashrate_15m'
    soak_stats_file p2pool_shares_found "$1/stats/local/stratum" '.shares_found'
    soak_stats_file p2pool_shares_failed "$1/stats/local/stratum" '.shares_failed'
    soak_stats_file p2pool_sidechain_height "$1/stats/pool/stats" '.pool_statistics.sidechainHeight'
}
soak_container_stats() { # formatted podman stats on stdin
    local name mem cpu count=0
    while IFS='|' read -r name mem cpu; do
        [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || continue
        [[ "$mem" =~ ^[0-9.[:space:]/kKMGTiB]+$ ]] || mem='?'
        [[ "$cpu" =~ ^[0-9.]+%?$ ]] || cpu='?'
        count=$((count + 1))
        printf 'container_stats=%s|%s|%s\n' "$name" "$mem" "$cpu"
    done
    [ "$count" -gt 0 ] || printf 'container_stats=?\n'
}
soak_api() {
    local api key value
    # Use the dashboard's installed gRPC client and proxy HTTP contract inside its running container.
    # Never dump a response, exception, worker identity, token, or address.
    api=$(
        timeout 20 podman exec -i dashboard python - <<'API'
import os
import grpc
import requests
from google.protobuf import empty_pb2
from mining_dashboard.client.tari.generated import base_node_pb2_grpc
values = {"tari_height": "?", "proxy_workers": "?", "proxy_accepted": "?", "proxy_rejected": "?"}
try:
    with grpc.insecure_channel(os.environ["TARI_GRPC_ADDRESS"]) as channel:
        tip = base_node_pb2_grpc.BaseNodeStub(channel).GetTipInfo(empty_pb2.Empty(), timeout=5)
        values["tari_height"] = tip.metadata.best_block_height
except Exception:
    pass
try:
    token = os.environ.get("PROXY_AUTH_TOKEN", "")
    headers = {"Authorization": "Bearer " + token} if token else {}
    url = "http://{}:{}/1/summary".format(os.environ.get("PROXY_HOST", "xmrig-proxy"), os.environ.get("PROXY_API_PORT", "3344"))
    response = requests.get(url, headers=headers, timeout=5)
    response.raise_for_status()
    summary = response.json()
    values.update(proxy_workers=summary.get("miners", {}).get("now", "?"),
                  proxy_accepted=summary.get("results", {}).get("accepted", "?"),
                  proxy_rejected=summary.get("results", {}).get("rejected", "?"))
except Exception:
    pass
for key, value in values.items():
    print("{}={}".format(key, value if isinstance(value, (int, float)) and not isinstance(value, bool) and value >= 0 else "?"))
API
    ) || api=''
    for key in tari_height proxy_workers proxy_accepted proxy_rejected; do
        value=$(printf '%s\n' "$api" | sed -n "s/^$key=//p" | head -1)
        # Remote/off Tari must not be represented as the local chain advancing.
        [ "$key" != tari_height ] || [ "$(env_get TARI_MODE)" = local ] || value='?'
        soak_number "$key" "$value"
    done
}
soak_tor() {
    local tor_progress tor_read
    tor_progress='?'
    if tor_read=$(timeout 8 podman exec tor /usr/local/bin/tor-healthcheck.sh 2>/dev/null); then
        tor_progress=100
    else
        tor_progress=$(printf '%s\n' "$tor_read" | sed -n 's/^Tor health: bootstrap progress=\([0-9]*\) tag=[a-z_]*[.]$/\1/p')
    fi
    soak_number tor_bootstrap_pct "$tor_progress"
}
[ "${1:-}" != --library ] || return 0
set -uo pipefail
printf 'btime=%s\n' "$(awk '/^btime/{print $2}' /proc/stat)"
printf 'jdirs=%s\n' "$(ls /var/log/journal 2>/dev/null | wc -l)"
printf 'uptime_s=%s\n' "$(awk '{print int($1)}' /proc/uptime)"
printf 'load=%s\n' "$(cut -d' ' -f1-3 /proc/loadavg | tr ' ' ',')"
printf 'data_free_mb=%s\n' "$(df -Pk /data 2>/dev/null | awk 'NR==2{print int($4/1024)}')"
printf 'rauc=%s\n' "$(rauc status --output-format=shell 2>/dev/null | awk -F= '/^RAUC_SYSTEM_BOOTED_BOOTNAME=/{b=$2} /^RAUC_BOOT_PRIMARY=/{p=$2} END{gsub(/\x27/,"",b); gsub(/\x27/,"",p); printf "%s/%s", b, p}')"
for c in $(podman ps -aq 2>/dev/null); do
    podman inspect -f 'container={{.Name}}|{{.State.Status}}|{{.RestartCount}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.State.StartedAt}}' "$c" 2>/dev/null
done
if [ -n "${SOAK_CURSOR:-}" ]; then
    printf 'ssh_window=cursor\n'
    printf 'ssh_accepted=%s\n' "$(journalctl -m -u ssh --after-cursor="$SOAK_CURSOR" --no-pager -q 2>/dev/null | grep -c 'Accepted ')"
else
    printf 'ssh_window=25h\n'
    printf 'ssh_accepted=%s\n' "$(journalctl -m -u ssh --since '-25h' --no-pager -q 2>/dev/null | grep -c 'Accepted ')"
fi
printf 'ssh_cursor=%s\n' "$(journalctl -m -u ssh -n1 --no-pager -q -o cat --show-cursor 2>/dev/null | sed -n 's/^-- cursor: //p')"
printf 'last_sessions=%s\n' "$(last -F 2>/dev/null | grep -v -c -E '^(reboot|wtmp|$)')"
env_get() { sed -n "s/^$1=//p" /data/pithead/.env 2>/dev/null | head -1 | tr -d '"'; }
mu=$(env_get MONERO_NODE_USERNAME)
mp=$(env_get MONERO_NODE_PASSWORD)
murl=$(env_get MONERO_RPC_URL)
[ -n "$murl" ] || murl=http://127.0.0.1:18081
if [ -n "$mu" ]; then body=$(curl -fsS --max-time 8 --digest -u "$mu:$mp" "$murl/get_info" 2>/dev/null); else body=$(curl -fsS --max-time 8 "$murl/get_info" 2>/dev/null); fi
printf '%s' "${body:-null}" | soak_monero
soak_memory </proc/meminfo
for pair in 'monero_chain_mib MONERO_DATA_DIR' 'tari_chain_mib TARI_DATA_DIR'; do
    read -r key envkey <<<"$pair"
    soak_disk "$key" "$(env_get "$envkey")"
done
pdir=$(realpath -e -- "$(env_get P2POOL_DATA_DIR)" 2>/dev/null) || pdir=/nonexistent
case "$pdir" in /data/*) ;; *) pdir=/nonexistent ;; esac
soak_p2pool "$pdir"
stats=$(timeout 10 podman stats --no-stream --format '{{.Name}}|{{.MemUsage}}|{{.CPU}}' 2>/dev/null) || stats=''
printf '%s\n' "$stats" | soak_container_stats
soak_api
soak_tor
listing='?'
canonical=''
hash='?'
present='?'
exemption='?'
if tables=$(timeout 5 nft list tables 2>/dev/null); then
    present=0
    if printf '%s\n' "$tables" | grep -qx 'table inet pithead_egress'; then
        present=1
        if listing=$(timeout 5 nft -s -j list table inet pithead_egress 2>/dev/null) &&
            canonical=$(printf '%s' "$listing" | soak_firewall_canonical); then
            hash=$(printf '%s\n' "$canonical" | sha256sum | awk '{print $1}')
            prefix=$(env_get NETWORK_PREFIX)
            if [[ "$prefix" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
                printf '%s' "$listing" | soak_sync_exemption "$prefix" >/dev/null 2>&1
                case "$?" in 0) exemption=1 ;; 1) exemption=0 ;; *) exemption='?' ;; esac
            fi
        else listing='?'; fi
    fi
fi
printf 'firewall_present=%s\nfirewall_hash=%s\nfirst_sync_exemption=%s\n' "$present" "$hash" "$exemption"
printf 'firewall_listing_b64=%s\n' "$(printf '%s\n' "$listing" | base64 | tr -d '\n')"
