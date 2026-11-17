# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

echo "== unit: apply retries service convergence after publication failures =="
AR="$SANDBOX/apply-retry"
AR_LOG="$AR/operations.log"

apply_retry_reset() {
    rm -rf "$AR"
    mkdir -p "$AR/data/dashboard"
    printf '{}\n' >"$AR/config.json"
    printf '%s\n' \
        'MONERO_WALLET_ADDRESS=identity-a' \
        'MONERO_NODE_HOST=identity-a' \
        'TARI_MODE=local' \
        "DASHBOARD_DATA_DIR=$AR/data/dashboard" >"$AR/.env"
    : >"$AR_LOG"
}

apply_retry_run() {
    local wallet="${1:-identity-a}" monero_host="${2:-identity-a}" tari_mode="${3:-local}"
    local inject_fail="${4:-0}" compose_fail="${5:-0}" assume_yes="${6:-1}"
    STACK="$STACK" AR="$AR" AR_LOG="$AR_LOG" NEXT_WALLET="$wallet" \
        NEXT_MONERO_HOST="$monero_host" NEXT_TARI_MODE="$tari_mode" \
        INJECT_FAIL="$inject_fail" COMPOSE_FAIL="$compose_fail" APPLY_YES="$assume_yes" \
        MARKER_WRITE_FAIL="${MARKER_WRITE_FAIL:-0}" \
        "$BASH" -Eeuo pipefail -s <<'EOF'
cd "$AR"
# shellcheck disable=SC1090
source "$STACK"
require_env() { :; }
validate_stratum_port_change() { :; }
ensure_onion_password() { :; }
parse_and_validate_config() {
    DASHBOARD_DIR="$AR/data/dashboard"
    DASHBOARD_DIR_IS_DEFAULT=1
    DASHBOARD_ONION_ENABLED=false
}
load_preserved_state() { :; }
is_deployed() { return 0; }
onion_missing() { return 1; }
ensure_directories() { :; }
resolve_dashboard_host() { :; }
render_env() {
    printf '%s\n' \
        "MONERO_WALLET_ADDRESS=$NEXT_WALLET" \
        "MONERO_NODE_HOST=$NEXT_MONERO_HOST" \
        "TARI_MODE=$NEXT_TARI_MODE" \
        "DASHBOARD_DATA_DIR=$AR/data/dashboard" >"${1:-$ENV_FILE}"
}
describe_change() { printf 'DEST\t%s changed\n' "$1"; }
mutation_lock_acquire() { :; }
mutation_lock_release() { :; }
echo() {
    case "${1:-}" in
    rearm-tari-only | rearm-sync-gate)
        if [ "$MARKER_WRITE_FAIL" -eq 1 ]; then
            builtin echo -n truncated
            return 28
        fi
        ;;
    esac
    builtin echo "$@"
}
carry_dashboard_data_move() { :; }
lan_guard_arm_transition() { return 0; }
provision_node_onions() { :; }
inject_service_configs() {
    printf 'inject\n' >>"$AR_LOG"
    [ "$INJECT_FAIL" -eq 0 ] || return 23
}
generate_caddyfile() { : >Caddyfile; }
provision_onion_client_auth() { :; }
provision_control_runner() { :; }
provision_firewall_check_units() { return 0; }
provision_ssh_access() { :; }
provision_console_login() { :; }
render_local_miner_config() { :; }
migrate_compose_project() { :; }
apply_tor_egress_firewall() { :; }
migrate_dashboard_data() { :; }
rearm_sync_gate_marker() {
    mkdir -p "$1"
    printf 'scope:%s\n' "$2" >>"$AR_LOG"
    : >"$1/sync-gate-reset"
}
compose_up_checked() {
    if [ "$*" = '-d --remove-orphans' ]; then
        printf 'compose:main\n' >>"$AR_LOG"
        [ "$COMPOSE_FAIL" -eq 0 ] || return 1
    else
        printf 'compose:recovery\n' >>"$AR_LOG"
    fi
}
reconcile_appliance_hostname() { :; }
provision_local_miner() { :; }
announce_dashboard_url() { :; }
apply_refresh_appliance_tls() { :; }
docker() { printf 'docker:%s\n' "$*" >>"$AR_LOG"; }
P2POOL_ONION=present
if [ "$APPLY_YES" -eq 1 ]; then
    apply -y
else
    apply
fi
EOF
}

apply_retry_count() { grep -c "^$1$" "$AR_LOG" 2>/dev/null || true; }
apply_retry_env() { run_sourced "$AR" env_get_file "$AR/.env" "$1"; }

apply_retry_reset
apply_retry_run identity-b identity-a local 1 >/dev/null 2>&1
assert_rc "injection failure after publication remains red" "$?" 23
assert_eq "failed injection leaves identity B published" "$(apply_retry_env MONERO_WALLET_ADDRESS)" identity-b
assert_eq "failed injection leaves the retry marker armed" "$([ -f "$AR/.env.apply-incomplete" ] && echo present || echo absent)" present
assert_eq "failed injection reaches no container recreation" "$(apply_retry_count compose:main)" 0

