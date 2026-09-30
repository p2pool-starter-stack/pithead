#!/usr/bin/env bash
# A disposable native unit rendered by the shipped CLI. It has separate data, a private bridge
# network with no default route, a unique name and loopback host ports.
set -euo pipefail
no_default_route() {
    awk 'NR > 1 && $2 == "00000000" && $8 == "00000000" { default_route=1 } END { exit default_route }' "$1"
}
ipv4_only() {
    jq -e '.[0] | (if has("ipv6_enabled") then .ipv6_enabled else .EnableIPv6 end) == false' "$1" >/dev/null
}
cd /data/pithead
proof_dir=$(mktemp -d "${TMPDIR:-/run}/pithead-monero-rpc.XXXXXX")
proof_name="monerod-rpc-proof-${proof_dir##*.}"
unit="/run/containers/systemd/$proof_name.container"
if [ -e "$unit" ] || podman container exists "$proof_name" || podman container exists "$proof_name-client" || podman network exists "$proof_name"; then
    rm -rf "$proof_dir"
    exit 1
fi
cleanup() {
    local cleanup_rc=0 service_state
    systemctl stop "$proof_name.service" >/dev/null 2>&1 || cleanup_rc=1
    rm -f "$unit" || cleanup_rc=1
    systemctl daemon-reload || cleanup_rc=1
    podman rm -f "$proof_name" "$proof_name-client" >/dev/null 2>&1 || true
    if podman container exists "$proof_name" || podman container exists "$proof_name-client"; then
        echo 'FAIL: native Quadlet proof container could not be removed' >&2
        cleanup_rc=1
    fi
    podman network rm "$proof_name" >/dev/null 2>&1 || true
    if podman network exists "$proof_name"; then
        echo 'FAIL: native Quadlet proof network could not be removed' >&2
        cleanup_rc=1
    fi
    service_state=$(systemctl is-active "$proof_name.service" 2>/dev/null || true)
    case "$service_state" in
    inactive | failed | unknown) ;;
    *)
        echo 'FAIL: native Quadlet proof service did not stop' >&2
        cleanup_rc=1
        ;;
    esac
    rm -rf "$proof_dir" || cleanup_rc=1
    if [ "$cleanup_rc" -ne 0 ]; then exit "$cleanup_rc"; fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
chmod 700 "$proof_dir"
mkdir "$proof_dir/data"
chown 1000:1000 "$proof_dir/data"
image=$(podman inspect -f '{{.ImageName}}' monerod)
client_image=$(podman inspect -f '{{.ImageName}}' dashboard)
# --internal disables bridge forwarding, including mapped host ports. Keep managed
# forwarding for publication proof, but omit the default route and external DNS.
podman network create --disable-dns --opt no_default_route=1 "$proof_name" >/dev/null
network="$proof_name"
podman network inspect "$network" >"$proof_dir/network.json"
ipv4_only "$proof_dir/network.json"
# Refuse a routing mismatch before the fixture daemon can dial anything.
podman run --pull=never --rm --name "$proof_name-client" --network "$network" --entrypoint python3 "$client_image" \
    -c 'from pathlib import Path; print(Path("/proc/net/route").read_text(),end="")' >"$proof_dir/client-routes"
no_default_route "$proof_dir/client-routes"
echo 'PASS: native Quadlet fixture bridge is IPv4-only without a default route before startup'
grep -vE '^(QUADLET_HOST_CONFIG_DIR|QUADLET_CADDYFILE|QUADLET_ENGINE_SOCK|MONERO_OUT_PEERS|MONERO_CLEARNET_SYNC)=' .env >"$proof_dir/env"
printf '\nQUADLET_HOST_CONFIG_DIR=/data/pithead\nQUADLET_CADDYFILE=/data/pithead/Caddyfile\nQUADLET_ENGINE_SOCK=/run/podman/podman.sock\nMONERO_OUT_PEERS=0\nMONERO_CLEARNET_SYNC=false\n' >>"$proof_dir/env"
# This cold-start fixture has a real zero, not a synchronized-chain claim. It advertises no
# existing onion identity and never dials mainnet peers. The RPC split is unchanged.
sed -E '/^(anonymous-inbound|proxy|tx-proxy)=/d' build/monero/bitmonero.conf.template >"$proof_dir/template"
./pithead render-quadlet --env "$proof_dir/env" --out "$proof_dir/units" >/dev/null
mkdir -p /run/containers/systemd
# RPC config, login, healthcheck and runtime hardening remain the renderer's output.
# Fixture resource rewrites must each match exactly once before any node can start.
printf %s "$UNIT_FILTER_B64" | base64 -d >"$proof_dir/unit.awk"
awk -v data="$proof_dir/data" -v template="$proof_dir/template" -v image="$image" -v network="$network" -v name="$proof_name" \
    -f "$proof_dir/unit.awk" "$proof_dir/units/monerod.container" >"$unit"
