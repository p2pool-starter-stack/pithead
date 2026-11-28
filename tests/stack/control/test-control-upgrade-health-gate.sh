# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

upg_stub_common() {
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
    warn() { echo "WARN: $*"; }
    verify_release_images() { echo verify; }
    compose_up_checked() { echo compose; }
    update_current_symlink() { echo symlink; }
    provision_control_runner() { echo provision; }
}

echo "== black-box: a crash-looping service aborts the upgrade before moving \`current ->\` (#4393) =="
upg_step_order_unhealthy() {
    (
        cd "$SANDBOX" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        upg_stub_common
        wait_services_healthy() { return 1; }
        stack_upgrade
    ) | grep -xE 'verify|compose|symlink|provision' | tr '\n' ','
}
assert_eq "unhealthy service aborts upgrade before moving \`current ->\` (#4393)" \
    "$(upg_step_order_unhealthy)" "verify,compose,"

echo "== black-box: a stubbed unhealthy dashboard aborts the versioned upgrade with rc=1, restores the previous stack, and never runs the symlink step (#4393) =="
upg_abort_versioned() {
    local out rc step
    out=$(
        cd "$SANDBOX" || exit
        mkdir -p pithead-v9.9.9 pithead-v9.9.8
        ln -sfn pithead-v9.9.8 current
        cd pithead-v9.9.9 || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        upg_stub_common
        sleep() { :; }
        mutation_lock_acquire() { :; }
        mutation_lock_release() { :; }
        docker() {
            if [ "$1" = compose ] && [ "$2" = ps ]; then
                echo "cid-$5"
                return 0
            fi
            if [ "$1" = inspect ]; then
                if [ "$4" = cid-dashboard ]; then
                    echo "unhealthy 2 0 0"
                else
                    echo "healthy 60 30 3"
                fi
                return 0
            fi
            echo "rollback:$PWD"
        }
        stack_upgrade
    )
    rc=$?
    step=$(printf '%s\n' "$out" | grep -xE 'verify|compose|symlink|provision|WARN: .*|rollback:[^ ]*' | tr '\n' ',')
    printf '%src=%s' "$step" "$rc"
}
assert_eq "real gate aborts an unhealthy dashboard: rc=1, previous stack restored, no symlink step (#4393)" \
    "$(upg_abort_versioned)" \
    "verify,compose,WARN: Upgrade: dashboard did not become healthy within 120s (status: unhealthy).,rollback:$SANDBOX/pithead-v9.9.8,rc=1"

echo "== unit: the health gate sizes its bound on the container's own start_period, interval and retries (#4393) =="
health_wait_stubbed() {
    (
        cd "$SANDBOX" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        sleep() { :; }
        log() { :; }
        warn() { echo "WARN: $*"; }
        TOR_SPEC="$1"
        TOR_UNTIL="$2"
        OTHER_SPEC="$3"
        OTHER_ST="$4"
        TORCNT="$SANDBOX/tor-count.$$"
        : >"$TORCNT"
        docker() {
            if [ "$1" = compose ]; then
                echo "cid-$5"
                return 0
            fi
            local svc="${4#cid-}" st spec
            if [ "$svc" = tor ]; then
                echo $(($(cat "$TORCNT") + 1)) >"$TORCNT"
                if [ "$(cat "$TORCNT")" -le "$TOR_UNTIL" ]; then st=starting; else st=healthy; fi
                spec="$TOR_SPEC"
            else
                st="$OTHER_ST"
                spec="$OTHER_SPEC"
            fi
            case "$3" in
            *Healthcheck*) echo "$st $spec" ;;
            *) echo "$st" ;;
            esac
        }
        wait_services_healthy
        echo "rc=$?"
    )
}
assert_eq "a tor bootstrap ending at 500s passes the bound its 600s start_period sets (#4393)" \
    "$(health_wait_stubbed "600 30 5" 250 "60 30 3" healthy | tr -d '\n')" "rc=0"
assert_eq "a tor bootstrap ending at 712s — inside Docker's own 750s mark — still passes the bound (#4393)" \
    "$(health_wait_stubbed "600 30 5" 355 "60 30 3" healthy | tr -d '\n')" "rc=0"
assert_eq "a never-healthy tor times out at 600+30*5+60=810s and returns non-zero (#4393)" \
    "$(health_wait_stubbed "600 30 5" 999999 "60 30 3" healthy | tr -d '\n')" \
    "WARN: Upgrade: tor did not become healthy within 810s (status: starting).rc=1"
assert_eq "an unhealthy dashboard exits non-zero naming itself and its 60+30*3+60=210s bound (#4393)" \
    "$(health_wait_stubbed "60 30 3" 0 "60 30 3" unhealthy | tr -d '\n')" \
    "WARN: Upgrade: dashboard did not become healthy within 210s (status: unhealthy).rc=1"
assert_eq "an exited service aborts the gate naming itself and its bound, and returns non-zero (#4393)" \
    "$(health_wait_stubbed "60 30 3" 0 "60 30 3" exited | tr -d '\n')" \
    "WARN: Upgrade: dashboard did not become healthy within 210s (status: exited).rc=1"
