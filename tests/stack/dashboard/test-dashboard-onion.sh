# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
echo "== unit: generate_caddyfile onion vhost (#343) =="
auth_hb64="$(printf '%s' '$2y$14$UNITTESTbcrypthashvalue000000000000000000000000000000' | openssl base64 -A)"
# shellcheck disable=SC1090
caddy_onion="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="$auth_hb64" \
        DASHBOARD_ONION_ENABLED=true NETWORK_PREFIX=172.28.0 generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "onion vhost bound to the bridge gateway" "$caddy_onion" "http://172.28.0.1 {"
assert_contains "onion vhost carries basic_auth" "$caddy_onion" "basic_auth"
onion_site="${caddy_onion#*172.28.0.1}"
case "$onion_site" in
*"tls internal"*) bad "onion vhost is plain HTTP" "'tls internal' present on the onion site" ;;
*) ok "onion vhost is plain HTTP (no tls internal)" ;;
esac
# shellcheck disable=SC1090
(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_HASH_B64="" \
        DASHBOARD_ONION_ENABLED=true NETWORK_PREFIX=172.28.0 generate_caddyfile >/dev/null 2>&1
)
assert_rc "onion without a login refuses to render" "$?" "1"
# shellcheck disable=SC1090
caddy_noonion="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="$auth_hb64" \
        DASHBOARD_ONION_ENABLED=false NETWORK_PREFIX=172.28.0 generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_not_contains "no onion vhost when disabled" "$caddy_noonion" "172.28.0.1"
# shellcheck disable=SC1090
caddy_onion_https="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="$auth_hb64" \
        DASHBOARD_ONION_ENABLED=true DASHBOARD_ONION=abcd234onionname.onion NETWORK_PREFIX=172.28.0 generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "onion HTTP vhost still present with the address set (#343)" "$caddy_onion_https" "http://172.28.0.1 {"
assert_contains "onion HTTPS vhost on the .onion name (#343)" "$caddy_onion_https" "https://abcd234onionname.onion {"
https_site="${caddy_onion_https#*https://abcd234onionname.onion}"
case "$https_site" in
*"tls internal"*) ok "onion HTTPS vhost uses a self-signed cert (tls internal)" ;;
*) bad "onion HTTPS vhost uses tls internal" "no 'tls internal' on the https onion site" ;;
esac
assert_contains "onion HTTPS vhost carries the same basic_auth (#343)" "$https_site" "basic_auth"
# shellcheck disable=SC1090
caddy_onion_ph="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="$auth_hb64" \
        DASHBOARD_ONION_ENABLED=true DASHBOARD_ONION=placeholder NETWORK_PREFIX=172.28.0 generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "onion HTTP vhost renders even before the address is captured (#343)" "$caddy_onion_ph" "http://172.28.0.1 {"
assert_not_contains "no HTTPS onion vhost until the .onion address is provisioned (#343)" "$caddy_onion_ph" "https://placeholder"

echo "== unit: generate_caddyfile access log (#349) =="
# shellcheck disable=SC1090
caddy_https="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_HASH_B64="" generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "access log block rendered" "$caddy_https" "output file /var/log/caddy/access.log"
assert_contains "access log is JSON" "$caddy_https" "wrap json"
assert_contains "access log growth is bounded (roll_size)" "$caddy_https" "roll_size 4MiB"
assert_contains "rolled files are capped (roll_keep)" "$caddy_https" "roll_keep 2"
assert_contains "access log stays dashboard-readable (mode 0644)" "$caddy_https" "mode 0644"
log_count="$(printf '%s' "$caddy_onion_https" | grep -c 'output file /var/log/caddy/access.log')"
assert_eq "every vhost (LAN + onion HTTP + onion HTTPS) writes the shared log" "$log_count" "3"

echo "== unit: onion client-auth crypto (#343) =="
assert_eq "b32encode_hex('f') = MY" "$(run_sourced "$SANDBOX" b32encode_hex 66)" "MY"
assert_eq "b32encode_hex('foobar') = MZXW6YTBOI" "$(run_sourced "$SANDBOX" b32encode_hex 666f6f626172)" "MZXW6YTBOI"
kp="$(run_sourced "$SANDBOX" generate_onion_client_keypair)"
set -- $kp
assert_eq "client pubkey is 52-char base32" "${#1}" "52"
assert_eq "client privkey is 52-char base32" "${#2}" "52"
if [ "$1" != "$2" ]; then ok "client pub != priv"; else bad "client pub != priv" "identical keys generated"; fi
case "$1$2" in *[!A-Z2-7]*) bad "client keys use the base32 alphabet" "non-base32 char present" ;; *) ok "client keys use the base32 alphabet" ;; esac

