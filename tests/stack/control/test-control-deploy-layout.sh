# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Black-box coverage for the pre-#455 dashboard layout migration. Kept separate from
# test-control-deploy.sh so the carry and recovery tests stay below the 400-line target.

echo "== black-box: deploy-box layout (#455) =="
# A sandboxed source-checkout install whose chain data dirs share one root — the live deploy-box
# layout. Proves the default resolution, the apply-time migration, and the upgrade-time
# symlink end to end through the real CLI (docker/sudo stubbed).
L="$SANDBOX/boxroot/pithead-v9.9.9"
mkdir -p "$L/build/tari" "$L/dashboard"
: >"$L/dashboard/Dockerfile"
cp "$STACK" "$L/pithead"
make_stubs "$L/bin"
cp "$ROOT/build/tari/config.toml.template" "$L/build/tari/"
SHARED="$SANDBOX/boxroot/data"
seed_L() {
    cat >"$L/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=ORIGINALTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
}
cfg_L() { # <dashboard-extra-json>  e.g. ',"data_dir":"/pinned"'
    # $VALID_PRIMARY, not $WALLET: same trap as modules 7/8 -- $WALLET is only assigned inside
    # build_val_sandbox() (lib.sh), never called in this file, and $VALID_PRIMARY is the lib.sh
    # top-level fixture WALLET equals in that function's local/checksum-valid case.
    printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","data_dir":"%s/monero"}, "tari":{"wallet_address":"'"$VALID_TARI"'","data_dir":"%s/tari"}, "p2pool":{"pool":"main","data_dir":"%s/p2pool"}, "tor":{"data_dir":"%s/tor"}, "dashboard":{"secure":true,"host":"box.lan"%s} }\n' \
        "$VALID_PRIMARY" "$SHARED" "$SHARED" "$SHARED" "$SHARED" "$1" >"$L/config.json"
}
# Old layout on disk: the dashboard DB inside the version dir's ./data (the pre-#455 default).
seed_L
cfg_L ""
mkdir -p "$L/data/dashboard"
printf 'proddb' >"$L/data/dashboard/mining_data.db"
(cd "$L" && PATH="$L/bin:$PATH" ./pithead apply -y) >/dev/null 2>&1
assert_rc "apply with a shared data root succeeds" "$?" "0"
assert_eq "DASHBOARD_DATA_DIR joins the shared data root" \
    "$(run_sourced "$L" env_get_file "$L/.env" DASHBOARD_DATA_DIR)" "$SHARED/dashboard"
assert_eq "apply moved the dashboard DB to the shared root" \
    "$(cat "$SHARED/dashboard/mining_data.db" 2>/dev/null)" "proddb"
if [ -e "$L/data/dashboard" ]; then bad "apply: old in-version-dir data gone" "still exists"; else ok "apply: old in-version-dir data gone"; fi
# Re-apply: no config change, nothing to migrate — clean no-op.
(cd "$L" && PATH="$L/bin:$PATH" ./pithead apply -y) >/dev/null 2>&1
assert_rc "re-apply is a no-op" "$?" "0"
assert_eq "re-apply leaves the migrated DB alone" "$(cat "$SHARED/dashboard/mining_data.db")" "proddb"
# Upgrade from the versioned dir: maintains `current ->` beside it and stays idempotent.
(cd "$L" && PATH="$L/bin:$PATH" ./pithead upgrade) >/dev/null 2>&1
assert_rc "upgrade succeeds" "$?" "0"
assert_eq "upgrade maintains current -> pithead-v9.9.9" "$(readlink "$SANDBOX/boxroot/current")" "pithead-v9.9.9"
assert_eq "upgrade leaves the migrated DB alone" "$(cat "$SHARED/dashboard/mining_data.db")" "proddb"
# Scattered custom dirs (no single parent): the classic in-install ./data default stands.
seed_L
# $VALID_PRIMARY, not $WALLET -- same trap as above.
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","data_dir":"%s/monero"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' \
    "$VALID_PRIMARY" "$SHARED" >"$L/config.json"
(cd "$L" && PATH="$L/bin:$PATH" ./pithead apply -y) >/dev/null 2>&1
assert_rc "apply with scattered data dirs succeeds" "$?" "0"
assert_eq "no shared root -> dashboard default stays ./data/dashboard" \
    "$(run_sourced "$L" env_get_file "$L/.env" DASHBOARD_DATA_DIR)" "$L/data/dashboard"
