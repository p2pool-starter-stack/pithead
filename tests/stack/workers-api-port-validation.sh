# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

workers_api_port_config() { # <JSON value>
    seed_env
    printf '{"monero":{"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"},"tari":{"wallet_address":"%s"},"p2pool":{"pool":"main"},"dashboard":{"secure":true,"host":"box.lan"},"workers":{"api_port":%s,"list":[]}}\n' \
        "$WALLET" "$VALID_TARI" "$1" >"$V/config.json"
}

echo "== config: workers.api_port is a TCP port from 1 through 65535 (#3358) =="
for api_port in 1 65535; do
    workers_api_port_config "$api_port"
    out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
    assert_rc "workers.api_port $api_port applies" "$?" "0"
    assert_eq "workers.api_port $api_port renders exactly" \
        "$(sed -n 's/^XMRIG_API_PORT=//p' "$V/.env")" "$api_port"
done

for bad_api_port in 0 -1 65536 '"8080"' true; do
    workers_api_port_config "$bad_api_port"
    out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
    rc=$?
    assert_rc "invalid workers.api_port $bad_api_port rejected" "$rc" "1"
    assert_contains "workers.api_port refusal names the invalid key ($bad_api_port)" \
        "$out" "workers.api_port"
done
