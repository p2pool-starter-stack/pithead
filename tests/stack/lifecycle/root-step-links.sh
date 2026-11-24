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
        DASHBOARD_ONION_ENABLED=true DASHBOARD_ONION_CLIENT_AUTH="${2:-true}" \
            DASHBOARD_ONION_CLIENT_PUBKEY=placeholder TOR_DATA_DIR="$1" provision_onion_client_auth
    ) 2>&1
}
RSL="$SANDBOX/root-step-links"
RSL_REFUSED="must be a real folder inside the Tor data folder"
mkdir -p "$RSL/outside-hs" "$RSL/outside-ac" "$RSL/outside-off/authorized_clients" "$RSL/tor-hs" \
    "$RSL/tor-ac/dashboard" "$RSL/tor-file/dashboard/authorized_clients" \
    "$RSL/tor-dangling/dashboard/authorized_clients" "$RSL/tor-real" "$RSL/tor-off-link" \
    "$RSL/tor-off-real/dashboard/authorized_clients"
chmod 755 "$RSL/outside-hs" "$RSL/outside-ac"
printf 'keep-me\n' >"$RSL/outside-hs/keep"
printf 'keep-me\n' >"$RSL/outside-off/authorized_clients/keep"
printf 'keep-me\n' >"$RSL/target-file"
chmod 644 "$RSL/target-file"
ln -s "$RSL/outside-hs" "$RSL/tor-hs/dashboard"
ln -s "$RSL/outside-ac" "$RSL/tor-ac/dashboard/authorized_clients"
ln -s "$RSL/target-file" "$RSL/tor-file/dashboard/authorized_clients/dashboard.auth"
ln -s "$RSL/missing" "$RSL/tor-dangling/dashboard/authorized_clients/dashboard.auth"
ln -s "$RSL/outside-off" "$RSL/tor-off-link/dashboard"
for rsl_case in tor-hs tor-ac; do
    out=$(rsl_onion "$RSL/$rsl_case")
    assert_rc "onion client-auth refuses a linked folder ($rsl_case)" "$?" 1
    assert_contains "onion client-auth names the folder it refuses ($rsl_case)" "$out" "$RSL_REFUSED"
done
assert_eq "onion client-auth leaves an outside dashboard folder's mode alone" "$(rsl_mode "$RSL/outside-hs")" 755
assert_eq "onion client-auth writes nothing into an outside dashboard folder" "$(ls -A "$RSL/outside-hs")" keep
assert_eq "onion client-auth leaves an outside dashboard folder's file alone" "$(cat "$RSL/outside-hs/keep")" keep-me
assert_eq "onion client-auth leaves an outside authorized_clients folder's mode alone" "$(rsl_mode "$RSL/outside-ac")" 755
assert_eq "onion client-auth writes nothing into an outside authorized_clients folder" "$(ls -A "$RSL/outside-ac")" ""
for rsl_case in tor-file tor-dangling; do
    rsl_onion "$RSL/$rsl_case" >/dev/null
    assert_rc "onion client-auth replaces a linked key file ($rsl_case)" "$?" 0
    assert_eq "the key file is a real file with the descriptor ($rsl_case)" \
        "$([ ! -L "$RSL/$rsl_case/dashboard/authorized_clients/dashboard.auth" ] && sed 's/:[A-Z2-7]*$/:KEY/' "$RSL/$rsl_case/dashboard/authorized_clients/dashboard.auth")" "descriptor:x25519:KEY"
done
assert_eq "onion client-auth leaves a linked file's content alone" "$(cat "$RSL/target-file")" keep-me
assert_eq "onion client-auth leaves a linked file's mode alone" "$(rsl_mode "$RSL/target-file")" 644
assert_eq "onion client-auth creates no dangling link target" "$([ -e "$RSL/missing" ] && echo created)" ""
rsl_onion "$RSL/tor-real" >/dev/null
assert_rc "onion client-auth writes into a real Tor data folder" "$?" 0
assert_eq "onion client-auth modes are 700, 700 and 600" "$(rsl_mode "$RSL/tor-real/dashboard") $(rsl_mode "$RSL/tor-real/dashboard/authorized_clients") $(rsl_mode "$RSL/tor-real/dashboard/authorized_clients/dashboard.auth")" "700 700 600"
out=$(rsl_onion "$RSL/tor-off-link" false)
assert_rc "client-auth off refuses a linked dashboard folder" "$?" 1
assert_contains "client-auth off names the folder it refuses" "$out" "$RSL_REFUSED"
assert_eq "client-auth off removes nothing outside the Tor data folder" "$(cat "$RSL/outside-off/authorized_clients/keep")" keep-me
rsl_onion "$RSL/tor-off-real" false >/dev/null
assert_rc "client-auth off clears a real authorized_clients folder" "$?" 0
assert_eq "client-auth off removes authorized_clients" "$([ -e "$RSL/tor-off-real/dashboard/authorized_clients" ] && echo kept)" ""

rsl_prepare() {
    (
        cd "$SANDBOX" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        umask 077
        # shellcheck disable=SC2034
        MONERO_DIR="$RSL/prep-monero" TARI_DIR="$RSL/prep-tari" TOR_DATA_DIR="$RSL/prep-tor" DASHBOARD_DIR="$RSL/prep-dash"
        # shellcheck disable=SC2034
        CLEARNET_STATE_DIR="$RSL/prep-clearnet" PROXY_TLS_DIR="$RSL/prep-tls" P2POOL_DIR="$1"
        log() { :; }
        prepare_control_dirs() { :; }
        ensure_stratum_tls_cert() { :; }
        ensure_owner() { :; }
        assert_safe_dir() { :; }
        docker() { :; }
        apply_tor_egress_firewall() { :; }
        compose_up_checked() { :; }
        mutation_lock_acquire() { :; }
        mutation_lock_release() { :; }
        env_get() { if [ "$1" = P2POOL_DATA_DIR ]; then echo "$P2POOL_DIR"; else echo "$RSL/rd-dash"; fi; }
        sudo() {
            printf '%s\n' "$*" >>"$RSL/sudo.log"
            if [ "$1" = chmod ]; then "$@"; fi
            return 0
        }
        "$2" -y
    ) >/dev/null 2>&1 </dev/null
}
rsl_stats_chmods() { grep chmod "$RSL/sudo.log" | grep -v "chmod 1777 $RSL/prep-clearnet"; }
mkdir -p "$RSL/stats-target" "$RSL/p2pool-link"
printf 'keep-me\n' >"$RSL/stats-target/file"
chmod 700 "$RSL/stats-target"
chmod 600 "$RSL/stats-target/file"
ln -s "$RSL/stats-target" "$RSL/p2pool-link/stats"
for rsl_step in prepare_directories ensure_directories reset_dashboard; do
    : >"$RSL/sudo.log"
    rmdir "$RSL/prep-monero" 2>/dev/null
    rsl_prepare "$RSL/p2pool-link" "$rsl_step"
    assert_eq "$rsl_step leaves a linked stats folder's mode alone" "$(rsl_mode "$RSL/stats-target")" 700
    assert_eq "$rsl_step leaves a file in a linked stats folder alone" "$(rsl_mode "$RSL/stats-target/file")" 600
    assert_eq "$rsl_step issues no chmod on the stats folder" "$(rsl_stats_chmods)" ""
    rsl_prepare "$RSL/p2pool-new-$rsl_step" "$rsl_step"
    assert_eq "$rsl_step creates a missing stats folder 755 under umask 077" "$(rsl_mode "$RSL/p2pool-new-$rsl_step/stats")" 755
done
