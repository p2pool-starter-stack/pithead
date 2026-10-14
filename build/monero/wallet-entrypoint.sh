#!/bin/bash
# View-only payout-confirmation wallet (#381).
#
# Runs monero-wallet-rpc against the LOCAL monerod, scan-only: the wallet is generated from the
# operator's PRIVATE VIEW KEY with NO spend key, so it can see incoming payouts but CANNOT
# spend. The view key is written to a JSON file on tmpfs and handed to --generate-from-json — it is
# NEVER put on the command line, where `docker inspect` / `ps` would expose it (#90 discipline,
# same as monerod's RPC creds). Each address/key pair keeps a wallet in the named volume. Reverting a pair reopens
# its saved scan progress. New wallets use PAYOUT_SCAN_HEIGHT or the local tip minus 100 blocks.
set -eu
umask 077

WALLET_DIR="${WALLET_DIR:-/home/ubuntu/wallets}"
WALLET_FILE="" # selected after the test-source guard
# Marker (#718, #2756, #2720): touched on every start, cleared by the healthcheck once the wallet has
# scanned to monerod's tip. While it exists, an unreachable RPC means "still scanning": for the
# genesis default the first scan is HOURS, and a reopened wallet catches up on every block it missed
# while stopped; monero-wallet-rpc is single-threaded and won't answer during either.
# It lives in the volume so it persists across container recreates until the scan actually finishes.
SCAN_MARKER="$WALLET_DIR/.payout-scanning"
GEN_JSON="${GEN_JSON:-/tmp/gen.json}" # tmpfs; holds the view key for the create-from-keys step only
DAEMON_ADDRESS="${MONERO_NODE_HOST:-127.0.0.1}:${MONERO_RPC_PORT:-18081}"

# Fresh wallets start 100 blocks behind the local tip (about 200 minutes).
# Never fall back to genesis when the node is unavailable: restart and retry instead.
resolve_scan_height() {
    local want="${PAYOUT_SCAN_HEIGHT:-auto}" count
    case "$want" in
    '' | auto)
        count=$(curl -fsS --digest --max-time 10 \
            -u "${MONERO_NODE_USERNAME:-}:${MONERO_NODE_PASSWORD:-}" \
            -H 'Content-Type: application/json' \
            -d '{"jsonrpc":"2.0","id":"0","method":"get_block_count"}' \
            "http://$DAEMON_ADDRESS/json_rpc" | jq -er '.result.count | select(type == "number" and . > 0 and floor == .)') || {
            echo "Cannot read the local Monero height; refusing a genesis fallback." >&2
            return 1
        }
        if [ "$count" -gt 100 ]; then printf '%s\n' "$((count - 100))"; else printf '0\n'; fi
        ;;
    *[!0-9]*)
        echo "Invalid payout scan height." >&2
        return 1
        ;;
    *) printf '%s\n' "$want" | sed 's/^0*//; s/^$/0/' ;;
    esac
}

