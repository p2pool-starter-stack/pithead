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
# Public test vectors from scalar 1. The private view keys below are synthetic; no funds use them.
MONERO_ADDR=44yQXfkWZNmJ8QgRfFWTzmJ8QgRfFWTzmJ8QgRfFWTzmJ7suhUXwdrDJ8QgRfFWTzmJ8QgRfFWTzmJ8QgRfFWTzmCYrSgjJ
TARI_ADDR=12M2aZjsSvTTcaFyzLxARkvwdxv8UHJeJBA6E1pEoP967ydCL8tv17vktNDHhqDgFg5LxtHrp9Wsd1cuhyW1p6fzimM
VIEW1=0100000000000000000000000000000000000000000000000000000000000000
VIEW2=0200000000000000000000000000000000000000000000000000000000000000
SPEND=e2f2ae0a6abc4e71a884a961c500515f58e30b6aa582dd8db6a65945e08d2d76
export MONERO_WALLET_ADDRESS="$MONERO_ADDR" MONERO_VIEW_KEY="$VIEW1"

compose() { docker compose -p pithead-wallet-itest -f "$COMPOSE" --profile payout_confirm --profile tari_payout_confirm "$@"; }
# The production Compose file names this network globally. Never attach test wallets to a live stack.
if docker network inspect mining_net >/dev/null 2>&1; then
    echo 'FAIL: mining_net already exists; real-wallet test needs an isolated Docker host' >&2
    exit 1
fi
cleanup() {
    compose down -v --remove-orphans >/dev/null 2>&1 || true
    rm -rf "$SCRATCH"
}
trap cleanup EXIT
probe() { docker run --rm -i --network mining_net --entrypoint python3 -v "$PROBE:/probe.py:ro" pithead-dashboard:itest /probe.py "$1" "$2" "$3"; }
write_tari_secret() {
    printf 'MINOTARI_WALLET_VIEW_PRIVATE_KEY=%s\nMINOTARI_WALLET_SPEND_KEY=%s\nMINOTARI_WALLET_PASSWORD=itest\n' "$1" "$SPEND" >"$TARI_WALLET_SECRET_FILE"
    chmod 600 "$TARI_WALLET_SECRET_FILE"
}

compose build wallet-rpc
compose pull tari-wallet

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
probe tari "$TARI_ADDR" mismatch
echo 'PASS: wrong-wallet view keys fail the address check on both chains'

compose down -v --remove-orphans
export MONERO_VIEW_KEY="$VIEW1"
write_tari_secret "$VIEW1"
compose up -d --no-deps wallet-rpc tari-wallet
probe monero "$MONERO_ADDR" match
probe tari "$TARI_ADDR" match
echo 'PASS: both pinned wallets initialize on fresh volumes and answer with the configured addresses'
