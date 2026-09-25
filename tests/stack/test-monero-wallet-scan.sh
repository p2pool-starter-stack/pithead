# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Monero payout wallet scan grace across restarts (#2720). A reopened wallet catches up on every
# block it missed while stopped, and monero-wallet-rpc answers between refresh passes, so the grace
# is armed on every start and retired only at monerod's tip. A sibling of test-monero-tari.sh, which
# holds the first-scan rows (#718/#2268) and is at its budget ceiling.
# Sourced by tests/stack/run.sh.

: "${ROOT:?}" "${SANDBOX:?}"

echo "== monero wallet: scan grace survives a restart and ends at the tip (#2720) =="
WS_BIN="$SANDBOX/ws-bin"
WS_DIR="$SANDBOX/ws-wallet"
mkdir -p "$WS_BIN" "$WS_DIR"
# ws_curl RC WALLET_HEIGHT [DAEMON_COUNT]: the wallet RPC exits RC; no DAEMON_COUNT = monerod down.
ws_curl() {
    cat >"$WS_BIN/curl" <<EOF
#!/bin/sh
case "\$*" in
*get_block_count*) [ -n "${3:-}" ] || exit 7; echo '{"result":{"count":${3:-0}}}' ;;
*get_height*) echo '{"result":{"height":$2}}' ;;
esac
exit $1
EOF
    chmod +x "$WS_BIN/curl"
}
# ws_hc [WALLET_DIR]: the real healthcheck's exit code.
ws_hc() { (
    PATH="$WS_BIN:$PATH" WALLET_DIR="${1:-$WS_DIR}" sh "$ROOT/build/monero/wallet-healthcheck.sh" >/dev/null 2>&1
    echo $?
); }
ws_marker() { if [ -f "$WS_DIR/.payout-scanning" ]; then echo kept; else echo cleared; fi; }

: >"$WS_DIR/.payout-scanning"
ws_curl 0 1000 3000000
assert_eq "wallet healthcheck: RPC up behind the tip -> healthy (#2720)" "$(ws_hc)" "0"
assert_eq "wallet healthcheck: RPC up behind the tip keeps the scan marker (#2720)" "$(ws_marker)" "kept"
ws_curl 7 1000 3000000
assert_eq "wallet healthcheck: RPC busy after an early answer -> still in grace (#2720)" "$(ws_hc)" "0"
ws_curl 0 2999999 3000000
ws_hc >/dev/null
assert_eq "wallet healthcheck: RPC up at the tip clears the scan marker (#2720)" "$(ws_marker)" "cleared"
: >"$WS_DIR/.payout-scanning"
ws_curl 0 1000
ws_hc >/dev/null
assert_eq "wallet healthcheck: unreadable monerod count clears the marker, strict by default (#2720)" "$(ws_marker)" "cleared"

# ws_start create|reopen: run the real entrypoint with monero-wallet-rpc stubbed; is the marker armed?
printf '#!/bin/sh\nexit 0\n' >"$WS_BIN/monero-wallet-rpc"
chmod +x "$WS_BIN/monero-wallet-rpc"
ws_start() { (
    d="$SANDBOX/ws-start-$1"
    mkdir -p "$d"
    if [ "$1" = reopen ]; then : >"$d/payout-wallet"; fi
    PATH="$WS_BIN:$PATH" WALLET_DIR="$d" GEN_JSON="$d/gen.json" bash "$ROOT/build/monero/wallet-entrypoint.sh" >/dev/null 2>&1
    if [ -f "$d/.payout-scanning" ]; then echo armed; else echo missing; fi
); }
assert_eq "wallet entrypoint arms the scan marker on create (#718)" "$(ws_start create)" "armed"
assert_eq "wallet entrypoint arms the scan marker on reopen (#2720)" "$(ws_start reopen)" "armed"
# A restart must not re-arm an existing marker: a crash loop would otherwise never leave the grace.
touch -t 200001010000.00 "$SANDBOX/ws-start-reopen/.payout-scanning"
ws_start reopen >/dev/null
ws_curl 7 0
assert_eq "wallet entrypoint keeps an old marker's age, so a crash loop still goes unhealthy (#2720)" "$(ws_hc "$SANDBOX/ws-start-reopen")" "1"
# The ringdb defaults to $HOME/.shared-ringdb on the read-only root; it must sit in the volume.
# shellcheck disable=SC2016
assert_contains "wallet entrypoint keeps the ringdb in the wallet volume (#2720)" \
    "$(cat "$ROOT/build/monero/wallet-entrypoint.sh")" '--shared-ringdb-dir "$WALLET_DIR/.shared-ringdb"'
