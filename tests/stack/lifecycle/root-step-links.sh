# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
echo "== unit: root steps never write through a link in a container-owned folder =="
rsl_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
rsl_onion() {
    (
        # shellcheck disable=SC1090
        cd "$SANDBOX" && source "$STACK" 2>/dev/null
        ensure_owner() { :; }
        set +e
        DASHBOARD_ONION_ENABLED=true DASHBOARD_ONION_CLIENT_AUTH=true \
            DASHBOARD_ONION_CLIENT_PUBKEY=placeholder TOR_DATA_DIR="$1" provision_onion_client_auth
    ) 2>&1
}
RSL="$SANDBOX/root-step-links"
mkdir -p "$RSL/target-dir" "$RSL/tor-hs" "$RSL/tor-ac/dashboard" "$RSL/tor-file/dashboard/authorized_clients" \
    "$RSL/tor-dangling/dashboard/authorized_clients"
chmod 755 "$RSL/target-dir"
printf 'keep-me\n' >"$RSL/target-file"
chmod 644 "$RSL/target-file"
ln -s "$RSL/target-dir" "$RSL/tor-hs/dashboard"
ln -s "$RSL/target-dir" "$RSL/tor-ac/dashboard/authorized_clients"
ln -s "$RSL/target-file" "$RSL/tor-file/dashboard/authorized_clients/dashboard.auth"
ln -s "$RSL/missing" "$RSL/tor-dangling/dashboard/authorized_clients/dashboard.auth"
for rsl_case in tor-hs tor-ac; do
    out=$(rsl_onion "$RSL/$rsl_case")
    assert_rc "onion client-auth refuses a linked folder ($rsl_case)" "$?" 1
    assert_contains "onion client-auth names the linked folder ($rsl_case)" "$out" "Refusing to write Tor onion client-auth through the link"
done
for rsl_case in tor-file tor-dangling; do
    rsl_onion "$RSL/$rsl_case" >/dev/null
    assert_rc "onion client-auth replaces a linked key file ($rsl_case)" "$?" 0
    assert_eq "the key file is a real file with the descriptor ($rsl_case)" \
        "$([ ! -L "$RSL/$rsl_case/dashboard/authorized_clients/dashboard.auth" ] && sed 's/:[A-Z2-7]*$/:KEY/' "$RSL/$rsl_case/dashboard/authorized_clients/dashboard.auth")" "descriptor:x25519:KEY"
done
assert_eq "onion client-auth leaves a linked folder's mode alone" "$(rsl_mode "$RSL/target-dir")" 755
assert_eq "onion client-auth writes nothing into a linked folder" "$(ls -A "$RSL/target-dir")" ""
assert_eq "onion client-auth leaves a linked file's content alone" "$(cat "$RSL/target-file")" keep-me
assert_eq "onion client-auth leaves a linked file's mode alone" "$(rsl_mode "$RSL/target-file")" 644
assert_eq "onion client-auth creates no dangling link target" "$([ -e "$RSL/missing" ] && echo created)" ""

rsl_prepare() {
    (
        cd "$SANDBOX" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        # shellcheck disable=SC2034
        MONERO_DIR="$RSL/prep-monero" TARI_DIR="$RSL/prep-tari" TOR_DATA_DIR="$RSL/prep-tor" DASHBOARD_DIR="$RSL/prep-dash"
        # shellcheck disable=SC2034
        CLEARNET_STATE_DIR="$RSL/prep-clearnet" PROXY_TLS_DIR="$RSL/prep-tls" P2POOL_DIR="$1"
        log() { :; }
        prepare_control_dirs() { :; }
        ensure_stratum_tls_cert() { :; }
        ensure_owner() { :; }
        sudo() { if [ "$1" = chmod ] && [ "$2" = -R ]; then "$@"; fi; }
        "${2:-prepare_directories}"
    ) 2>&1
}
mkdir -p "$RSL/stats-target" "$RSL/p2pool-link" "$RSL/p2pool-real/stats"
chmod 700 "$RSL/stats-target" "$RSL/p2pool-real/stats"
ln -s "$RSL/stats-target" "$RSL/p2pool-link/stats"
out=$(rsl_prepare "$RSL/p2pool-link")
assert_eq "prepare_directories leaves a linked stats folder's mode alone" "$(rsl_mode "$RSL/stats-target")" 700
assert_contains "prepare_directories names the stats link it skips" "$out" "Not changing modes through the link at"
rsl_prepare "$RSL/p2pool-real" >/dev/null
assert_eq "prepare_directories still opens a real stats folder to 755" "$(rsl_mode "$RSL/p2pool-real/stats")" 755
rmdir "$RSL/prep-monero"
chmod 700 "$RSL/p2pool-real/stats"
rsl_prepare "$RSL/p2pool-link" ensure_directories >/dev/null
assert_eq "ensure_directories leaves a linked stats folder's mode alone" "$(rsl_mode "$RSL/stats-target")" 700
rmdir "$RSL/prep-monero"
rsl_prepare "$RSL/p2pool-real" ensure_directories >/dev/null
assert_eq "ensure_directories still opens a real stats folder to 755" "$(rsl_mode "$RSL/p2pool-real/stats")" 755