: >"$AR_LOG"
apply_retry_run identity-b identity-a local 1 >/dev/null 2>&1
assert_rc "unchanged retry repeats a failing injection" "$?" 23
assert_eq "repeated injection failure retains the marker" "$([ -f "$AR/.env.apply-incomplete" ] && echo present || echo absent)" present
assert_eq "repeated injection failure reaches no recreation" "$(apply_retry_count compose:main)" 0

: >"$AR_LOG"
apply_retry_run identity-b identity-a local >/dev/null 2>&1
assert_rc "successful unchanged retry converges services" "$?" 0
assert_eq "successful retry injects before recreation" "$(grep -xE 'inject|compose:main' "$AR_LOG" | tr '\n' ',')" 'inject,compose:main,'
assert_eq "successful retry clears its marker" "$([ -e "$AR/.env.apply-incomplete" ] && echo present || echo absent)" absent

: >"$AR_LOG"
apply_retry_run identity-b identity-a local >/dev/null 2>&1
assert_rc "final unchanged apply succeeds" "$?" 0
assert_eq "final unchanged apply does not inject again" "$(apply_retry_count inject)" 0
assert_eq "final unchanged apply does not recreate" "$(apply_retry_count compose:main)" 0

apply_retry_reset
mkdir "$AR/.env.apply-incomplete"
apply_retry_run identity-b identity-a local >/dev/null 2>&1
assert_rc "retry-marker creation failure is red" "$?" 1
assert_eq "retry-marker creation failure prevents env publication" "$(apply_retry_env MONERO_WALLET_ADDRESS)" identity-a
assert_eq "retry-marker creation failure reaches no injection" "$(apply_retry_count inject)" 0

apply_retry_reset
apply_retry_run identity-b identity-a local 0 0 0 >/dev/null 2>&1
assert_rc "cancelled wallet confirmation returns cleanly" "$?" 0
assert_eq "cancelled confirmation keeps identity A" "$(apply_retry_env MONERO_WALLET_ADDRESS)" identity-a
assert_eq "cancelled confirmation does not arm the retry marker" "$([ -e "$AR/.env.apply-incomplete" ] && echo present || echo absent)" absent

apply_retry_scope_case() {
    local label="$1" wallet="$2" monero_host="$3" tari_mode="$4" payload="$5"
    apply_retry_reset
    apply_retry_run "$wallet" "$monero_host" "$tari_mode" 0 1 >/dev/null 2>&1
    assert_rc "$label compose failure is red" "$?" 1
    assert_eq "$label compose failure retains reset scope" "$(cat "$AR/.env.apply-incomplete" 2>/dev/null)" "$payload"
    : >"$AR_LOG"
    apply_retry_run "$wallet" "$monero_host" "$tari_mode" 1 >/dev/null 2>&1
    assert_rc "$label retry injection failure is red" "$?" 23
    assert_eq "$label early retry failure preserves reset scope" "$(cat "$AR/.env.apply-incomplete" 2>/dev/null)" "$payload"
    : >"$AR_LOG"
    apply_retry_run "$wallet" "$monero_host" "$tari_mode" >/dev/null 2>&1
    assert_rc "$label retry succeeds" "$?" 0
    assert_eq "$label successful retry injects before recreation" "$(grep -xE 'inject|compose:main' "$AR_LOG" | tr '\n' ',')" 'inject,compose:main,'
    assert_eq "$label successful retry clears the marker" "$([ -e "$AR/.env.apply-incomplete" ] && echo present || echo absent)" absent
}

apply_retry_scope_case "Tari-mode" identity-a identity-a remote rearm-tari-only
apply_retry_scope_case "Monero-node" identity-a identity-b local rearm-sync-gate

apply_retry_reset
apply_retry_run identity-a identity-a remote 1 >/dev/null 2>&1
assert_rc "changed Tari mode fails when injection fails" "$?" 23
assert_eq "changed Tari mode records its selected reset scope before injection" \
    "$(cat "$AR/.env.apply-incomplete" 2>/dev/null)" rearm-tari-only

for scope in rearm-tari-only rearm-sync-gate; do
    apply_retry_reset
    printf '%s\n' "$scope" >"$AR/.env.apply-incomplete"
    MARKER_WRITE_FAIL=1 apply_retry_run identity-b identity-a local >/dev/null 2>&1
    assert_rc "$scope marker write failure is red" "$?" 1
    assert_eq "$scope survives a partial marker write" "$(cat "$AR/.env.apply-incomplete")" "$scope"
    assert_eq "$scope marker write failure prevents env publication" "$(apply_retry_env MONERO_WALLET_ADDRESS)" identity-a
    assert_eq "$scope marker write failure reaches no injection" "$(apply_retry_count inject)" 0
    assert_eq "$scope marker write failure cleans its staging file" "$(find "$AR" -name '.env.apply-incomplete.*' | wc -l)" 0
done
