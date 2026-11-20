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

# ws_start reopen: run the real entrypoint on an existing wallet with monero-wallet-rpc stubbed.
printf '#!/bin/sh\nexit 0\n' >"$WS_BIN/monero-wallet-rpc"
chmod +x "$WS_BIN/monero-wallet-rpc"
ws_start() { (
    d="$SANDBOX/ws-start-$1"
    mkdir -p "$d"
    if [ "$1" = reopen ]; then : >"$d/payout-wallet"; fi
    PATH="$WS_BIN:$PATH" WALLET_DIR="$d" GEN_JSON="$d/gen.json" bash "$ROOT/build/monero/wallet-entrypoint.sh" >/dev/null 2>&1
    if [ -f "$d/.payout-scanning" ]; then echo armed; else echo missing; fi
); }
# test-monero-tari.sh covers arming on create and reopen (#2756). A restart must not re-arm an
# existing marker: a crash loop would otherwise never leave the grace.
ws_start reopen >/dev/null
touch -t 200001010000.00 "$SANDBOX/ws-start-reopen/.payout-scanning"
ws_start reopen >/dev/null
ws_curl 7 0
assert_eq "wallet entrypoint keeps an old marker's age, so a crash loop still goes unhealthy (#2720)" "$(ws_hc "$SANDBOX/ws-start-reopen")" "1"
# The ringdb defaults to $HOME/.shared-ringdb on the read-only root; it must sit in the volume.
# shellcheck disable=SC2016
assert_contains "wallet entrypoint keeps the ringdb in the wallet volume (#2720)" \
    "$(cat "$ROOT/build/monero/wallet-entrypoint.sh")" '--shared-ringdb-dir "$WALLET_DIR/.shared-ringdb"'

echo "== monero wallet: remote node trust and proxy flags (#2866) =="
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >"$ARGS_OUT"\nexit 0\n' >"$WS_BIN/monero-wallet-rpc"
chmod +x "$WS_BIN/monero-wallet-rpc"
ws_args() { (
    d="$SANDBOX/ws-args-$1"
    mkdir -p "$d"
    shift
    env PAYOUT_SCAN_HEIGHT=100 "$@" PATH="$WS_BIN:$PATH" WALLET_DIR="$d" GEN_JSON="$d/gen.json" ARGS_OUT="$d/args" bash "$ROOT/build/monero/wallet-entrypoint.sh" >/dev/null 2>&1
    tr '\n' ' ' <"$d/args"
); }
local_args="$(ws_args local MONERO_NODE_HOST=172.28.0.26)"
assert_contains "the local wallet stub ran" "$local_args" "--rpc-bind-port 18082"
assert_contains "local wallet keeps the trusted bundled daemon" "$local_args" "--trusted-daemon"
assert_not_contains "local wallet adds no proxy" "$local_args" "--proxy"
assert_contains "local wallet dials the bundled node" "$local_args" "--daemon-address 172.28.0.26:18081"
direct_args="$(ws_args direct PAYOUT_NODE_REMOTE=true MONERO_NODE_HOST=192.0.2.10 MONERO_RPC_PORT=28081)"
assert_contains "the remote wallet stub ran" "$direct_args" "--rpc-bind-port 18082"
assert_contains "remote wallet distrusts the node" "$direct_args" "--untrusted-daemon"
assert_not_contains "remote wallet never sets the trusted flag" "$direct_args" "--trusted-daemon"
assert_contains "remote wallet dials the configured node and port" "$direct_args" "--daemon-address 192.0.2.10:28081"
assert_not_contains "a direct remote wallet adds no proxy" "$direct_args" "--proxy"
tor_args="$(ws_args tor PAYOUT_NODE_REMOTE=true PAYOUT_NODE_PROXY=172.28.0.25:9050 MONERO_NODE_HOST=node.example.com)"
assert_contains "a Privacy remote wallet scans through the Tor SOCKS port" "$tor_args" "--proxy 172.28.0.25:9050"
assert_contains "a proxied wallet passes the flag monero-wallet-rpc requires to start behind a proxy" "$tor_args" "--daemon-ssl-allow-any-cert"
assert_not_contains "a direct wallet keeps certificate checks" "$direct_args" "--daemon-ssl-allow-any-cert"
v6_args="$(ws_args v6 PAYOUT_NODE_REMOTE=true MONERO_NODE_HOST=2001:db8::1)"
assert_contains "an IPv6 node is bracketed for the wallet" "$v6_args" "--daemon-address [2001:db8::1]:18081"
key_args="$(ws_args key PAYOUT_NODE_REMOTE=true MONERO_VIEW_KEY=feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface)"
assert_contains "the view-key wallet stub ran" "$key_args" "--generate-from-json"
assert_not_contains "no wallet argument carries the view key" "$key_args" "feedface"