ac_root="$SANDBOX/tor-ac"
rm -rf "$ac_root"
mkdir -p "$ac_root"
# shellcheck disable=SC1090
(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    ensure_owner() { :; }
    set +e
    DASHBOARD_ONION_ENABLED=true DASHBOARD_ONION_CLIENT_AUTH=true \
        DASHBOARD_ONION_CLIENT_PUBKEY=placeholder TOR_DATA_DIR="$ac_root" \
        APP_UID=$(id -u) APP_GID=$(id -g) provision_onion_client_auth >/dev/null 2>&1
)
ac_file="$ac_root/dashboard/authorized_clients/dashboard.auth"
if [ -f "$ac_file" ]; then ok "authorized_clients/dashboard.auth is written"; else bad "authorized_clients/dashboard.auth is written" "file missing"; fi
assert_contains "authorized_clients carries a v3 descriptor" "$(cat "$ac_file" 2>/dev/null)" "descriptor:x25519:"
ac_dir_mode="$(stat -c '%a' "$ac_root/dashboard" 2>/dev/null || stat -f '%Lp' "$ac_root/dashboard" 2>/dev/null)"
ac_subdir_mode="$(stat -c '%a' "$ac_root/dashboard/authorized_clients" 2>/dev/null || stat -f '%Lp' "$ac_root/dashboard/authorized_clients" 2>/dev/null)"
ac_key_mode="$(stat -c '%a' "$ac_file" 2>/dev/null || stat -f '%Lp' "$ac_file" 2>/dev/null)"
assert_eq "hidden-service dir is 0700" "$ac_dir_mode" "700"
assert_eq "authorized_clients dir is 0700" "$ac_subdir_mode" "700"
assert_eq "authorized_clients key file is 0600" "$ac_key_mode" "600"
# shellcheck disable=SC1090
(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_ONION_ENABLED=true DASHBOARD_ONION_CLIENT_AUTH=false TOR_DATA_DIR="$ac_root" \
        provision_onion_client_auth >/dev/null 2>&1
)
if [ -d "$ac_root/dashboard/authorized_clients" ]; then bad "client-auth off clears authorized_clients" "dir still present"; else ok "client-auth off clears authorized_clients"; fi

echo "== unit: ensure_onion_password auto-generates (#343) =="
autopw_dir="$SANDBOX/onion-autopw"
mkdir -p "$autopw_dir"
autopw_cfg="$autopw_dir/config.json"
printf '{"dashboard":{"onion":{"enabled":true}}}' >"$autopw_cfg"
# shellcheck disable=SC1090
(cd "$autopw_dir" && source "$STACK" 2>/dev/null && ensure_onion_password >/dev/null 2>&1)
genpw="$(jq -r '.dashboard.auth.password // ""' "$autopw_cfg")"
if [ "${#genpw}" -ge 16 ]; then ok "ensure_onion_password writes a >=16-char password"; else bad "ensure_onion_password writes a >=16-char password" "length ${#genpw}"; fi
# shellcheck disable=SC1090
(cd "$autopw_dir" && source "$STACK" 2>/dev/null && ensure_onion_password >/dev/null 2>&1)
assert_eq "ensure_onion_password leaves an existing password alone" "$(jq -r '.dashboard.auth.password' "$autopw_cfg")" "$genpw"
printf '{"dashboard":{}}' >"$autopw_cfg"
# shellcheck disable=SC1090
(cd "$autopw_dir" && source "$STACK" 2>/dev/null && ensure_onion_password >/dev/null 2>&1)
assert_eq "ensure_onion_password no-op when onion off" "$(jq -r '.dashboard.auth.password // "none"' "$autopw_cfg")" "none"

