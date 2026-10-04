#!/usr/bin/env bash
# A live, isolated fixture: actual apply, production wallet services and dashboard, no miner.
set -euo pipefail
ROOT="$(pwd -P)"
# shellcheck source=tests/integration/fixtures/payout-pairs.sh
source "$ROOT/tests/integration/fixtures/payout-pairs.sh"
: "${TMPDIR:?the runner must supply scratch storage}"
umask 077
WORK="$(mktemp -d "$TMPDIR/pithead-payout-pairs.XXXXXX")"
PROJECT="pithead-payout-pairs-$$"
TOOLBOX="pithead-payout-pair-tools:itest"
BEFORE="$(sha256sum config.json .env)"
compose() { docker compose -f "$WORK/docker-compose.yml" --env-file "$WORK/.env" "$@"; }
cleanup() {
    rc=$?
    compose down -v --remove-orphans >"$WORK/cleanup.log" 2>&1 || rc=1
    [ "$(sha256sum "$ROOT/config.json" "$ROOT/.env" | sed "s|$ROOT/||g")" = "$BEFORE" ] || rc=1
    # Keep raw evidence until the job finishes; no canonical wallet volume is touched.
    mkdir -p "$ROOT/results"
    cp "$WORK/"*.log "$ROOT/results/" 2>/dev/null || true
    [ "$rc" = 0 ] && rm -rf "$WORK"
    exit "$rc"
}
trap cleanup EXIT
cp pithead config.reference.json config.core-keys.json VERSION "$WORK/"
cp -r build "$WORK/"
cp .env "$WORK/.env"
# Build the exact source tree; no released image can substitute for the candidate.
docker build -t pithead-payout-pair-monero:itest build/monero >"$WORK/monero-build.log" 2>&1
docker build -t pithead-payout-pair-dashboard:itest dashboard >"$WORK/dashboard-build.log" 2>&1
docker build --build-arg "SHELLCHECK_VERSION=$(make -s print-shellcheck-version)" \
    --build-arg "SHFMT_VERSION=$(make -s print-shfmt-version)" \
    -t "$TOOLBOX" tests/runner >"$WORK/tools-build.log" 2>&1
docker pull "$(docker compose --profile tari_payout_confirm config --format json | jq -er '.services["tari-wallet"].image')" >"$WORK/tari-pull.log" 2>&1
# Endpoint values stay private; they are read from the deployed local-node configuration.
MONERO_HOST=$(sed -n 's/^MONERO_NODE_HOST=//p' .env)
TARI_HOST=$(sed -n 's/^TARI_GRPC_ADDRESS=//p' .env)
[ -n "$MONERO_HOST" ] && [ -n "$TARI_HOST" ]
docker compose --profile '*' config --no-interpolate --no-path-resolution --format json |
    python3 tests/integration/payout-pairs/compose.py "$PROJECT" "$MONERO_HOST" "$TARI_HOST" >"$WORK/docker-compose.yml"
# The source's relative mounts resolve in WORK, where the candidate build/ tree was copied.
jq --arg w "$WORK" --arg m "$PAYOUT_MONERO1" --arg t "$PAYOUT_TARI1" --arg k "$PAYOUT_VIEW1" \
    '.monero.wallet_address=$m | .monero.view_key=$k | .monero.payout_scan_height="auto" |
     .monero.rpc_lan_access=false | .monero.zmq_lan_access=false | .tari.grpc_lan_access=false |
     .monero.data_dir=($w+"/data/monero") | .tari.wallet_address=$t | .tari.view_key=$k |
     del(.tari.spend_public_key) | .tari.payout_scan_birthday="auto" | .tari.data_dir=($w+"/data/tari") |
     .p2pool.data_dir=($w+"/data/p2pool") | .tor.data_dir=($w+"/data/tor") |
     .dashboard.data_dir=($w+"/data/dashboard") | .dashboard.secure=false |
     .dashboard.onion.enabled=false | .dashboard.control.enabled=false | .dashboard.local_miner.enabled=false |
     .local_miner.enabled=false | .xvb.enabled=false | .telegram.enabled=false |
     .notifications={} | .healthchecks={} | .workers.list=[] | .network.tor_egress_firewall=false' \
    config.json >"$WORK/config.json"