ws_curl_log() {
    cat >"$WS_BIN/curl" <<'EOS'
#!/bin/sh
printf '%s\n' "$*" >>"$CURL_LOG"
case "$*" in
*get_block_count*) echo '{"result":{"count":3000000}}' ;;
*get_height*) echo '{"result":{"height":3000000}}' ;;
esac
exit 0
EOS
    chmod +x "$WS_BIN/curl"
}
ws_curl_log
CURL_LOG="$SANDBOX/ws-curl.log"
: >"$CURL_LOG"
: >"$WS_DIR/.payout-scanning"
CURL_LOG="$CURL_LOG" PAYOUT_NODE_PROXY=172.28.0.25:9050 MONERO_NODE_HOST=node.example.com MONERO_RPC_PORT=28081 PATH="$WS_BIN:$PATH" WALLET_DIR="$WS_DIR" sh "$ROOT/build/monero/wallet-healthcheck.sh" >/dev/null 2>&1
assert_contains "the healthcheck reads a proxied node's height through the proxy" "$(grep get_block_count "$CURL_LOG")" "--socks5-hostname 172.28.0.25:9050"
assert_contains "the healthcheck reads the configured remote node" "$(grep get_block_count "$CURL_LOG")" "http://node.example.com:28081/json_rpc"
: >"$CURL_LOG"
: >"$WS_DIR/.payout-scanning"
CURL_LOG="$CURL_LOG" MONERO_NODE_HOST=172.28.0.26 PATH="$WS_BIN:$PATH" WALLET_DIR="$WS_DIR" sh "$ROOT/build/monero/wallet-healthcheck.sh" >/dev/null 2>&1
assert_contains "the local healthcheck read the bundled node" "$(grep get_block_count "$CURL_LOG")" "http://172.28.0.26:18081/json_rpc"
assert_not_contains "a local healthcheck dials without a proxy" "$(grep get_block_count "$CURL_LOG")" "socks5"
: >"$CURL_LOG"
: >"$WS_DIR/.payout-scanning"
ws_curl 0 10
CURL_LOG="$CURL_LOG" PAYOUT_NODE_REMOTE=true MONERO_NODE_HOST=192.0.2.10 PATH="$WS_BIN:$PATH" WALLET_DIR="$WS_DIR" sh "$ROOT/build/monero/wallet-healthcheck.sh" >/dev/null 2>&1
assert_eq "an unreadable remote node keeps the scan marker armed" "$([ -f "$WS_DIR/.payout-scanning" ] && echo kept || echo cleared)" kept
: >"$WS_DIR/.payout-scanning"
CURL_LOG="$CURL_LOG" MONERO_NODE_HOST=172.28.0.26 PATH="$WS_BIN:$PATH" WALLET_DIR="$WS_DIR" sh "$ROOT/build/monero/wallet-healthcheck.sh" >/dev/null 2>&1
assert_eq "an unreadable local node still clears the scan marker" "$([ -f "$WS_DIR/.payout-scanning" ] && echo kept || echo cleared)" cleared