# Read the keys through the pinned wallet RPC, never trust an optional address sidecar.
# Only the keys are needed; the probe creates its own cache without contacting a daemon.
legacy_address_matches() (
    set -eu
    local probe pid='' address attempt
    probe=$(mktemp -d "$WALLET_DIR/.legacy-probe.XXXXXX") || exit 1
    trap '[ -z "$pid" ] || { kill -KILL "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }; rm -rf "$probe"' EXIT
    trap 'exit 1' INT TERM
    cp "$WALLET_DIR/payout-wallet.keys" "$probe/wallet.keys" || exit 1
    monero-wallet-rpc --wallet-file "$probe/wallet" --password '' --offline \
        --no-initial-sync --rpc-bind-ip 127.0.0.1 --rpc-bind-port 18083 \
        --disable-rpc-login --non-interactive --max-concurrency 1 \
        --shared-ringdb-dir "$probe/ringdb" --log-file "$probe/rpc.log" \
        >"$probe/output" 2>&1 &
    pid=$!
    for ((attempt = 0; attempt < 30; attempt++)); do
        kill -0 "$pid" 2>/dev/null || exit 1
        if address=$(curl -fsS --max-time 1 -H 'Content-Type: application/json' \
            -d '{"jsonrpc":"2.0","id":"0","method":"get_address"}' \
            http://127.0.0.1:18083/json_rpc 2>/dev/null | jq -er '.result.address | select(type == "string" and length > 0)'); then
            [ "$address" = "${MONERO_WALLET_ADDRESS:-}" ]
            exit $?
        fi
        sleep 1
    done
    exit 1
)

select_wallet() {
    local identity legacy owner suffix
    identity=$(printf '%s\n%s\n' "${MONERO_WALLET_ADDRESS:-}" "${MONERO_VIEW_KEY:-}" | sha256sum)
    identity="${identity%% *}"
    WALLET_FILE="$WALLET_DIR/payout-wallet-$identity"
    legacy="$WALLET_DIR/payout-wallet"
    owner="$WALLET_DIR/.legacy-wallet-identity"
    # Record the adoption owner first; a interrupted rename resumes for this pair only.
    if [ -f "$legacy" ] && [ ! -f "$owner" ] && [ ! -e "$WALLET_FILE" ]; then
        if legacy_address_matches; then
            (
                umask 077
                printf '%s\n' "$identity" >"$owner"
            )
        else
            echo "Legacy Monero wallet identity differs or cannot be read; retaining it without adoption." >&2
        fi
    fi
    if [ -f "$owner" ] && [ "$(cat "$owner")" = "$identity" ]; then
        for suffix in .keys .address.txt .unportable ''; do
            [ ! -f "$legacy$suffix" ] || mv "$legacy$suffix" "$WALLET_FILE$suffix"
        done
    fi
    # A different wallet gets its own catch-up grace; restarts of the same one keep its age.
    if [ "$(cat "$WALLET_DIR/.payout-active" 2>/dev/null || true)" != "$identity" ]; then
        rm -f "$SCAN_MARKER"
        printf '%s\n' "$identity" >"$WALLET_DIR/.payout-active"
    fi
}

# Write the create-from-keys JSON for a VIEW-ONLY wallet ($1 = restore height). The spend key is
# DELIBERATELY OMITTED, never set to "": monero-wallet-rpc (v0.18) parses an empty-string spendkey
# as a secret key and aborts creation ("failed to parse spend key secret key"), so an empty value
# breaks the wallet outright. An absent spendkey IS the view-only form — exactly what a payout-
# confirmation wallet needs (#714). umask 077 so the file (it holds the view key) is owner-only.
write_gen_json() {
    local height="$1"
    (
        umask 077
        cat >"$GEN_JSON" <<EOF
{
  "version": 1,
  "filename": "$WALLET_FILE",
  "scan_from_height": $height,
  "password": "",
  "address": "${MONERO_WALLET_ADDRESS:-}",
  "viewkey": "${MONERO_VIEW_KEY:-}"
}
EOF
    )
}

# When sourced by the shell test harness, expose the functions and stop — don't render or exec.
if [ "${PITHEAD_TEST_SOURCE:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

mkdir -p "$WALLET_DIR"
select_wallet

# Bound parallel wallet work to one worker; host CPU count is not a memory budget.
# Shared server flags. --rpc-login (dashboard→wallet-rpc) authenticates the loopback-published RPC so
# even a mining-net peer that reaches the bridge IP can't read payout history; --daemon-login is the
# monerod RPC cred (same value p2pool already passes on its command line). The ringdb default is
# under $HOME on the read-only root (#2720), so it lives in the wallet volume instead. Bind 0.0.0.0
# so the 127.0.0.1:18082 host publish works; the rpc-login + loopback-only publish is the access control.
set -- \
    --daemon-address "$DAEMON_ADDRESS" \
    --daemon-login "${MONERO_NODE_USERNAME:-}:${MONERO_NODE_PASSWORD:-}" \
    --trusted-daemon \
    --rpc-bind-ip 0.0.0.0 --confirm-external-bind \
    --rpc-bind-port 18082 \
    --rpc-login "${WALLET_RPC_USERNAME:-wallet}:${WALLET_RPC_PASSWORD:-}" \
    --password "" \
    --shared-ringdb-dir "$WALLET_DIR/.shared-ringdb" \
    --max-concurrency 1 \
    --log-level 0 \
    --non-interactive

# Mark a scan on EVERY start (#718, #2756): a first creation scans from the restore height (genesis
# is hours); a reopen catches up from the height the wallet last stored, which after a long stop, a
# remote-node spell or an unsaved scan is just as long. monero-wallet-rpc does not answer while it
# scans. The healthcheck tolerates an unreachable RPC while this marker exists, within a 24h grace
# by default, and clears it once the wallet reaches monerod's tip (#2720). An existing marker keeps
# its mtime, so a wallet that crash-loops without catching up still turns unhealthy after the grace.
[ -f "$SCAN_MARKER" ] || touch "$SCAN_MARKER" 2>/dev/null || true

if [ ! -f "$WALLET_FILE" ]; then
    height="$(resolve_scan_height)"
    echo "Creating view-only payout wallet at restore height $height (#381)..."
    # The view key lives ONLY in this tmpfs file, never on argv.
    write_gen_json "$height"
    # --generate-from-json creates + opens the wallet, then keeps serving the RPC.
    exec monero-wallet-rpc "$@" --generate-from-json "$GEN_JSON"
fi

echo "Opening existing view-only payout wallet (#381)..."
exec monero-wallet-rpc "$@" --wallet-file "$WALLET_FILE"
