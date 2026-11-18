#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
COMPOSE="$ROOT/docker-compose.yml"
RECORDER="$ROOT/tests/integration/mini-stack/socks-recorder.py"
NET="pithead-socks-itest-$$"
MONERO_ADDR=44yQXfkWZNmJ8QgRfFWTzmJ8QgRfFWTzmJ8QgRfFWTzmJ7suhUXwdrDJ8QgRfFWTzmJ8QgRfFWTzmJ8QgRfFWTzmCYrSgjJ
VIEW1=0100000000000000000000000000000000000000000000000000000000000000
fails=0
SCRATCH="$(mktemp -d "${TMPDIR:-${RUNNER_TEMP:-/tmp}}/pithead-socks.XXXXXX")"
export TARI_WALLET_SECRET_FILE="$SCRATCH/tari-wallet-secret.env" WALLET_RPC_PASSWORD=itest
export TOR_DATA_DIR="$SCRATCH/tor" MONERO_DATA_DIR="$SCRATCH/monero" TARI_DATA_DIR="$SCRATCH/tari"
export P2POOL_DATA_DIR="$SCRATCH/p2pool" DASHBOARD_DATA_DIR="$SCRATCH/dashboard"
export PROXY_API_PORT=3344 PROXY_AUTH_TOKEN=itest

cleanup() {
    docker rm -f "$NET-socks" "$NET-wallet-domain" "$NET-wallet-ipv4" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    rm -rf "$SCRATCH"
}
trap cleanup EXIT

compose() { docker compose -p pithead-wallet-itest -f "$COMPOSE" --profile payout_confirm "$@"; }
compose build wallet-rpc
IMAGE="$(compose config --format json | jq -r '.services["wallet-rpc"].image')"
docker network create --internal "$NET" >/dev/null
docker run -d --name "$NET-socks" --network "$NET" --entrypoint python3 \
    -v "$RECORDER:/socks.py:ro" pithead-dashboard:itest -u /socks.py >/dev/null
PROXY_IP="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$NET-socks")"

start_wallet() {
    docker run -d --name "$NET-wallet-$1" --network "$NET" --read-only \
        --security-opt no-new-privileges:true --cap-drop ALL \
        --tmpfs /tmp:size=16m,mode=1777 --tmpfs /home/ubuntu/wallets:mode=1777 \
        -e PAYOUT_NODE_REMOTE=true -e "PAYOUT_NODE_PROXY=$PROXY_IP:1080" \
        -e "MONERO_NODE_HOST=$2" -e MONERO_RPC_PORT=18089 \
        -e MONERO_NODE_USERNAME=itest -e MONERO_NODE_PASSWORD=itest \
        -e WALLET_RPC_PASSWORD=itest -e PAYOUT_SCAN_HEIGHT=1 \
        -e "MONERO_WALLET_ADDRESS=$MONERO_ADDR" -e "MONERO_VIEW_KEY=$VIEW1" \
        --entrypoint /usr/local/bin/wallet-entrypoint.sh "$IMAGE" >/dev/null
}

recorded() {
    local end=$(($(date +%s) + 120)) line
    while [ "$(date +%s)" -lt "$end" ]; do
        line="$(docker logs "$NET-socks" 2>/dev/null | jq -c --arg h "$1" 'select(.host == $h)' 2>/dev/null | head -n1)"
        [ -z "$line" ] || {
            printf '%s\n' "$line"
            return 0
        }
        sleep 2
    done
    return 1
}

check() {
    local label="$1" filter="$2" record="$3"
    if jq -e "$filter" <<<"$record" >/dev/null 2>&1; then echo "  ✓ $label"; else
        echo "  ✗ $label: got [$record]"
        fails=$((fails + 1))
    fi
}

echo "== wallet SOCKS route: hostnames reach the proxy unresolved (#2866) =="
start_wallet domain node.example.com
start_wallet ipv4 203.0.113.7
domain="$(recorded node.example.com || true)"
ipv4="$(recorded 203.0.113.7 || true)"
check "an IP-literal node reaches the proxy as that IP (instrument control)" \
    '.type == "ipv4" and .port == 18089' "${ipv4:-null}"
check "a hostname node reaches the proxy as an unresolved domain" \
    '.type == "domain" and .host == "node.example.com" and .port == 18089' "${domain:-null}"
if [ "$fails" -ne 0 ]; then
    docker logs --tail 40 "$NET-wallet-domain" 2>&1 | tail -n 40 || true
    docker logs "$NET-socks" 2>&1 | tail -n 20 || true
fi
[ "$fails" -eq 0 ]
