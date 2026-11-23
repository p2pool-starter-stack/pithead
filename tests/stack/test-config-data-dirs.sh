# shellcheck shell=bash
: "${STACK_SUITE:?source through tests/stack/run.sh}"

echo "== config: nested data dirs and dashboard.secure normalization =="
# Nested data dirs are refused: reset/removal of the outer one would wipe the inner one.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","data_dir":"/srv/pithead/monero"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main","data_dir":"/srv/pithead"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "nested data dirs rejected" "$rc" "1"
assert_contains "nested data dirs message names both keys" "$out" "monero.data_dir (/srv/pithead/monero) and p2pool.data_dir (/srv/pithead) overlap"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","data_dir":"/srv/pithead/monero"}, "tari":{"wallet_address":"'"$VALID_TARI"'","data_dir":"/srv/pithead/tari"}, "p2pool":{"pool":"main","data_dir":"/srv/pithead/p2pool"}, "tor":{"data_dir":"/srv/pithead/tor"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_not_contains "sibling data dirs under a shared root are not an overlap" "$out" "overlap"

# dashboard.secure is normalized like every other boolean: "TRUE"/1/"yes" render TLS (#16).
for sec in '"TRUE"' 1 '"yes"'; do
    seed_env
    printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":%s,"host":"box.lan"} }\n' "$WALLET" "$sec" >"$V/config.json"
    (cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
    assert_eq "dashboard.secure $sec renders as true" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_SECURE)" "true"
done