chmod 600 "$unit"
[ "$(grep -cE '^Volume=.*:/home/ubuntu/\.bitmonero$' "$unit")" = 1 ]
grep -qxF "Volume=$proof_dir/data:/home/ubuntu/.bitmonero" "$unit"

systemctl daemon-reload
timeout 180 systemctl start "$proof_name.service" >/dev/null 2>&1
systemctl show "$proof_name.service" -p FragmentPath --value | grep -q '/generator'
# Verify isolation before any network probe; never infer it only from create options.
route_file="$proof_dir/routes"
podman exec "$proof_name" cat /proc/net/route >"$route_file"
no_default_route "$route_file"
echo 'PASS: native Quadlet fixture has no IPv4 default route'
echo 'PASS: native Quadlet cold start uses the rendered monerod unit'

admin=$(podman exec "$proof_name" /usr/local/bin/monerod-peers.sh)
printf '%s' "$admin" | jq -e '.outgoing == 0 and (.outgoing | type) == "number" and .incoming >= 0' >/dev/null
echo 'PASS: Quadlet local authenticated helper reads a real zero on cold start'
code=$(podman exec "$proof_name" curl -s --max-time 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:18085/get_info)
[ "$code" = 401 ]
echo 'PASS: Quadlet admin listener rejects unauthenticated local access'
restricted=$(podman exec "$proof_name" sh -c '
    printf "user = %s\n" "$(printf "%s:%s" "$MONERO_NODE_USERNAME" "$MONERO_NODE_PASSWORD" | jq -Rs .)" |
        curl -fsS --max-time 5 --digest --config - http://127.0.0.1:18081/get_info | jq -r .restricted')
[ "$restricted" = true ]
echo 'PASS: Quadlet network listener remains authenticated and restricted'
code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:38081/get_info)
[ "$code" = 401 ]
echo 'PASS: Quadlet published listener rejects unauthenticated access'
[ -z "$(podman port "$proof_name" 18085 2>/dev/null || true)" ]
node_ip=$(podman inspect "$proof_name" | jq -er '.[0].NetworkSettings.Networks | to_entries[0].value.IPAddress | select(length > 0)')
code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://$node_ip:18085/get_info" || true)
[ "$code" = 000 ]
podman run --pull=never --rm --name "$proof_name-client" --network "$network" --entrypoint python3 "$client_image" -c 'import socket,sys
try: socket.create_connection((sys.argv[1],18085),4)
except OSError: sys.exit(0)
sys.exit(1)' "$node_ip"
echo 'PASS: Quadlet admin listener is unpublished and unreachable from host and another container'
code=$(curl -gs --max-time 5 -o /dev/null -w '%{http_code}' 'http://[::1]:18085/get_info' || true)
[ "$code" = 000 ]
echo 'PASS: Quadlet admin listener is unreachable on every enabled address family'
advertised=$(printf %s "$P2P_PROBE_B64" | base64 -d | podman run --pull=never --rm -i --name "$proof_name-client" --network "$network" --entrypoint python3 "$client_image" - "$node_ip" 18080)
[ "$advertised" = 18081 ]
echo 'PASS: native Quadlet P2P handshake advertises restricted RPC port'

snapshot() {
    podman inspect "$proof_name" | jq -c '.[0] | {State:{StartedAt:.State.StartedAt,Health:(.State.Health // .State.Healthcheck)}}'
}
observation() {
    snapshot | podman run --pull=never --rm -i --name "$proof_name-client" --network "$network" --entrypoint python3 "$client_image" -c 'import json,sys
from mining_dashboard.collector.containers import parse_monero_peers,_epoch
p=json.load(sys.stdin)
r=parse_monero_peers(p)
assert type(r["peers_out"]) is int and r["peers_out"] == 0
end=_epoch(p["State"]["Health"]["Log"][-1]["End"])
assert parse_monero_peers(p,now=end+91) == {"peers_in":None,"peers_out":None}
print(p["State"]["StartedAt"])'
}
before=$(observation)
echo 'PASS: native Quadlet cold-start health observation is fresh; its expired snapshot is unavailable'
timeout 180 systemctl restart "$proof_name.service" >/dev/null 2>&1
admin=$(podman exec "$proof_name" /usr/local/bin/monerod-peers.sh)
printf '%s' "$admin" | jq -e '.outgoing == 0' >/dev/null
after=$(observation)
[ "$before" != "$after" ]
echo 'PASS: native Quadlet restart supplies a fresh observation from a new run'
echo 'PASS: native Quadlet RPC proof complete'
