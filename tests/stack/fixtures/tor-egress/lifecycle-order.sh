# shellcheck shell=bash
make_stubs "$SANDBOX/lifecycle-bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$SANDBOX/lifecycle-bin/systemctl"
chmod +x "$SANDBOX/lifecycle-bin/systemctl"

echo "== regression: every command installs the Tor-egress firewall BEFORE compose (#291) =="

up_order=$(
    cd "$SANDBOX" || exit
    export PATH="$SANDBOX/lifecycle-bin:$PATH"
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    log() { :; }
    warn_missing_data_dirs() { :; }
    migrate_compose_project() { :; }
    print_clearnet_banner() { :; }
    announce_dashboard_url() { :; }
    apply_tor_egress_firewall() { echo firewall; }
    compose_up_checked() { echo compose; }
    printf '{}\n' >config.json
    stack_up
)
assert_eq "up applies the firewall before 'compose up' (#276)" "$(fw_then_compose "$up_order")" "firewall,compose,"

upg_order=$(
    cd "$SANDBOX" || exit
    export PATH="$SANDBOX/lifecycle-bin:$PATH"
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    mv() { :; }
    inject_service_configs() { :; }
    generate_caddyfile() { :; }
    migrate_compose_project() { :; }
    is_source_checkout() { return 1; }
    log() { :; }
    docker() { :; }
    apply_tor_egress_firewall() { echo firewall; }
    compose_up_checked() { echo compose; }
    stack_upgrade
)
assert_eq "upgrade applies the firewall before 'compose up' (#291)" "$(fw_then_compose "$upg_order")" "firewall,compose,"

upg_onion_order=$(
    cd "$SANDBOX" || exit
    export PATH="$SANDBOX/lifecycle-bin:$PATH"
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    ensure_onion_password() { echo onionpw; }
    parse_and_validate_config() { echo validate; }
    load_preserved_state() { :; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    mv() { :; }
    inject_service_configs() { :; }
    generate_caddyfile() { :; }
    migrate_compose_project() { :; }
    is_source_checkout() { return 1; }
    log() { :; }
    docker() { :; }
    apply_tor_egress_firewall() { :; }
    compose_up_checked() { :; }
    stack_upgrade
)
assert_eq "upgrade runs ensure_onion_password before config validation (#355)" \
    "$(printf '%s\n' "$upg_onion_order" | grep -xE 'onionpw|validate' | tr '\n' ',')" "onionpw,validate,"

upg_sig_order=$(
    cd "$SANDBOX" || exit
    export PATH="$SANDBOX/lifecycle-bin:$PATH"
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
    generate_caddyfile() { :; }
    provision_control_runner() { :; }
    migrate_compose_project() { :; }
    is_source_checkout() { return 1; }
    log() { :; }
    docker() { :; }
    apply_tor_egress_firewall() { :; }
    verify_release_images() { echo verify; }
    compose_up_checked() { echo compose; }
    stack_upgrade
)
assert_eq "upgrade verifies release-image signatures before 'compose up' (#376)" \
    "$(printf '%s\n' "$upg_sig_order" | grep -xE 'verify|compose' | tr '\n' ',')" "verify,compose,"

up_sig_order=$(
    cd "$SANDBOX" || exit
    export PATH="$SANDBOX/lifecycle-bin:$PATH"
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    warn_missing_data_dirs() { :; }
    migrate_compose_project() { :; }
    apply_tor_egress_firewall() { :; }
    print_clearnet_banner() { :; }
    announce_dashboard_url() { :; }
    print_first_run_epilogue() { :; }
    log() { :; }
    verify_release_images() { echo verify; }
    compose_up_checked() { echo compose; }
    printf '{}\n' >config.json
    stack_up
)
assert_eq "first-install up verifies release-image signatures before 'compose up' (#452)" \
    "$(printf '%s\n' "$up_sig_order" | grep -xE 'verify|compose' | tr '\n' ',')" "verify,compose,"

apply_order=$(
    cd "$SANDBOX" || exit
    export PATH="$SANDBOX/lifecycle-bin:$PATH"
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    # shellcheck disable=SC2034
    P2POOL_ONION=onion
    require_env() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    is_deployed() { return 0; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    env_changed_keys() { :; }
    mv() { :; }
    inject_service_configs() { :; }
    generate_caddyfile() { :; }
    migrate_compose_project() { :; }
    announce_dashboard_url() { :; }
    log() { :; }
    warn() { :; }
    docker() { :; }
    apply_tor_egress_firewall() { echo firewall; }
    compose_up_checked() { echo compose; }
    : >".env.apply-incomplete"
    apply
)
assert_eq "apply applies the firewall before 'compose up' (#291)" "$(fw_then_compose "$apply_order")" "firewall,compose,"

rd_order=$(
    cd "$SANDBOX" || exit
    export PATH="$SANDBOX/lifecycle-bin:$PATH"
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    env_get() { echo "/nonexistent/reset-$1"; }
    assert_safe_dir() { :; }
    mkdir() { :; }
    sudo() { :; }
    log() { :; }
    docker() {
        [ "$1 $2" = "compose up" ] && echo compose
        return 0
    }
    apply_tor_egress_firewall() { echo firewall; }
    reset_dashboard -y
)
assert_eq "reset-dashboard applies the firewall before 'compose up' (#291)" "$(fw_then_compose "$rd_order")" "firewall,compose,"
