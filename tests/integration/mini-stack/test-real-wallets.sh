#!/usr/bin/env bash
# Tier 3: the production Compose wallet services and pinned binaries, with fresh volumes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
COMPOSE="$ROOT/docker-compose.yml"
PROBE="$ROOT/tests/integration/mini-stack/real-wallet-probe.py"
SCRATCH_BASE="${TMPDIR:-${RUNNER_TEMP:?set TMPDIR or RUNNER_TEMP}}"
SCRATCH="$(mktemp -d "$SCRATCH_BASE/pithead-wallets.XXXXXX")"
export TARI_WALLET_SECRET_FILE="$SCRATCH/tari-wallet-secret.env"
export WALLET_RPC_PASSWORD=itest PAYOUT_SCAN_HEIGHT=1 TARI_WALLET_BIRTHDAY=0
# Compose interpolates all services even with --no-deps; these unused paths stay in scratch.
export TOR_DATA_DIR="$SCRATCH/tor" MONERO_DATA_DIR="$SCRATCH/monero" TARI_DATA_DIR="$SCRATCH/tari"
export P2POOL_DATA_DIR="$SCRATCH/p2pool" DASHBOARD_DATA_DIR="$SCRATCH/dashboard"
export PROXY_API_PORT=3344 PROXY_AUTH_TOKEN=itest
# Public test vectors from scalar 1. The private view keys below are synthetic; no funds use them.
MONERO_ADDR=44yQXfkWZNmJ8QgRfFWTzmJ8QgRfFWTzmJ8QgRfFWTzmJ7suhUXwdrDJ8QgRfFWTzmJ8QgRfFWTzmJ8QgRfFWTzmCYrSgjJ
TARI_ADDR=12M2aZjsSvTTcaFyzLxARkvwdxv8UHJeJBA6E1pEoP967ydCL8tv17vktNDHhqDgFg5LxtHrp9Wsd1cuhyW1p6fzimM
VIEW1=0100000000000000000000000000000000000000000000000000000000000000
VIEW2=0200000000000000000000000000000000000000000000000000000000000000
SPEND=e2f2ae0a6abc4e71a884a961c500515f58e30b6aa582dd8db6a65945e08d2d76
OLD_VOLUME="pithead-wallet-red-$$"
export MONERO_WALLET_ADDRESS="$MONERO_ADDR" TARI_WALLET_ADDRESS="$TARI_ADDR" MONERO_VIEW_KEY="$VIEW1"

compose() { docker compose -p pithead-wallet-itest -f "$COMPOSE" --profile payout_confirm --profile tari_payout_confirm "$@"; }
# The production Compose file names this network globally. Never attach test wallets to a live stack.
if docker network inspect mining_net >/dev/null 2>&1; then
    echo 'FAIL: mining_net already exists; real-wallet test needs an isolated Docker host' >&2
    exit 1
fi
cleanup() {
    compose down -v --remove-orphans >/dev/null 2>&1 || true
    docker volume rm "$OLD_VOLUME" >/dev/null 2>&1 || true
    rm -rf "$SCRATCH"
}
trap cleanup EXIT
probe() { docker run --rm -i --network mining_net --entrypoint python3 -v "$PROBE:/probe.py:ro" pithead-dashboard:itest /probe.py "$1" "$2" "$3"; }
write_tari_secret() {
    printf 'MINOTARI_WALLET_VIEW_PRIVATE_KEY=%s\nMINOTARI_WALLET_SPEND_KEY=%s\nMINOTARI_WALLET_PASSWORD=itest\n' "$1" "$SPEND" >"$TARI_WALLET_SECRET_FILE"
    chmod 600 "$TARI_WALLET_SECRET_FILE"
}

compose down -v --remove-orphans
compose build wallet-rpc
compose pull tari-wallet
TARI_IMAGE="$(compose config --format json | jq -r '.services["tari-wallet"].image')"

# #2454's red control: the pinned binary cannot create its config under a root-owned old mount.
write_tari_secret "$VIEW1"
docker run --rm --user 0 --mount "type=volume,source=$OLD_VOLUME,target=/home/ubuntu/wallet" \
    --entrypoint chown "$TARI_IMAGE" 0:0 /home/ubuntu/wallet
if timeout 30s docker run --rm --network none --user 1000:1000 --read-only \
    --security-opt no-new-privileges:true --cap-drop ALL --tmpfs /tmp:size=32m,mode=1777 \
    --mount "type=volume,source=$OLD_VOLUME,target=/home/ubuntu/wallet" \
    --env-file "$TARI_WALLET_SECRET_FILE" --entrypoint minotari_console_wallet "$TARI_IMAGE" \
    --base-path /home/ubuntu/wallet --non-interactive-mode --enable-grpc \
    --grpc-address /ip4/0.0.0.0/tcp/18143 --birthday 0 \
    -p wallet.http_server_url=http://127.0.0.1:9000 \
    -p wallet.fallback_http_server_url=http://127.0.0.1:9000 >"$SCRATCH/old-tari.log" 2>&1; then
    echo 'FAIL: Tari initialized on the old root-owned wallet volume' >&2
    exit 1
fi
grep -Eiq 'permission denied|os error 13' "$SCRATCH/old-tari.log" || {
    echo 'FAIL: old Tari volume did not fail for the initialization permission error' >&2
    exit 1
}
echo 'PASS: old Tari mount reproduces the #2454 initialization failure'

# A wrong Monero view key must be refused by wallet2 at first creation, on a fresh volume.
export MONERO_VIEW_KEY="$VIEW2"
write_tari_secret "$VIEW2"
compose up -d --no-deps wallet-rpc tari-wallet
deadline=$(($(date +%s) + 90))
until compose logs wallet-rpc 2>&1 | grep -Eiq '(invalid|mismatch|failed).*view.?key|view.?key.*(invalid|mismatch|failed|does not)'; do
    [ "$(date +%s)" -lt "$deadline" ] || {
        echo 'FAIL: wrong Monero view key was not refused by wallet-rpc' >&2
        exit 1
    }
    sleep 2
done
restarts="$(docker inspect wallet-rpc --format '{{.RestartCount}}')"
[ "$restarts" -gt 0 ] || {
    echo 'FAIL: wrong Monero key left wallet-rpc running' >&2
    exit 1
}
probe monero "$MONERO_ADDR" unavailable
probe tari "$TARI_ADDR" mismatch
echo 'PASS: wrong-wallet view keys fail the address check on both chains'

compose down -v --remove-orphans
export MONERO_VIEW_KEY="$VIEW1"
write_tari_secret "$VIEW1"
compose up -d --no-deps wallet-rpc tari-wallet
probe monero "$MONERO_ADDR" match
probe tari "$TARI_ADDR" match
echo 'PASS: both pinned wallets initialize on fresh volumes and answer with the configured addresses'
