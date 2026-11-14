# shellcheck shell=bash
: "${STACK_SUITE:?source through tests/stack/run.sh}"
echo "== unit: 2.0.0 configuration migration (#3576) =="
MG_FX="$ROOT/tests/stack/fixtures/config-2.0.0"
MG_DATA="$ROOT/dashboard/tests/fixtures/config-2.0.0"
MG="$SANDBOX/config-migration"
mkdir -p "$MG"

mg_normalize() {
    local line
    while IFS= read -r line; do
        case "$line" in
        PITHEAD_PROFILE=* | COMPOSE_PROJECT_NAME=*) continue ;;
        P2POOL_FLAGS=*)
            line=${line% --no-clearnet-p2p}
            line=${line% --no-upnp}
            ;;
        esac
        printf '%s\n' "$line"
    done
}

mg_render() {
    local dir="$1" input="$2" flag="$3" rendered="$1/.env"
    (cd "$dir" && bash "$MG_FX/render.sh" "$STACK" "$input" "$flag") >"$dir/render.log" 2>&1 || return 1
    {
        while IFS= read -r line; do printf '%s\n' "${line//$dir/@ROOT@}"; done <"$rendered"
        printf 'LOCAL_MINER=%s\nDASHBOARD_HOST=%s\n' "$(cat "$dir/local-miner.txt")" "$(cat "$dir/dashboard-host.txt")"
    }
}

