# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

echo "== black-box: a crash-looping service aborts the upgrade before moving \`current ->\` (#4393) =="
upg_step_order_unhealthy() {
    (
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
        render_env() { [ -n "${1:-}" ] && : >"$1"; }
        provision_node_onions() { :; }
        inject_service_configs() { :; }
        generate_caddyfile() { :; }
        migrate_compose_project() { :; }
        apply_tor_egress_firewall() { :; }
        migrate_dashboard_data() { :; }
        is_source_checkout() { return 1; }
        log() { :; }
        verify_release_images() { echo verify; }
        compose_up_checked() { echo compose; }
        wait_services_healthy() { return 1; }
        update_current_symlink() { echo symlink; }
        provision_control_runner() { echo provision; }
        stack_upgrade
    ) | grep -xE 'verify|compose|symlink|provision' | tr '\n' ','
}
assert_eq "unhealthy service aborts upgrade before moving \`current ->\` (#4393)" \
    "$(upg_step_order_unhealthy)" "verify,compose,"

echo "== unit: the health gate waits past 120s when the container's own start_period says so (#4393) =="
health_wait_stubbed() {
    (
        cd "$SANDBOX" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        sleep() { :; }
        log() { :; }
        error() {
            echo "ERR: $*"
            return 1
        }
        TOR_SP="$1"
        TOR_UNTIL="$2"
        OTHER="$3"
        TORCNT="$SANDBOX/tor-count.$$"
        : >"$TORCNT"
        docker() {
            if [ "$1" = compose ]; then
                echo "cid-$5"
                return 0
            fi
            local svc="${4#cid-}" st sp
            if [ "$svc" = tor ]; then
                echo $(($(cat "$TORCNT") + 1)) >"$TORCNT"
                if [ "$(cat "$TORCNT")" -le "$TOR_UNTIL" ]; then st=starting; else st=healthy; fi
                sp="$TOR_SP"
            else
                st="$OTHER"
                sp=60
            fi
            case "$3" in
            *Healthcheck*) echo "$st $sp" ;;
            *) echo "$st" ;;
            esac
        }
        wait_services_healthy
        echo "rc=$?"
    )
}
assert_eq "a tor bootstrap ending at 500s passes the gate its 600s start_period sets (#4393)" \
    "$(health_wait_stubbed 600 250 healthy | tr -d '\n')" "rc=0"
assert_contains "an exited service aborts the gate naming itself and the bound (#4393)" \
    "$(health_wait_stubbed 60 0 exited | tr -d '\n')" \
    "Upgrade: dashboard did not become healthy within 120s (status: exited)."
