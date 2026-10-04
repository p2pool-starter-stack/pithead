#!/bin/bash
# View-only Tari payout-confirmation wallet (#462), the sibling of #381's monero wallet-rpc.
#
# Runs minotari_console_wallet against the LOCAL Tari base node, scan-only: the wallet is created
# from the operator's PRIVATE VIEW KEY + PUBLIC SPEND KEY (with a password that only encrypts the
# local DB), so it can SEE incoming merge-mine coinbase payouts but CANNOT spend.
#
# SECRET HANDLING (the deliberate deviation from #381): Tari has no JSON-import path, so the three
# secrets can't ride a file handed to a create-from-json flag. They also must NOT sit in the
# container's `environment:` — `docker inspect` would show them. Instead pithead renders them into an
# owner-only (0600) host file owned by the container's uid 1000, which compose (a `secrets:` entry)
# and the quadlet bind-mount read-only at $SECRET_FILE (/run/secrets/...). This wrapper sources that
# file and EXPORTS the three MINOTARI_WALLET_* vars into the wallet
# child process only — they never appear in the container's declared env, so `docker inspect` never
# sees them, and they never touch argv (where `ps` would expose them). First run creates the
# view-only wallet from the keys; later runs reopen the existing wallet DB from the named volume.
set -eu

WALLET_DIR="${WALLET_DIR:-/var/tari/wallet}"
SECRET_FILE="${TARI_WALLET_SECRET_FILE_IN:-/run/secrets/tari_wallet_secret}"
GRPC_BIND="${TARI_WALLET_GRPC_BIND:-/ip4/0.0.0.0/tcp/18143}"
BASE_NODE_GRPC="${TARI_BASE_NODE_GRPC_ADDRESS:-127.0.0.1:18142}"
# The v6 wallet scans through the base node's HTTP wallet query service (port 9000), not gRPC. Both
# the primary and the fallback URL name the LOCAL node: the stock fallback is Tari's public
# rpc.tari.com, which would scan over clearnet (#2731). The host is the one the gRPC address names.
NODE_URL="http://${BASE_NODE_GRPC%%:*}:9000"

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

# Keep a separate base path (and hence database) for each configured address/key pair.
select_wallet() {
    local identity owner entry
    identity=$(printf '%s\n%s\n' "${TARI_WALLET_ADDRESS:-$MINOTARI_WALLET_SPEND_KEY}" "$MINOTARI_WALLET_VIEW_PRIVATE_KEY" | sha256sum)
    identity="${identity%% *}"
    WALLET_BASE="$WALLET_DIR/payout-$identity"
    owner="$WALLET_DIR/.legacy-wallet-identity"
    if [ -n "$(find "$WALLET_DIR" -maxdepth 7 -name console_wallet.db -not -path "$WALLET_DIR/payout-*/*" -print -quit)" ] && [ ! -f "$owner" ]; then
        (
            umask 077
            printf '%s\n' "$identity" >"$owner"
        )
    fi
    mkdir -p "$WALLET_BASE"
    # Record the adoption owner before moving: an interrupted migration resumes for that pair.
    if [ -f "$owner" ] && [ "$(cat "$owner")" = "$identity" ]; then
        for entry in "$WALLET_DIR"/*; do
            [ -e "$entry" ] || continue
            case "${entry##*/}" in payout-*) continue ;; esac
            mv "$entry" "$WALLET_BASE/"
        done
    fi
    if [ "$(cat "$WALLET_DIR/.payout-active" 2>/dev/null || true)" != "$identity" ]; then
        rm -f "$WALLET_DIR/.payout-scanning"
        printf '%s\n' "$identity" >"$WALLET_DIR/.payout-active"
    fi
}

# When sourced by the shell test harness, expose the functions and stop — don't read secrets or exec.
if [ "${PITHEAD_TEST_SOURCE:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

# Pull the three secrets off the bind-mounted secret file into THIS shell's env, then export so the wallet
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
select_wallet
# Repair a root-owned volume if needed, then run the wallet as the image's non-root uid (#2454).
if [ "$(stat -c %u "$WALLET_DIR")" != 1000 ] || [ "$(stat -c %u "$WALLET_BASE")" != 1000 ]; then
    chown -R 1000:1000 "$WALLET_DIR"
fi
# First-scan grace survives restarts; a crash loop cannot restart its clock.
[ -e "$WALLET_DIR/.payout-scanning" ] || touch "$WALLET_DIR/.payout-scanning"
birthday="$(resolve_birthday)"
echo "Starting view-only Tari payout wallet (birthday $birthday, base node $NODE_URL) (#462)..."

# The three MINOTARI_WALLET_VIEW_PRIVATE_KEY / SPEND_KEY / PASSWORD env vars (sourced above, now
# exported) supply the view-only wallet material WITHOUT ever landing on the command line. Supplying
# all three creates the read-only wallet non-interactively on first run and reopens it after.
exec setpriv --reuid=1000 --regid=1000 --clear-groups minotari_console_wallet \
    --base-path "$WALLET_BASE" \
    --non-interactive-mode \
    --enable-grpc \
    --grpc-address "$GRPC_BIND" \
    --birthday "$birthday" \
    -p "wallet.http_server_url=$NODE_URL" \
    -p "wallet.fallback_http_server_url=$NODE_URL"