mg_checked=0
for mg_input in "$MG_DATA"/inputs/*.json; do
    mg_name=$(basename "$mg_input" .json)
    for mg_platform in diy appliance; do
        mg_flag=0
        [ "$mg_platform" != appliance ] || mg_flag=1
        mg_dir="$MG/$mg_name-$mg_platform"
        mkdir -p "$mg_dir/render"
        cp "$mg_input" "$mg_dir/config.json"
        cp "$ROOT/VERSION" "$mg_dir/VERSION"
        PITHEAD_APPLIANCE="$mg_flag" run_sourced "$mg_dir" migrate_config_to_2_1 >/dev/null 2>&1
        assert_rc "$mg_name $mg_platform migrates" "$?" 0
        assert_eq "$mg_name $mg_platform migrated settings" \
            "$(jq -S 'del(.config_version)' "$mg_dir/config.json")" "$(cat "$MG_DATA/migrated/$mg_name.$mg_platform.json")"
        cmp -s "$mg_input" "$mg_dir/config.json.bak-2.0" && ok "$mg_name $mg_platform keeps the 2.0.0 bytes" || bad "$mg_name $mg_platform keeps the 2.0.0 bytes" "backup differs"
        assert_eq "$mg_name $mg_platform migrated mode" "$(file_mode "$mg_dir/config.json")" 600
        assert_eq "$mg_name $mg_platform backup mode" "$(file_mode "$mg_dir/config.json.bak-2.0")" 600
        cp "$mg_dir/config.json" "$mg_dir/once"
        PITHEAD_APPLIANCE="$mg_flag" run_sourced "$mg_dir" migrate_config_to_2_1 >/dev/null 2>&1
        cmp -s "$mg_dir/config.json" "$mg_dir/once" && ok "$mg_name $mg_platform second run changes nothing" || bad "$mg_name $mg_platform second run changes nothing" changed
        if mg_got=$(PITHEAD_APPLIANCE="$mg_flag" mg_render "$mg_dir/render" "$mg_input" "$mg_flag"); then
            assert_eq "$mg_name $mg_platform renders the v2.0.0 environment" "$(mg_normalize <<<"$mg_got")" \
                "$(mg_normalize <"$MG_FX/golden/$mg_name.$mg_platform.env")"
            if [ "$(jq -r .profile "$mg_dir/config.json")" = privacy ]; then
                assert_contains "$mg_name $mg_platform privacy keeps inbound peering on Tor" "$mg_got" "--no-clearnet-p2p"
            else
                case "$mg_got" in *--no-clearnet-p2p*) bad "$mg_name $mg_platform keeps clearnet inbound peering" present ;; *) ok "$mg_name $mg_platform keeps clearnet inbound peering" ;; esac
            fi
        else
            bad "$mg_name $mg_platform renders" "$(tail -3 "$mg_dir/render/render.log")"
        fi
        mg_checked=$((mg_checked + 1))
    done
done
[ "$mg_checked" -ge 30 ] && ok "migration covered $mg_checked fixture and platform pairs" || bad "migration covered every fixture" "$mg_checked"

MG_DRY="$MG/dry"
mkdir -p "$MG_DRY"
cp "$MG_DATA/inputs/diy-login.json" "$MG_DRY/config.json"
cp "$MG_DRY/config.json" "$MG_DRY/before"
PITHEAD_APPLIANCE=0 run_sourced "$MG_DRY" eval 'PITHEAD_DRY_RUN=1; migrate_config_to_2_1' >/dev/null 2>&1
assert_rc "dry migration succeeds" "$?" 0
cmp -s "$MG_DRY/config.json" "$MG_DRY/before" && ok "dry migration leaves the bytes unchanged" || bad "dry migration leaves the bytes unchanged" changed
[ ! -e "$MG_DRY/config.json.bak-2.0" ] && ok "dry migration writes no backup" || bad "dry migration writes no backup" present

MG_FUTURE="$MG/future"
mkdir -p "$MG_FUTURE"
jq '.config_version="9.9.9"' "$MG_DATA/inputs/workers-tokens.json" >"$MG_FUTURE/config.json"
cp "$ROOT/VERSION" "$MG_FUTURE/VERSION"
cp "$MG_FUTURE/config.json" "$MG_FUTURE/before"
mg_out=$(PITHEAD_APPLIANCE=0 run_sourced "$MG_FUTURE" parse_and_validate_config 2>&1)
cmp -s "$MG_FUTURE/config.json" "$MG_FUTURE/before" && ok "a future stamp is left alone" || bad "a future stamp is left alone" changed
assert_contains "a future stamp keeps the existing warning" "$mg_out" "written by pithead 9.9.9"

MG_INFER="$MG/infer"
mkdir -p "$MG_INFER"
for mg_case in 'clearnet-performance performance' 'privacy-shaped privacy' 'diy-login balance'; do
    read -r mg_fixture mg_expected <<<"$mg_case"
    cp "$MG_DATA/inputs/$mg_fixture.json" "$MG_INFER/config.json"
    PITHEAD_APPLIANCE=0 run_sourced "$MG_INFER" migrate_config_to_2_1 >/dev/null 2>&1
    assert_eq "$mg_fixture infers $mg_expected" "$(jq -r .profile "$MG_INFER/config.json")" "$mg_expected"
done
jq '.p2pool.clearnet=true | .tor.auto_heal=true' "$MG_DATA/inputs/diy-login.json" >"$MG_INFER/config.json"
PITHEAD_APPLIANCE=0 run_sourced "$MG_INFER" migrate_config_to_2_1 >/dev/null 2>&1
assert_eq "a mixed config migrates to balance" "$(jq -r .profile "$MG_INFER/config.json")" balance
assert_eq "a mixed config keeps its explicit override" "$(jq -r .p2pool.clearnet "$MG_INFER/config.json")" true

jq '.monero.clearnet_initial_sync=true | .tari.clearnet_initial_sync=true | .network.tor_egress_firewall=false' "$MG_DATA/inputs/diy-login.json" >"$MG_INFER/config.json"
PITHEAD_APPLIANCE=0 run_sourced "$MG_INFER" migrate_config_to_2_1 >/dev/null 2>&1
assert_eq "a partly Performance-shaped config stays balance" "$(jq -r .profile "$MG_INFER/config.json")" balance

MG_BAK="$MG/backup-failure"
mkdir -p "$MG_BAK"
cp "$MG_DATA/inputs/diy-login.json" "$MG_BAK/config.json"
PITHEAD_APPLIANCE=0 run_sourced "$MG_BAK" eval 'cp() { return 1; }; migrate_config_to_2_1' >/dev/null 2>&1
assert_rc "a failed backup refuses the migration" "$?" 1
cmp -s "$MG_BAK/config.json" "$MG_DATA/inputs/diy-login.json" && ok "a failed backup leaves the config untouched" || bad "a failed backup leaves the config untouched" changed

build_backup_sandbox
cp "$ROOT/VERSION" "$BK/VERSION"
MG_TREE="$MG/restore-tree"
mkdir -p "$MG_TREE/${BK#/}"
cp "$MG_DATA/inputs/workers-tokens.json" "$MG_TREE/${BK#/}/config.json"
cp "$BK/.env" "$MG_TREE/${BK#/}/.env"
tar -czf "$MG/v2.tar.gz" -C "$MG_TREE" "${BK#/}/config.json" "${BK#/}/.env"
run_sourced "$BK" restore_apply "$MG/v2.tar.gz" "" "$MG/restore-error" "$MG/restored" "" "$MG/restore-stage" >/dev/null 2>&1
assert_rc "a 2.0.0 backup restores" "$?" 0
cp "$MG/restored" "$BK/config.json"
PITHEAD_APPLIANCE=0 run_sourced "$BK" parse_and_validate_config >/dev/null 2>&1
assert_rc "a restored 2.0.0 backup applies" "$?" 0
assert_eq "a restored 2.0.0 backup ends migrated" "$(jq -r .profile "$BK/config.json")" balance