upg_autopw_dir="$SANDBOX/upgrade-onion-autopw"
mkdir -p "$upg_autopw_dir"
printf '{"dashboard":{"onion":{"enabled":true}}}' >"$upg_autopw_dir/config.json"
(
    cd "$upg_autopw_dir" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    inject_service_configs() { :; }
    generate_caddyfile() { :; }
    migrate_compose_project() { :; }
    apply_tor_egress_firewall() { :; }
    provision_egress_check_units() { :; }
    provision_lan_guard_check_units() { :; }
    compose_up_checked() { :; }
    is_source_checkout() { return 1; }
    docker() { :; }
    log() { :; }
    stack_upgrade >/dev/null 2>&1
)
upg_genpw="$(jq -r '.dashboard.auth.password // ""' "$upg_autopw_dir/config.json")"
if [ "${#upg_genpw}" -ge 16 ]; then ok "upgrade auto-generates the onion password (not an error)"; else bad "upgrade auto-generates the onion password (not an error)" "length ${#upg_genpw}"; fi

echo "== black-box: rotate-dashboard-onion command flow (#356) =="
rot_out=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    export DASHBOARD_ONION_ENABLED=true
    export DASHBOARD_ONION_CLIENT_AUTH=false
    TOR_DATA_DIR="$SANDBOX/rot-tor"
    mkdir -p "$TOR_DATA_DIR/dashboard"
    warn() { :; }
    log() { :; }
    docker() { :; }
    sudo() { :; }
    env_get() { [ "$1" = "DEPLOYMENT_COMPLETED" ] && echo true || echo "x.onion"; }
    resolve_dashboard_host() { HOST_IP="host.set"; }
    provision_tor() { :; }
    render_env() { echo "HOST_IP=${HOST_IP-UNSET} DC=${DEPLOYMENT_COMPLETED-UNSET}"; }
    generate_caddyfile() { :; }
    onion_client_key() { :; }
    rotate_dashboard_onion -y
)
assert_rc "rotate command completes with its focused fixture" "$?" 0
assert_contains "rotate resolves the host before render_env — no unbound HOST_IP (#356)" "$rot_out" "HOST_IP=host.set"
assert_contains "rotate preserves DEPLOYMENT_COMPLETED across render_env (#356)" "$rot_out" "DC=true"

echo "== black-box: upgrade captures a just-enabled dashboard onion address (#356) =="
upg_capture() {
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    ensure_onion_password() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    mv() { :; }
    inject_service_configs() { :; }
    generate_caddyfile() { echo caddyfile-rendered; }
    migrate_compose_project() { :; }
    is_source_checkout() { return 1; }
    log() { :; }
    docker() { :; }
    apply_tor_egress_firewall() { :; }
    provision_egress_check_units() { :; }
    provision_lan_guard_check_units() { :; }
    compose_up_checked() { :; }
    provision_dashboard_onion() {
        DASHBOARD_ONION="upgcap5678.onion"
        echo captured
    }
    export DASHBOARD_ONION_ENABLED="$1"
    export DASHBOARD_ONION="$2"
    stack_upgrade
}
assert_contains "upgrade captures the onion address when enabled + uncaptured (#356)" "$(upg_capture true '')" "captured"
assert_not_contains "upgrade skips capture when the onion is disabled (#356)" "$(upg_capture false '')" "captured"

upg_regen_on=$(upg_capture true '' | grep -c "caddyfile-rendered")
case "$upg_regen_on" in
2) ok "upgrade capture regenerates the Caddyfile (#546)" ;;
*) bad "upgrade capture regenerates the Caddyfile (#546)" "generate_caddyfile ran $upg_regen_on time(s), want 2 (preamble + capture)" ;;
esac
upg_regen_off=$(upg_capture false '' | grep -c "caddyfile-rendered")
case "$upg_regen_off" in
1) ok "upgrade without onion renders the Caddyfile once (#546)" ;;
*) bad "upgrade without onion renders the Caddyfile once (#546)" "generate_caddyfile ran $upg_regen_off time(s), want 1" ;;
esac

