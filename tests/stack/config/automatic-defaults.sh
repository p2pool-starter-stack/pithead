#!/usr/bin/env bash
# shellcheck disable=SC2034
set -uo pipefail
# shellcheck source=tests/stack/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
AD="$SANDBOX/automatic-defaults"
mkdir -p "$AD"
printf '{"monero":{"wallet_address":"%s","node_username":"u","node_password":"p"},"tari":{"mode":"off"},"dashboard":{"secure":false},"local_miner":{"enabled":false}}\n' "$VALID_PRIMARY" >"$AD/base.json"
cp "$AD/base.json" "$AD/config.json"
for value in false null 1 '[]' '"invalid"'; do
    jq --argjson value "$value" '.donation=$value' "$AD/base.json" >"$AD/config.json"
    out=$(run_sourced "$AD" validate_donation_config 2>&1)
    assert_rc "donation block $value is refused" "$?" 1
    assert_contains "invalid donation block names the object" "$out" "donation must be an object"
done
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
parity_generate_password() { printf AbcD1234efGH5678ijKL9012mnOP3456; }
parity_wizard() {
    generate_node_password() { parity_generate_password; }
    default_node_username() { printf fixture-node; }
    run_wizard
}
parity_finalize() {
    _console() { :; }
    generate_node_password() { parity_generate_password; }
    default_node_username() { printf fixture-node; }
    ensure_appliance_dashboard_password
    parse_and_validate_config
}
for parity_platform in diy appliance; do
    parity_flag=0
    [ "$parity_platform" != appliance ] || parity_flag=1
    parity_dir="$SANDBOX/parity-$parity_platform"
    mkdir -p "$parity_dir/cli" "$parity_dir/browser" "$parity_dir/form"
    printf '%s\n\n\n\n\n\n\n' "$VALID_PRIMARY" |
        PITHEAD_APPLIANCE="$parity_flag" run_sourced "$parity_dir/cli" parity_wizard >"$parity_dir/cli.log" 2>&1
    assert_rc "$parity_platform CLI defaults generate" "$?" 0
    for parity_kind in browser form; do
        python3 - "$ROOT/dashboard" "$parity_platform" "$parity_kind" "$VALID_PRIMARY" >"$parity_dir/$parity_kind/config.json" <<'PYTHON'
import json
import sys

sys.path.insert(0, sys.argv[1])
from mining_dashboard.config.defaults import effective_defaults, merge
from mining_dashboard.wizard.defaults import explicit_wizard_config, new_machine_answers
from mining_dashboard.wizard.form import build_config
from mining_dashboard.wizard_config import prepare_config

platform, kind, wallet = sys.argv[2:]
reference = effective_defaults(platform, legacy=True)
for chain in ("monero", "tari"):
    reference[chain]["wallet_address"] = ""
if kind == "browser":
    cfg = merge(reference, new_machine_answers({}, [], platform))
    cfg["monero"]["wallet_address"] = wallet
else:
    cfg = build_config({"monero_wallet": wallet}, platform=platform)
cfg, _ = prepare_config(cfg, reference, reject_legacy_conflicts=True)
print(json.dumps(explicit_wizard_config(cfg, reference)))
PYTHON
        assert_rc "$parity_platform $parity_kind defaults generate" "$?" 0
    done
    for parity_kind in cli browser form; do
        make_stubs "$parity_dir/$parity_kind/bin"
        PATH="$parity_dir/$parity_kind/bin:$PATH" PITHEAD_APPLIANCE="$parity_flag" run_sourced "$parity_dir/$parity_kind" parity_finalize >"$parity_dir/$parity_kind.finalize.log" 2>&1
        assert_rc "$parity_platform $parity_kind defaults validate" "$?" 0
        parity_defaults=$(PITHEAD_APPLIANCE="$parity_flag" run_sourced "$parity_dir/$parity_kind" config_defaults legacy)
        jq -S --argjson defaults "$parity_defaults" '$defaults * .' "$parity_dir/$parity_kind/config.json" >"$parity_dir/$parity_kind.effective.json"
        assert_rc "$parity_platform $parity_kind effective config is complete" "$?" 0
    done
    for parity_kind in browser form; do
        assert_eq "$parity_platform $parity_kind complete config matches CLI" "$(cat "$parity_dir/$parity_kind.effective.json")" "$(cat "$parity_dir/cli.effective.json")"
    done
done
printf 'automatic defaults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