apply_pair() {
    # Separate namespaces contain any host-unit provisioning. The stock CLI uses real Compose.
    python3 "$ROOT/tests/integration/payout-pairs/docker_guard.py" "$PROJECT" "$WORK/docker.sock" \
        docker run --rm --user 0 --network none -e PITHEAD_PULL=never -e "DOCKER_HOST=unix://$WORK/docker.sock" \
        -v "$WORK:$WORK" -w "$WORK" "$TOOLBOX" ./pithead apply -y >"$WORK/apply-$1.log" 2>&1
}
wallet_rpc() { # method
    compose exec -T wallet-rpc sh -c 'curl -fsS --digest --max-time 5 -u "$WALLET_RPC_USERNAME:$WALLET_RPC_PASSWORD" -H "Content-Type: application/json" -d "$1" http://127.0.0.1:18082/json_rpc' \
        _ "{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"$1\"}"
}
ready() {
    local end=$(($(date +%s) + 1200)) st height tip
    while [ "$(date +%s)" -lt "$end" ]; do
        st=$(compose exec -T dashboard python3 -c 'import json,urllib.request; s=json.load(urllib.request.urlopen("http://127.0.0.1:8000/api/state",timeout=5)); print(json.dumps({k:s["earnings"][k] for k in ("confirmed","tari_confirmed")}))' 2>/dev/null) || st='{}'
        if printf '%s' "$st" | jq -e 'all(.confirmed,.tari_confirmed; .enabled and .reachable and .address_match and (.down != true))' >/dev/null &&
            compose exec -T wallet-rpc test ! -e /home/ubuntu/wallets/.payout-scanning; then
            # Healthchecks must pass with zero scan grace; the card cannot be forced green.
            compose exec -T -e PAYOUT_SCAN_GRACE_SEC=0 wallet-rpc /usr/local/bin/wallet-healthcheck.sh >/dev/null
            compose exec -T -e PAYOUT_SCAN_GRACE_SEC=0 tari-wallet /wallet-config/wallet-healthcheck.sh
            height=$(wallet_rpc get_height | jq -er .result.height)
            tip=$(compose exec -T wallet-rpc sh -c 'curl -fsS --digest --max-time 5 -u "$MONERO_NODE_USERNAME:$MONERO_NODE_PASSWORD" -H "Content-Type: application/json" -d '\''{"jsonrpc":"2.0","id":"0","method":"get_block_count"}'\'' "http://$MONERO_NODE_HOST:$MONERO_RPC_PORT/json_rpc"' | jq -er .result.count)
            [ "$((height + 2))" -ge "$tip" ]
            printf 'PASS: both payout cards recovered; Monero wallet height=%s node count=%s\n' "$height" "$tip"
            return 0
        fi
        sleep 5
    done
    echo 'FAIL: isolated payout cards did not recover within 1200 seconds' >&2
    return 1
}
wallet_path() { compose exec -T wallet-rpc sh -c 'cat /home/ubuntu/wallets/.payout-active'; }
wallet_inode() { compose exec -T wallet-rpc sh -c 'stat -c %i /home/ubuntu/wallets/payout-wallet-$(cat /home/ubuntu/wallets/.payout-active).keys'; }
tari_path() { compose exec -T tari-wallet cat /var/tari/wallet/.payout-active; }
tari_inode() { compose exec -T tari-wallet sh -c 'find /var/tari/wallet/payout-$(cat /var/tari/wallet/.payout-active) -name console_wallet.db -exec stat -c %i {} \;'; }
# A real apply must reject either wrong-wallet key before changing env or starting services.
cp "$WORK/config.json" "$WORK/valid.json"
VALID_ENV="$(sha256sum "$WORK/.env")"
for chain in monero tari; do
    jq --arg c "$chain" --arg k "$PAYOUT_VIEW2" '.[$c].view_key=$k' "$WORK/valid.json" >"$WORK/config.json"
    if apply_pair "$chain-mismatch"; then
        echo "FAIL: $chain apply accepted a wrong-wallet view key" >&2
        exit 1
    fi
    grep -q "$chain.view_key does not belong to $chain.wallet_address" "$WORK/apply-$chain-mismatch.log"
    [ "$(sha256sum "$WORK/.env")" = "$VALID_ENV" ]
    printf 'PASS: %s wrong-wallet view key refused before rendering or deployment\n' "$chain"
done
mv "$WORK/valid.json" "$WORK/config.json"
apply_pair initial
ready
FIRST="$(wallet_path)" FIRST_INODE="$(wallet_inode)"
TARI_FIRST="$(tari_path)" TARI_FIRST_INODE="$(tari_inode)"
[ -n "$TARI_FIRST_INODE" ]
# Persist progress before the recreated wallet is stopped, then pin the retained cache inode.
wallet_rpc store >/dev/null
jq --arg m "$PAYOUT_MONERO2" --arg t "$PAYOUT_TARI2" --arg k "$PAYOUT_VIEW2" \
    '.monero.wallet_address=$m | .monero.view_key=$k | .tari.wallet_address=$t | .tari.view_key=$k' \
    "$WORK/config.json" >"$WORK/new.json"
mv "$WORK/new.json" "$WORK/config.json"
apply_pair changed
SECOND="$(wallet_path)"
[ "$SECOND" != "$FIRST" ]
[ "$(tari_path)" != "$TARI_FIRST" ]
SCAN_FROM=$(compose exec -T wallet-rpc jq -er .scan_from_height /tmp/gen.json)
[ "$SCAN_FROM" -gt 0 ]
ready
TIP=$(wallet_rpc get_height | jq -er .result.height)
[ "$((TIP - SCAN_FROM))" -le 130 ]
printf 'PASS: changed pair created near the tip (restore=%s caught-up=%s), retaining the first wallet\n' "$SCAN_FROM" "$TIP"
compose exec -T wallet-rpc test -f "/home/ubuntu/wallets/payout-wallet-$FIRST"
compose exec -T tari-wallet test -d "/var/tari/wallet/payout-$TARI_FIRST"
wallet_rpc store >/dev/null
jq --arg m "$PAYOUT_MONERO1" --arg t "$PAYOUT_TARI1" --arg k "$PAYOUT_VIEW1" \
    '.monero.wallet_address=$m | .monero.view_key=$k | .tari.wallet_address=$t | .tari.view_key=$k' \
    "$WORK/config.json" >"$WORK/new.json"
mv "$WORK/new.json" "$WORK/config.json"
apply_pair reverted
[ "$(wallet_path)" = "$FIRST" ]
[ "$(wallet_inode)" = "$FIRST_INODE" ]
[ "$(tari_path)" = "$TARI_FIRST" ]
[ "$(tari_inode)" = "$TARI_FIRST_INODE" ]
# A reopened wallet has no creation JSON in its fresh container tmpfs.
compose exec -T wallet-rpc test ! -e /tmp/gen.json
ready
printf 'PASS: revert reopened both retained wallet identities and inodes without recreation\n'
[ "$(sha256sum config.json .env)" = "$BEFORE" ]
printf 'PASS: canonical payout configuration stayed unchanged\n'
