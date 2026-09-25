# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# The view-only Tari payout wallet's entrypoint and the node side it scans through (#462, #2731).
# A sibling of test-monero-tari.sh, which is at its budget ceiling; $V, $WALLET, $TVIEW and $TSPEND
# come from it. Sourced by tests/stack/run.sh.

: "${ROOT:?}" "${V:?}" "${WALLET:?}" "${TVIEW:?}" "${TSPEND:?}"

echo "== black-box: tari.payout_scan_birthday validation (#523) =="
# The restore-point birthday is validated only on the view-key path (it feeds the tari-wallet). It
# is "auto" or days since 2022-01-01, no later than today — a block height or a future day is a
# common mistake that must fail at apply, not silently mis-restore the wallet. Keys are valid so
# only the birthday is under test.
# (1) A non-integer birthday (a block height, say) is refused.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","view_key":"%s","spend_public_key":"%s","payout_scan_birthday":"height-3200000"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$TVIEW" "$TSPEND" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "non-integer birthday rejected" "$?" "1"
assert_contains "non-integer birthday message names the field" "$out" "tari.payout_scan_birthday"
# (2) A day after today is refused: Tari counts from 2022-01-01, so a 1970-based 20000 is 2076 (#2731).
for bd in 20000 99999999999999999999; do
    seed_env
    printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","view_key":"%s","spend_public_key":"%s","payout_scan_birthday":"'"$bd"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$TVIEW" "$TSPEND" >"$V/config.json"
    out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
    assert_rc "future birthday $bd rejected" "$?" "1"
    assert_contains "future birthday $bd message names the unit" "$out" "days since 2022-01-01"
done
# (3) A valid past birthday applies and reflects verbatim into .env.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","view_key":"%s","spend_public_key":"%s","payout_scan_birthday":"1000"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$TVIEW" "$TSPEND" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "valid birthday accepted" "$?" "0"
assert_eq "valid birthday reflected into .env" "$(run_sourced "$V" env_get_file "$V/.env" TARI_WALLET_BIRTHDAY)" "1000"

echo "== unit: tari-wallet entrypoint — Tari-epoch birthday, local-node scan URL (#2731) =="
# Tari's --birthday counts days since 2022-01-01 (1640995200); "auto" must be today in that unit.
tw_today=$((($(date +%s) - 1640995200) / 86400))
tw_auto="$(TARI_WALLET_BIRTHDAY=auto PITHEAD_TEST_SOURCE=1 bash -c 'source "$1"; resolve_birthday' _ "$ROOT/build/tari-wallet/entrypoint.sh")"
[ "$tw_auto" -ge "$((tw_today - 1))" ] && [ "$tw_auto" -le "$tw_today" ] && tw_ok=yes || tw_ok="no ($tw_auto vs $tw_today)"
assert_eq "auto birthday is today's Tari day" "$tw_ok" "yes"
assert_eq "explicit birthday verbatim" "$(TARI_WALLET_BIRTHDAY=1425 PITHEAD_TEST_SOURCE=1 bash -c 'source "$1"; resolve_birthday' _ "$ROOT/build/tari-wallet/entrypoint.sh")" "1425"
# The wallet scans over the node's HTTP wallet service on the host of its gRPC address, and both the
# primary and the fallback URL are that local node (the stock fallback is the public rpc.tari.com).
assert_eq "scan URL is the local node's :9000" "$(TARI_BASE_NODE_GRPC_ADDRESS=172.28.0.27:18142 PITHEAD_TEST_SOURCE=1 bash -c 'source "$1"; base_node_http_url' _ "$ROOT/build/tari-wallet/entrypoint.sh")" "http://172.28.0.27:9000"
tw_entry="$(cat "$ROOT/build/tari-wallet/entrypoint.sh")"
assert_contains "wallet primary URL set" "$tw_entry" '-p "wallet.http_server_url=$node_url"'
assert_contains "wallet fallback URL pinned local" "$tw_entry" '-p "wallet.fallback_http_server_url=$node_url"'
assert_not_contains "dead v6 gRPC override dropped" "$tw_entry" "GRPC_BASE_NODE_ADDRESS"
tw_tpl="$(cat "$ROOT/build/tari/config.toml.template")"
assert_contains "node serves the wallet HTTP API" "$tw_tpl" "[base_node.http_wallet_query_service]"
assert_contains "wallet HTTP API on 9000" "$tw_tpl" "port = 9000"
assert_not_contains "9000 never published by compose" "$(cat "$ROOT/docker-compose.yml")" ":9000:"
assert_not_contains "9000 never published by quadlets" "$(cat "$ROOT"/os/quadlet/*/*.container)" "9000:9000"
