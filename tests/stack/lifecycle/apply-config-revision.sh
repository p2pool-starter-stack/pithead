# shellcheck shell=bash
: "${STACK_SUITE:?source through tests/stack/run.sh}"

echo "== unit: apply rejects a rendered config whose revision changed =="

ACR="$SANDBOX/apply-config-revision"

apply_revision_reset() { # <config-label> <env-label> [retry]
    rm -rf "$ACR"
    mkdir -p "$ACR"
    printf '%s\n' "$1" >"$ACR/config.json"
    printf 'MONERO_WALLET_ADDRESS=%s\n' "$2" >"$ACR/.env"
    [ "${3:-0}" -eq 0 ] || : >"$ACR/.env.apply-incomplete"
    : >"$ACR/actions"
}

apply_revision_run() { # <injected-label|none> <confirmation> [scope] [interactive|yes]
    local inject="$1" confirmation="$2" scope="${3:-both}" mode="${4:-interactive}" fake="$ACR/pithead-test"
    STACK="$STACK" ACR="$ACR" INJECT_LABEL="$inject" INJECT_SCOPE="$scope" CONFIRM_MODE="$confirmation" APPLY_MODE="$mode" \
        bash -Eeuo pipefail -c '
        cd "$ACR"
        source "$STACK"
        trap cleanup_env_staging EXIT
        TEST_LOCK_DEPTH=0
        RENDER_LABEL=""
        P2POOL_ONION=onion-state-present
        require_env() { :; }
        validate_stratum_port_change() { :; }
        ensure_onion_password() { :; }
        parse_and_validate_config() { RENDER_LABEL=$(cat "$CONFIG_FILE"); }
        load_preserved_state() { :; }
        onion_missing() { return 1; }
        is_deployed() { return 0; }
        ensure_directories() { :; }
        resolve_dashboard_host() { :; }
        render_env() {
            printf "MONERO_WALLET_ADDRESS=%s\n" "$RENDER_LABEL" >"$1"
            : >"$ACR/rendered"
        }
        describe_change() { printf "DEST\tpayout changed\n"; }
        read() {
            local variable="${*: -1}" answer="wrong"
            [ "$variable" = CONFIRM ] || {
                builtin read "$@"
                return
            }
            printf "prompt-depth=%s\n" "$TEST_LOCK_DEPTH" >>"$ACR/actions"
            [ "$CONFIRM_MODE" != correct ] || answer="${RENDER_LABEL: -8}"
            printf -v "$variable" "%s" "$answer"
        }
        mutation_lock_acquire() {
            TEST_LOCK_DEPTH=$((TEST_LOCK_DEPTH + 1))
            printf "acquire\n" >>"$ACR/actions"
            if [ -f "$ACR/rendered" ] && [ ! -f "$ACR/injected" ] && [ "$INJECT_LABEL" != none ]; then
                [ "$INJECT_SCOPE" = env ] || printf "%s\n" "$INJECT_LABEL" >"$CONFIG_FILE"
                [ "$INJECT_SCOPE" = config ] || printf "MONERO_WALLET_ADDRESS=%s\n" "$INJECT_LABEL" >"$ENV_FILE"
                : >"$ACR/injected"
            fi
        }
        mutation_lock_release() {
            [ "$TEST_LOCK_DEPTH" -eq 0 ] || TEST_LOCK_DEPTH=$((TEST_LOCK_DEPTH - 1))
            printf "release\n" >>"$ACR/actions"
        }
        mv() {
            case "$*" in *"$PITHEAD_ENV_STAGE "*) printf "publish\n" >>"$ACR/actions" ;; esac
            command mv "$@"
        }
        compose_up_checked() { printf "recreate\n" >>"$ACR/actions"; }
        provision_node_onions() { :; }
        inject_service_configs() { :; }
        generate_caddyfile() { :; }
        carry_dashboard_data_move() { :; }
        lan_guard_arm_transition() { :; }
        provision_onion_client_auth() { :; }
        provision_control_runner() { :; }
        provision_firewall_check_units() { :; }
        provision_ssh_access() { :; }
        provision_console_login() { :; }
        render_local_miner_config() { :; }
        provision_local_miner() { :; }
        reconcile_appliance_hostname() { :; }
        migrate_compose_project() { :; }
        apply_tor_egress_firewall() { :; }
        migrate_dashboard_data() { :; }
        update_current_symlink() { :; }
        announce_dashboard_url() { :; }
        is_appliance() { return 1; }
        docker() { :; }
        if [ "$APPLY_MODE" = yes ]; then apply -y; else apply; fi
    ' "$fake"
}

