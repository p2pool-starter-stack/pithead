#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if ! docker compose version >/dev/null 2>&1; then
    echo "FAIL: docker compose is required"
    exit 1
fi
ENV_FILE="$(mktemp)"
trap 'rm -f "$ENV_FILE"' EXIT
fails=0
render() {
    local profiles="$1" host="$2" port="$3"
    shift 3
    {
        cat <<'EOF'
MONERO_DATA_DIR=/srv/data/monero
TARI_DATA_DIR=/srv/data/tari
P2POOL_DATA_DIR=/srv/data/p2pool
DASHBOARD_DATA_DIR=/srv/data/dashboard
TOR_DATA_DIR=/srv/data/tor
MONERO_NODE_USERNAME=monero
MONERO_NODE_PASSWORD=secret
MONERO_WALLET_ADDRESS=49Wallet
TARI_WALLET_ADDRESS=TWallet
MONERO_ONION_ADDRESS=a.onion
TARI_ONION_ADDRESS=b.onion
TARI_MEM_LIMIT=2048m
MONERO_MEM_LIMIT=3g
P2POOL_ONION_ADDRESS=c.onion
P2POOL_FLAGS=
P2POOL_PORT=37889
STRATUM_BIND=0.0.0.0
XVB_POOL_URL=na.xmrvsbeast.com:4247
XVB_DONOR_ID=49Wallet
XVB_ENABLED=true
P2POOL_URL=172.28.0.28:3333
PROXY_API_PORT=3344
PROXY_AUTH_TOKEN=token
PROXY_STRATUM_PASSWORD=hunter2
PROXY_DONATE_LEVEL=1
MONERO_PRUNE=1
MONERO_PREP_THREADS=4
MONERO_RPC_BIND=127.0.0.1
MONERO_ZMQ_BIND=127.0.0.1
MONERO_RPC_URL=http://monero.example:28081
MONERO_ZMQ_PORT=18083
TARI_GRPC_ADDRESS=172.28.0.27:18142
TARI_GRPC_BIND=127.0.0.1
TOR_COMPOSE_PROFILES=local_node,local_tari
DASHBOARD_SECURE=true
HOST_IP=box.lan
EOF
        printf 'COMPOSE_PROFILES=%s\nMONERO_NODE_HOST=%s\nMONERO_RPC_PORT=%s\n' "$profiles" "$host" "$port"
        [ "$#" -eq 0 ] || printf '%s\n' "$@"
    } >"$ENV_FILE"
    docker compose --env-file "$ENV_FILE" -f "$ROOT/docker-compose.yml" config --format json 2>/dev/null
}
jq_assert() {
    if jq -e "$2" <<<"$3" >/dev/null 2>&1; then echo "  ✓ $1"; else
        echo "  ✗ $1: failed [$2]"
        fails=$((fails + 1))
    fi
}

echo "== compose: remote-node payout wallet render (#2866) =="
LOCAL="$(render local_node,payout_confirm 172.28.0.26 18081)"
jq_assert "local-node wallet-rpc keeps the bundled node endpoint and no proxy" \
    '.services["wallet-rpc"].environment | .MONERO_NODE_HOST == "172.28.0.26" and .MONERO_RPC_PORT == "18081" and .PAYOUT_NODE_REMOTE == "false" and .PAYOUT_NODE_PROXY == ""' "$LOCAL"
jq_assert "local-node wallet-rpc still waits for a healthy monerod" \
    '.services["wallet-rpc"].depends_on.monerod.condition == "service_healthy"' "$LOCAL"
REMOTE="$(render payout_confirm 192.0.2.10 28081 PAYOUT_NODE_REMOTE=true PAYOUT_NODE_PROXY=172.28.0.25:9050)"
jq_assert "remote-node wallet-rpc renders without a local monerod and with no required dependency on it" \
    '(.services["wallet-rpc"] != null) and (.services.monerod == null) and (((.services["wallet-rpc"].depends_on // {}).monerod // {required: false}).required == false)' "$REMOTE"
jq_assert "remote-node wallet-rpc scans the configured node through the rendered proxy" \
    '.services["wallet-rpc"].environment | .MONERO_NODE_HOST == "192.0.2.10" and .MONERO_RPC_PORT == "28081" and .PAYOUT_NODE_REMOTE == "true" and .PAYOUT_NODE_PROXY == "172.28.0.25:9050"' "$REMOTE"
jq_assert "remote-node wallet-rpc keeps its loopback-only publish and an empty command line" \
    '.services["wallet-rpc"] | (.command // null) == null and (.ports | all(.host_ip == "127.0.0.1"))' "$REMOTE"
jq_assert "no remote-node render carries a spend key" \
    '[.services["wallet-rpc"].environment | keys[] | select(test("SPEND"; "i"))] | length == 0' "$REMOTE"
[ "$fails" -eq 0 ]
