#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/stack/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
echo "== unit: shared defaults exports, setup parity and v2.0.0 compatibility =="
if python3 "$ROOT/scripts/build-config-defaults.py" --check; then
    ok "defaults exports match the canonical table"
else
    bad "defaults exports match the canonical table"
fi
for defaults_platform in diy appliance; do
    defaults_flag=0
    [ "$defaults_platform" != appliance ] || defaults_flag=1
    defaults_dir="$SANDBOX/defaults-$defaults_platform"
    mkdir -p "$defaults_dir"
    defaults_minimal="$ROOT/config.minimal.json"
    [ "$defaults_platform" != appliance ] || defaults_minimal="$ROOT/config.minimal.appliance.json"
    defaults_expected=$(PITHEAD_APPLIANCE="$defaults_flag" run_sourced "$defaults_dir" new_install_defaults)
    printf '%s\n\n\n\n\n\n\n\n\n\n\n' "$VALID_PRIMARY" |
        PITHEAD_APPLIANCE="$defaults_flag" run_sourced "$defaults_dir" run_wizard >"$defaults_dir/wizard.log" 2>&1
    for defaults_path in tari.mode xvb.enabled dashboard.tari_required dashboard.host local_miner.enabled; do
        defaults_value=$(jq -c --arg p "$defaults_path" 'getpath($p | split("."))' <<<"$defaults_expected")
        assert_eq "$defaults_platform CLI Enter-through $defaults_path" \
            "$(jq -c --arg p "$defaults_path" 'getpath($p | split("."))' "$defaults_dir/config.json")" "$defaults_value"
        assert_eq "$defaults_platform minimal $defaults_path" \
            "$(jq -c --arg p "$defaults_path" 'getpath($p | split("."))' "$defaults_minimal")" "$defaults_value"
    done
    mkdir -p "$defaults_dir/golden"
    if (cd "$defaults_dir/golden" && bash "$ROOT/tests/stack/fixtures/config-2.0.0/render.sh" \
        "$STACK" "$ROOT/tests/stack/fixtures/config-2.0.0/absent.json" "$defaults_flag") >"$defaults_dir/golden.log" 2>&1; then
        ok "$defaults_platform sparse v2 config parses and renders"
        sed "s|$defaults_dir/golden|@ROOT@|g" "$defaults_dir/golden/.env" >"$defaults_dir/normalized.env"
        assert_eq "$defaults_platform full env matches v2.0.0 golden" \
            "$(cat "$defaults_dir/normalized.env")" \
            "$(awk '/^COMPOSE_PROFILES=/ { print "COMPOSE_PROJECT_NAME=pithead" } { print }' "$ROOT/tests/stack/fixtures/config-2.0.0/$defaults_platform.env")"
        assert_eq "$defaults_platform absent local_miner.enabled matches v2.0.0" \
            "$(cat "$defaults_dir/golden/local-miner.txt")" "$(cat "$ROOT/tests/stack/fixtures/config-2.0.0/$defaults_platform.local-miner")"
        assert_eq "$defaults_platform absent dashboard.host matches v2.0.0" \
            "$(cat "$defaults_dir/golden/dashboard-host.txt")" "$(cat "$ROOT/tests/stack/fixtures/config-2.0.0/$defaults_platform.dashboard-host")"
        for defaults_legacy in 'tari.mode local' 'xvb.enabled true' 'dashboard.tari_required true'; do
            read -r defaults_key defaults_value <<<"$defaults_legacy"
            assert_eq "$defaults_platform LEGACY_ABSENT $defaults_key" \
                "$(PITHEAD_APPLIANCE="$defaults_flag" run_sourced "$defaults_dir/golden" config_get "$defaults_key")" "$defaults_value"
        done
    else
        bad "$defaults_platform sparse v2 config parses and renders" "$(tail -5 "$defaults_dir/golden.log")"
    fi
done

