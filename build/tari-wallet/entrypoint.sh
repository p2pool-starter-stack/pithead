#!/bin/bash
# View-only Tari payout-confirmation wallet (#462), the sibling of #381's monero wallet-rpc.
#
# Runs minotari_console_wallet against the LOCAL Tari base node, scan-only: the wallet is created
# from the operator's PRIVATE VIEW KEY + PUBLIC SPEND KEY (with a password that only encrypts the
# local DB), so it can SEE incoming merge-mine coinbase payouts but CANNOT spend.
#
# SECRET HANDLING (the deliberate deviation from #381): Tari has no JSON-import path, so the three
# secrets can't ride a file handed to a create-from-json flag. They also must NOT sit in the
# container's `environment:` — `docker inspect` would show them. Instead compose delivers them as a
# `secrets:` entry, which Docker mounts on a TMPFS at $SECRET_FILE (/run/secrets/...), owner-readable
# only. This wrapper sources that file and EXPORTS the three MINOTARI_WALLET_* vars into the wallet
# child process only — they never appear in the container's declared env, so `docker inspect` never
# sees them, and they never touch argv (where `ps` would expose them). First run creates the
# view-only wallet from the keys; later runs reopen the existing wallet DB from the named volume.
set -eu

WALLET_DIR="${WALLET_DIR:-/home/ubuntu/wallet}"
SECRET_FILE="${TARI_WALLET_SECRET_FILE_IN:-/run/secrets/tari_wallet_secret}"
GRPC_BIND="${TARI_WALLET_GRPC_BIND:-/ip4/0.0.0.0/tcp/18143}"
BASE_NODE_GRPC="${TARI_BASE_NODE_GRPC_ADDRESS:-127.0.0.1:18142}"

# Days since 2022-01-01, Tari's birthday genesis (BIRTHDAY_GENESIS_FROM_UNIX_EPOCH = 1640995200).
TARI_BIRTHDAY_GENESIS=1640995200

# Resolve the wallet BIRTHDAY. Unlike #381's Monero restore HEIGHT, a Tari birthday is DAYS SINCE
# 2022-01-01 (#2731), the unit Tari Universe stores as wallet_birthday: "auto"/empty means "today",
# so a fresh wallet scans forward from now instead of rescanning from genesis. An explicit integer
# is used verbatim.
resolve_birthday() {
    local want="${TARI_WALLET_BIRTHDAY:-auto}"
    case "$want" in
    '' | auto) printf '%s\n' "$((($(date +%s) - TARI_BIRTHDAY_GENESIS) / 86400))" ;;
    *) printf '%s\n' "$want" ;;
    esac
}

# The v6 wallet scans through the base node's HTTP wallet query service (port 9000), not gRPC. Point
# both the primary and the fallback URL at the LOCAL node: the stock fallback is Tari's public
# rpc.tari.com, which would scan over clearnet (#2731). The host is the one the gRPC address names.
base_node_http_url() {
    printf 'http://%s:9000\n' "${BASE_NODE_GRPC%%:*}"
}

# When sourced by the shell test harness, expose the functions and stop — don't read secrets or exec.
if [ "${PITHEAD_TEST_SOURCE:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

# Pull the three secrets off the tmpfs secret file into THIS shell's env, then export so the wallet
# child inherits them. Read in a subshell-free way; the file is owner-only and never echoed.
if [ -r "$SECRET_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$SECRET_FILE"
    set +a
else
    echo "tari-wallet: secret file $SECRET_FILE not readable — cannot start view-only wallet (#462)" >&2
    exit 1
fi

mkdir -p "$WALLET_DIR"
birthday="$(resolve_birthday)"
node_url="$(base_node_http_url)"
echo "Starting view-only Tari payout wallet (birthday $birthday, base node $node_url) (#462)..."

# The three MINOTARI_WALLET_VIEW_PRIVATE_KEY / SPEND_KEY / PASSWORD env vars (sourced above, now
# exported) supply the view-only wallet material WITHOUT ever landing on the command line. Supplying
# all three creates the read-only wallet non-interactively on first run and reopens it after.
exec minotari_console_wallet \
    --base-path "$WALLET_DIR" \
    --non-interactive-mode \
    --enable-grpc \
    --grpc-address "$GRPC_BIND" \
    --birthday "$birthday" \
    -p "wallet.http_server_url=$node_url" \
    -p "wallet.fallback_http_server_url=$node_url"