echo "== black-box: apply captures + renders the HTTPS onion vhost in the SAME run (#546) =="
AOC="$SANDBOX/apply-onion-capture"
mkdir -p "$AOC"
printf 'DEPLOYMENT_COMPLETED=true\n' >"$AOC/.env"
caddy_apply_capture=$(
    cd "$AOC" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    ensure_onion_password() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    mv() { :; }
    env_changed_keys() { echo DASHBOARD_ONION_ENABLED; }
    inject_service_configs() { :; }
    provision_onion_client_auth() { :; }
    provision_control_runner() { :; }
    migrate_compose_project() { :; }
    apply_tor_egress_firewall() { :; }
    provision_egress_check_units() { :; }
    provision_lan_guard_check_units() { :; }
    migrate_dashboard_data() { :; }
    compose_up_checked() { :; }
    announce_dashboard_url() { :; }
    log() { :; }
    warn() { :; }
    docker() { :; }
    provision_dashboard_onion() { DASHBOARD_ONION="captured1234abcd.onion"; }
    P2POOL_ONION=p2pa.onion HOST_IP=box.lan DASHBOARD_SECURE=true DASHBOARD_AUTH_USER=admin \
        DASHBOARD_AUTH_HASH_B64="$auth_hb64" NETWORK_PREFIX=172.28.0 DASHBOARD_ONION_ENABLED=true \
        DASHBOARD_ONION=placeholder apply -y >/dev/null 2>&1
    cat Caddyfile
)
assert_contains "apply: HTTPS onion vhost appears in the SAME apply run (#546)" "$caddy_apply_capture" "https://captured1234abcd.onion {"
assert_contains "apply: HTTP onion vhost (bridge gateway) still present" "$caddy_apply_capture" "http://172.28.0.1 {"

echo "== black-box: rotate-dashboard-onion regenerates the Caddyfile (#546) =="
ROC="$SANDBOX/rotate-onion-capture"
mkdir -p "$ROC/rot-tor/dashboard"
cat >"$ROC/Caddyfile" <<'EOF'
https://box.lan {
    tls internal
}

http://172.28.0.1 {
}

https://oldaddr1234.onion {
    tls internal
}
EOF
caddy_rotate_capture=$(
    cd "$ROC" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    warn() { :; }
    log() { :; }
    docker() { :; }
    sudo() { :; }
    env_get() { :; }
    render_env() { :; }
    resolve_dashboard_host() { HOST_IP=box.lan; }
    provision_tor() { DASHBOARD_ONION="newaddr5678.onion"; }
    onion_client_key() { :; }
    export DASHBOARD_ONION_ENABLED=true
    export DASHBOARD_ONION_CLIENT_AUTH=false
    TOR_DATA_DIR="$ROC/rot-tor" DASHBOARD_SECURE=true DASHBOARD_AUTH_USER=admin \
        DASHBOARD_AUTH_HASH_B64="$auth_hb64" NETWORK_PREFIX=172.28.0 rotate_dashboard_onion -y >/dev/null 2>&1
    cat Caddyfile
)
assert_not_contains "rotate drops the retired onion's HTTPS vhost (#546)" "$caddy_rotate_capture" "oldaddr1234.onion"
assert_contains "rotate adds the new onion's HTTPS vhost in the same run (#546)" "$caddy_rotate_capture" "https://newaddr5678.onion {"

echo "== unit: dashboard_onion_status surfaces the onion URL for status/doctor (#343) =="
onion_env_dir() {
    local d
    mk_tmpdir d
    {
        echo "DASHBOARD_ONION_ENABLED=$1"
        echo "DASHBOARD_ONION_ADDRESS=$2"
        echo "DASHBOARD_ONION_CLIENT_AUTH=$3"
    } >"$d/.env"
    echo "$d"
}
od_on="$(onion_env_dir true abcd.onion true)"
assert_contains "status onion: URL + client-key pointer when client-auth on" \
    "$(run_sourced "$od_on" dashboard_onion_status)" "http://abcd.onion (client-auth ON + login; get your client key with"
assert_not_contains "status onion: never prints a client key" \
    "$(run_sourced "$od_on" dashboard_onion_status)" "descriptor:x25519:"
od_noauth="$(onion_env_dir true abcd.onion false)"
assert_eq "status onion: login-required line when client-auth off" \
    "$(run_sourced "$od_noauth" dashboard_onion_status)" "http://abcd.onion (login required)"
od_unprov="$(onion_env_dir true placeholder true)"
assert_eq "status onion: nothing while unprovisioned (placeholder)" \
    "$(run_sourced "$od_unprov" dashboard_onion_status)" ""
od_off="$(onion_env_dir false abcd.onion true)"
assert_eq "status onion: nothing when the onion is disabled" \
    "$(run_sourced "$od_off" dashboard_onion_status)" ""
rm -rf "$od_on" "$od_noauth" "$od_unprov" "$od_off"