for defaults_platform in diy appliance; do
    defaults_flag=0
    [ "$defaults_platform" != appliance ] || defaults_flag=1
    defaults_dir="$SANDBOX/parity-$defaults_platform"
    mkdir -p "$defaults_dir"
    defaults_full=$(PITHEAD_APPLIANCE="$defaults_flag" run_sourced "$defaults_dir" config_defaults legacy)
    mkdir -p "$defaults_dir/empty"
    printf '{}\n' >"$defaults_dir/empty/config.json"
    defaults_checked=0
    while IFS= read -r defaults_path; do
        defaults_value=$(jq -r --arg p "$defaults_path" 'getpath($p | split("."))' <<<"$defaults_full")
        assert_eq "$defaults_platform absent table leaf $defaults_path" \
            "$(PITHEAD_APPLIANCE="$defaults_flag" run_sourced "$defaults_dir/empty" config_get "$defaults_path")" "$defaults_value"
        defaults_checked=$((defaults_checked + 1))
    done < <(jq -r 'paths as $p | select(getpath($p) | type != "object") | $p | join(".")' <<<"$defaults_full")
    [ "$defaults_checked" -gt 0 ] && ok "$defaults_platform table leaves were checked" || bad "$defaults_platform table leaves were checked"
    jq --argjson defaults "$defaults_full" '
        $defaults * . | .dashboard.control.enabled = false' \
        "$ROOT/tests/stack/fixtures/config-2.0.0/absent.json" >"$defaults_dir/full.json"
    for defaults_kind in absent full minimal; do
        defaults_fixture="$ROOT/tests/stack/fixtures/config-2.0.0/absent.json"
        [ "$defaults_kind" != full ] || defaults_fixture="$defaults_dir/full.json"
        if [ "$defaults_kind" = minimal ]; then
            defaults_minimal="$ROOT/config.minimal.json"
            [ "$defaults_platform" != appliance ] || defaults_minimal="$ROOT/config.minimal.appliance.json"
            jq --arg wallet "$VALID_PRIMARY" '.monero.wallet_address = $wallet' \
                "$defaults_minimal" >"$defaults_dir/minimal.json"
            defaults_fixture="$defaults_dir/minimal.json"
        fi
        mkdir -p "$defaults_dir/$defaults_kind"
        if (cd "$defaults_dir/$defaults_kind" && bash "$ROOT/tests/stack/fixtures/config-2.0.0/render.sh" \
            "$STACK" "$defaults_fixture" "$defaults_flag" platform-defaults) >"$defaults_dir/$defaults_kind.log" 2>&1; then
            ok "$defaults_platform $defaults_kind default configuration parses and renders"
            sed "s|$defaults_dir/$defaults_kind|@ROOT@|g" "$defaults_dir/$defaults_kind/.env" >"$defaults_dir/$defaults_kind.env"
        else
            bad "$defaults_platform $defaults_kind default configuration parses and renders" "$(tail -5 "$defaults_dir/$defaults_kind.log")"
        fi
    done
    assert_eq "$defaults_platform every non-required table default agrees with absent-key rendering" \
        "$(cat "$defaults_dir/full.env")" "$(cat "$defaults_dir/absent.env")"
    for defaults_row in 'TARI_MODE off' 'XVB_ENABLED false' 'TARI_REQUIRED false'; do
        read -r defaults_key defaults_value <<<"$defaults_row"
        assert_eq "$defaults_platform parsed minimal $defaults_key" \
            "$(grep "^$defaults_key=" "$defaults_dir/minimal.env" | cut -d= -f2-)" "$defaults_value"
    done
done

defaults_preview() {
    local table
    table=$(config_defaults_json | jq --arg mode "$1" '
        (.LEGACY_ABSENT[] | select(.path == "tari.mode")).value = $mode')
    config_defaults_json() { printf '%s' "$table"; }
    control_mark_config_confirm_rows tari.remote.host '' "$2"
}
for defaults_legacy_mode in local off; do
    for defaults_explicit_mode in null local off; do
        defaults_staged="$SANDBOX/preview.json"
        jq -n --arg mode "$defaults_explicit_mode" '{tari: {mode: (if $mode == "null" then null else $mode end)}}' >"$defaults_staged"
        defaults_expected="$defaults_explicit_mode"
        [ "$defaults_explicit_mode" != null ] || defaults_expected="$defaults_legacy_mode"
        defaults_message='Remote node endpoint settings are changing.'
        [ "$defaults_expected" != off ] || defaults_message='Tari remote settings are stored but inactive while merge-mining is off.'
        assert_contains "control preview uses $defaults_legacy_mode fallback and $defaults_explicit_mode explicit mode" \
            "$(run_sourced "$SANDBOX" defaults_preview "$defaults_legacy_mode" "$defaults_staged")" "$defaults_message"
    done
done

printf 'shared defaults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