apply_revision_stale_case() { # <name> <config-label> <env-label> [retry] [scope] [mode]
    local name="$1" config="$2" env="$3" retry="${4:-0}" scope="${5:-both}" mode="${6:-interactive}" rc expected_config expected_env
    apply_revision_reset "$config" "$env" "$retry"
    apply_revision_run wallet-B-confirmB correct "$scope" "$mode" >/dev/null 2>&1
    rc=$?
    expected_config=wallet-B-confirmB
    expected_env=wallet-B-confirmB
    [ "$scope" != env ] || expected_config="$config"
    [ "$scope" != config ] || expected_env="$env"
    assert_rc "$name: stale render is rejected" "$rc" 1
    assert_eq "$name: newer config revision remains canonical" "$(cat "$ACR/config.json")" "$expected_config"
    assert_eq "$name: newer environment revision remains published" \
        "$(cat "$ACR/.env")" "MONERO_WALLET_ADDRESS=$expected_env"
    assert_not_contains "$name: stale environment A is not published" "$(cat "$ACR/actions")" publish
    assert_not_contains "$name: services are not recreated from stale A" "$(cat "$ACR/actions")" recreate
    if compgen -G "$ACR/.env.new.*" >/dev/null; then
        bad "$name: stale staging is removed" "a staged environment remains"
    else
        ok "$name: stale staging is removed"
    fi
}

apply_revision_stale_case changed wallet-A-confirmA wallet-old-label
assert_contains "changed: apply reaches the wallet confirmation" "$(cat "$ACR/actions")" prompt-depth=0
apply_revision_stale_case config-only wallet-A-confirmA wallet-old-label 0 config
apply_revision_stale_case environment-only wallet-A-confirmA wallet-old-label 0 env
apply_revision_stale_case changed-assume-yes wallet-A-confirmA wallet-old-label 0 both yes
assert_not_contains "changed --yes: no interactive confirmation is attempted" "$(cat "$ACR/actions")" prompt-depth

apply_revision_stale_case unchanged wallet-A-confirmA wallet-A-confirmA
apply_revision_stale_case retry wallet-A-confirmA wallet-A-confirmA 1

apply_revision_reset wallet-A-confirmA wallet-old-label
apply_revision_run none correct >/dev/null 2>&1
assert_rc "stable revision: apply succeeds" "$?" 0
assert_contains "stable revision: the confirmed environment is published" "$(cat "$ACR/actions")" publish
assert_contains "stable revision: services are recreated" "$(cat "$ACR/actions")" recreate
assert_contains "stable revision: no mutation lock is held at the prompt" "$(cat "$ACR/actions")" prompt-depth=0

apply_revision_reset wallet-A-confirmA wallet-old-label
apply_revision_run none decline >/dev/null 2>&1
assert_rc "declined wallet redirect: apply returns cleanly" "$?" 0
assert_eq "declined wallet redirect: live environment is untouched" \
    "$(cat "$ACR/.env")" "MONERO_WALLET_ADDRESS=wallet-old-label"
assert_not_contains "declined wallet redirect: services are not recreated" "$(cat "$ACR/actions")" recreate
if compgen -G "$ACR/.env.new.*" >/dev/null; then
    bad "declined wallet redirect: staging is removed" "a staged environment remains"
else
    ok "declined wallet redirect: staging is removed"
fi

apply_revision_reset wallet-C-confirmC wallet-B-confirmB
apply_revision_run none correct >/dev/null 2>&1
assert_rc "fresh invocation: a newly rendered and confirmed redirect succeeds" "$?" 0
assert_eq "fresh invocation: publishes only the freshly confirmed wallet label" \
    "$(cat "$ACR/.env")" "MONERO_WALLET_ADDRESS=wallet-C-confirmC"
assert_contains "fresh invocation: asks for a new confirmation with no lock held" \
    "$(cat "$ACR/actions")" prompt-depth=0

unset -f apply_revision_reset apply_revision_run apply_revision_stale_case
