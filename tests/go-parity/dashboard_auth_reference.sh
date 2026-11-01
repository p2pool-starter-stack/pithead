#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
export PITHEAD_CONFIG_FILE=$2
export PITHEAD_IMPL="${DASHBOARD_AUTH_PARITY_IMPL:-bash}"
unset PITHEAD_GO_CONFIG_DOCUMENT_BINARY PITHEAD_GO_HELPER

# shellcheck source=/dev/null
source "$root/lib/pithead/00-prelude.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/19-small-utilities.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/22-config-value-helpers.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/35-caddyfile-and-auth-helpers.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/27g-go-dashboard-auth.sh"
if [ "${DASHBOARD_AUTH_WITHOUT_GO_HOOK:-0}" = 1 ]; then
    unset -f _parse_dashboard_auth_go _parse_dashboard_policy_go
fi

env_get() {
    printf 'env_get:%s:%s:%s:%s:%s:%s:%s\n' "$1" "$DASHBOARD_AUTH_USER" \
        "$DASHBOARD_AUTH_PW_FP" "$DASHBOARD_AUTH_HASH_B64" "$DASHBOARD_ONION_ENABLED" \
        "$DASHBOARD_ONION_CLIENT_AUTH" "$DASHBOARD_CONTROL_ENABLED" >>"$DASHBOARD_AUTH_CALL_LOG"
    case "$1" in
    DASHBOARD_AUTH_PW_FP) printf '%s' "${DASHBOARD_AUTH_PREVIOUS_FP:-}" ;;
    DASHBOARD_AUTH_HASH_B64) printf '%s' "${DASHBOARD_AUTH_PREVIOUS_HASH:-}" ;;
    esac
}
caddy_hash_password_b64() {
    printf 'hash:%s:%s:%s:%s:%s:%s\n' "$DASHBOARD_AUTH_USER" "$DASHBOARD_AUTH_PW_FP" \
        "$DASHBOARD_AUTH_HASH_B64" "$DASHBOARD_ONION_ENABLED" "$DASHBOARD_ONION_CLIENT_AUTH" \
        "$DASHBOARD_CONTROL_ENABLED" >>"$DASHBOARD_AUTH_CALL_LOG"
    printf '%s' "${DASHBOARD_AUTH_SYNTHETIC_HASH:-c3ludGhldGljLWhhc2g=}"
    return "${DASHBOARD_AUTH_HASH_RC:-0}"
}
warn() {
    printf 'warn:%s:%s:%s:%s:%s:%s\n' "$DASHBOARD_AUTH_USER" "$DASHBOARD_AUTH_PW_FP" \
        "$DASHBOARD_AUTH_HASH_B64" "$DASHBOARD_ONION_ENABLED" "$DASHBOARD_ONION_CLIENT_AUTH" \
        "$DASHBOARD_CONTROL_ENABLED" >>"$DASHBOARD_AUTH_CALL_LOG"
    echo -e "${C_YELLOW}[WARNING]${C_RESET} $1" >&2
}

# shellcheck disable=SC1090
source <(
    printf '_dashboard_auth_block() {\n'
    sed -n '/^[[:space:]]*local dash_pw dashboard_auth_native=0$/,/^[[:space:]]*stamp_config_version$/p' \
        "$root/lib/pithead/28-parse-and-validate-config.sh" | sed '$d'
    printf '}\n'
)

DASHBOARD_AUTH_USER=seed-user
DASHBOARD_AUTH_HASH_B64=seed-hash
DASHBOARD_AUTH_PW_FP=seed-fingerprint
DASHBOARD_ONION_ENABLED=seed-onion
DASHBOARD_ONION_CLIENT_AUTH=seed-client-auth
DASHBOARD_CONTROL_ENABLED=seed-control
# shellcheck disable=SC2034
DASHBOARD_SECURE="${DASHBOARD_AUTH_SECURE:-true}"

_dashboard_auth_finish() {
    local rc=$?
    trap - EXIT
    printf '\0%s\0%s\0%s\0%s\0%s\0%s\0' "$DASHBOARD_AUTH_USER" \
        "$DASHBOARD_AUTH_HASH_B64" "$DASHBOARD_AUTH_PW_FP" "$DASHBOARD_ONION_ENABLED" \
        "$DASHBOARD_ONION_CLIENT_AUTH" "$DASHBOARD_CONTROL_ENABLED"
    exit "$rc"
}
trap _dashboard_auth_finish EXIT
_dashboard_auth_block
