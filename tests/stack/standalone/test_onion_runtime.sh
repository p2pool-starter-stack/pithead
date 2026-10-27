#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
ONION_TEST_STACK=${PITHEAD_ONION_TEST_STACK:-$ROOT/pithead}
# shellcheck source=tests/stack/lib.sh
source "$ROOT/tests/stack/lib.sh"
STACK=$ONION_TEST_STACK
echo "== unit: dashboard onion runtime refresh =="
fixture=$SANDBOX

run_fixture() (
    cd "$fixture/$1"
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    validate_stratum_port_change() { :; }
    ensure_onion_password() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    mutation_lock_acquire() { :; }
    mutation_lock_release() { :; }
    inject_service_configs() { :; }
    provision_onion_client_auth() { :; }
    provision_control_runner() { :; }
    provision_firewall_check_units() { :; }
    provision_ssh_access() { :; }
    provision_console_login() { :; }
    provision_node_onions() { :; }
    migrate_compose_project() { :; }
    apply_tor_egress_firewall() { :; }
    migrate_dashboard_data() { :; }
    reconcile_appliance_hostname() { :; }
    provision_local_miner() { :; }
    announce_dashboard_url() { :; }
    tari_upgrade_space_precheck() { :; }
    verify_release_images() { :; }
    update_current_symlink() { :; }
    is_appliance() { return 1; }
    is_source_checkout() { return 1; }
    is_deployed() { return 0; }
    log() { printf '%s\n' "$*"; }
    warn() { :; }
    sudo() { :; }
    docker() { printf '%s\n' "$*" >>engine.calls; }
    env_changed_keys() { printf 'DASHBOARD_ONION_ENABLED\n'; }
    render_env() { printf 'DEPLOYMENT_COMPLETED=true\nDASHBOARD_ONION_ADDRESS=%s\n' "$DASHBOARD_ONION" >"${1:-$ENV_FILE}"; }
    generate_caddyfile() { printf '%s\n' "$DASHBOARD_ONION" >Caddyfile; }
    provision_dashboard_onion() { DASHBOARD_ONION=new.onion; }
    provision_tor() { DASHBOARD_ONION=new.onion; }
    compose_up_checked() {
        printf '%s\n' "$*" >>up.calls
        if [ "$1" = -d ] && [ "${2:-}" = --no-deps ] && [ "${3:-}" = dashboard ] && [ "$mode" = failed ]; then return 1; fi
        cp "$ENV_FILE" runtime.env
    }
    P2POOL_ONION=pool.onion
    DASHBOARD_ONION_ENABLED=true DASHBOARD_ONION=placeholder DASHBOARD_ONION_CLIENT_AUTH=false
    TOR_DATA_DIR="$PWD/tor"
    case "$mode" in known) DASHBOARD_ONION=known.onion ;; disabled) DASHBOARD_ONION_ENABLED=false ;; esac
    case "$verb" in
    apply) apply -y ;;
    upgrade) stack_upgrade ;;
    rotate) rotate_dashboard_onion -y ;;
    esac
)

for spec in apply:new apply:known apply:disabled apply:failed upgrade:new upgrade:failed rotate:new rotate:failed; do
    verb=${spec%:*} mode=${spec#*:}
    mkdir -p "$fixture/$spec"
    printf '{}\n' >"$fixture/$spec/config.json"
    printf 'DEPLOYMENT_COMPLETED=true\nDASHBOARD_ONION_ADDRESS=placeholder\n' >"$fixture/$spec/.env"
    rc=0
    run_fixture "$spec" >"$fixture/$spec/output" 2>&1 || rc=$?
    if [ "$mode" = failed ]; then
        [ "$rc" -ne 0 ] || {
            printf 'FAIL %s accepted refresh failure\n' "$spec"
            exit 1
        }
        if [ "$verb" = apply ]; then test -f "$fixture/$spec/.env.apply-incomplete"; fi
    else
        [ "$rc" -eq 0 ] || {
            cat "$fixture/$spec/output"
            exit 1
        }
        case "$mode" in new) expected=new.onion ;; known) expected=known.onion ;; *) expected=placeholder ;; esac
        grep -qx "DASHBOARD_ONION_ADDRESS=$expected" "$fixture/$spec/runtime.env" || {
            printf 'FAIL %s dashboard kept stale environment\n' "$spec"
            exit 1
        }
        if [ "$verb" = apply ]; then test ! -e "$fixture/$spec/.env.apply-incomplete"; fi
        if [ "$mode" = known ] || [ "$mode" = disabled ]; then
            [ "$(wc -l <"$fixture/$spec/up.calls" | tr -d ' ')" -eq 1 ]
        fi
    fi
    printf 'PASS %s\n' "$spec"
done
