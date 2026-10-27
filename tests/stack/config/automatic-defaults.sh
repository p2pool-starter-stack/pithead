#!/usr/bin/env bash
# shellcheck disable=SC2034
set -uo pipefail
# shellcheck source=tests/stack/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
AD="$SANDBOX/automatic-defaults"
mkdir -p "$AD"
printf '{"monero":{"wallet_address":"%s","node_username":"u","node_password":"p"},"tari":{"mode":"off"},"dashboard":{"secure":false},"local_miner":{"enabled":false}}\n' "$VALID_PRIMARY" >"$AD/base.json"
cp "$AD/base.json" "$AD/config.json"
for value in 0 11 '"5"' 2.5 true null; do
    jq --argjson value "$value" '.donation.percent = $value' "$AD/base.json" >"$AD/config.json"
    out=$(run_sourced "$AD" validate_donation_config 2>&1)
    assert_rc "invalid donation percentage $value is refused" "$?" 1
    assert_contains "invalid percentage names the field" "$out" "donation.percent"
done
for value in $(seq 1 10); do
    jq --argjson value "$value" '.donation.percent = $value' "$AD/base.json" >"$AD/config.json"
    run_sourced "$AD" validate_donation_config >/dev/null 2>&1
    assert_rc "donation percentage $value accepted" "$?" 0
done
for key in enabled tor; do
    for value in '"true"' 1 null; do
        jq --arg key "$key" --argjson value "$value" '.donation[$key] = $value' "$AD/base.json" >"$AD/config.json"
        out=$(run_sourced "$AD" validate_donation_config 2>&1)
        assert_rc "non-boolean donation $key refused" "$?" 1
        assert_contains "boolean error names the field" "$out" "donation.$key"
    done
    for value in true false; do
        jq --arg key "$key" --argjson value "$value" '.donation[$key] = $value' "$AD/base.json" >"$AD/config.json"
        run_sourced "$AD" validate_donation_config >/dev/null 2>&1
        assert_rc "boolean donation $key accepted" "$?" 0
    done
done
automatic_render() {
    host_memtotal_kb() { printf %s "$AD_MEM"; }
    hostname() { printf test-machine; }
    chown() { return 0; }
    detect_host_timezone() { printf UTC; }
    MONERO_ONION=monero.onion TARI_ONION=tari.onion P2POOL_ONION=p2pool.onion
    DASHBOARD_ONION="" DASHBOARD_ONION_CLIENT_PUBKEY="" DASHBOARD_ONION_CLIENT_PRIVKEY=""
    PROXY_AUTH_TOKEN=fixture-proxy-token TARI_WALLET_PASSWORD="" WALLET_RPC_PASSWORD=""
    parse_and_validate_config
    resolve_dashboard_host
    render_env
}
for memory in 8388607 8388608 8388609; do
    cp "$AD/base.json" "$AD/config.json"
    AD_MEM="$memory" run_sourced "$AD" automatic_render >"$AD/render.log" 2>&1
    assert_rc "automatic defaults render at $memory KiB" "$?" 0
    flags=$(run_sourced "$AD" env_get_file "$AD/.env" P2POOL_FLAGS)
    if [ "$memory" -lt 8388608 ]; then
        assert_contains "low-RAM host uses light mode" "$flags" "--light-mode"
    else
        assert_not_contains "host at or above floor uses full mode" "$flags" "--light-mode"
    fi
    for row in "DONATION_ENABLED false" "DONATION_PERCENT 2" "DONATION_TOR_ENABLED true" "XMRIG_API_PORT 8080" "HOST_IP test-machine"; do
        read -r key expected <<<"$row"
        assert_eq "rendered $key uses its automatic default" "$(run_sourced "$AD" env_get_file "$AD/.env" "$key")" "$expected"
    done
done
jq '.workers.api_port=null | .dashboard.host="explicit-machine"' "$AD/base.json" >"$AD/config.json"
AD_MEM=8388608 run_sourced "$AD" automatic_render >"$AD/render.log" 2>&1
assert_rc "null worker port renders" "$?" 0
assert_eq "null worker port means 8080" "$(run_sourced "$AD" env_get_file "$AD/.env" XMRIG_API_PORT)" 8080
assert_eq "explicit hostname wins" "$(run_sourced "$AD" env_get_file "$AD/.env" HOST_IP)" explicit-machine
for row in "remote off false 3" "local off false 8" "local local false 14" "local local true 17"; do
    read -r monero tari miner expected <<<"$row"
    jq --arg monero "$monero" --arg tari "$tari" --argjson miner "$miner" '.monero.mode=$monero | .tari.mode=$tari | .local_miner.enabled=$miner' "$AD/base.json" >"$AD/config.json"
    assert_eq "mode-aware memory floor $row" "$(run_sourced "$AD" low_ram_floor_gb)" "$expected"
done
build_val_sandbox
seed_env
dashboard_pass="$(run_sourced "$V" generate_node_password)"
assert_eq "diagnostic fixture uses a generated password" "$(printf %s "$dashboard_pass" | wc -c | tr -d ' ')" 32
jq --arg p "$dashboard_pass" '.dashboard.auth={username:"admin",password:$p}' "$AD/base.json" >"$V/config.json"
(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y >"$V/apply.log" 2>&1)
assert_rc "password-bearing diagnostics fixture applies" "$?" 0
status_out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead status 2>&1 || true)"
assert_contains "status reached service diagnostics" "$status_out" "Service health check"
assert_not_contains "status never prints dashboard password" "$status_out" "$dashboard_pass"
doctor_out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead doctor 2>&1 || true)"
assert_contains "doctor reached diagnostics summary" "$doctor_out" "Diagnostics summary"
assert_not_contains "doctor never prints dashboard password" "$doctor_out" "$dashboard_pass"
(cd "$V" && PATH="$V/bin:$PATH" ./pithead doctor --json >"$V/doctor.json" 2>"$V/doctor.err") || true
assert_eq "doctor JSON contains checks" "$(jq -r 'has("checks")' "$V/doctor.json")" true
assert_not_contains "doctor JSON never prints dashboard password" "$(cat "$V/doctor.json" "$V/doctor.err")" "$dashboard_pass"
(cd "$V" && PATH="$V/bin:$PATH" ./pithead support-bundle >"$V/bundle.log" 2>&1)
assert_rc "support bundle succeeds" "$?" 0
bundle_tar=$(find "$V" -maxdepth 1 -name 'support-bundle-*.tar.gz' | head -1)
assert_contains "support bundle exists" "$bundle_tar" "support-bundle-"
mkdir -p "$V/extracted"
tar -xzf "$bundle_tar" -C "$V/extracted"
assert_rc "support bundle extracts" "$?" 0
if grep -r -F -q -- "$dashboard_pass" "$V/extracted"; then
    bad "support bundle never contains dashboard password" "generated password found"
else
    assert_rc "support bundle never contains dashboard password" "$?" 1
fi
printf 'automatic defaults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
