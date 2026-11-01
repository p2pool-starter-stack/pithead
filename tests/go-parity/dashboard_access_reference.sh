#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
export PITHEAD_CONFIG_FILE=$2
export PITHEAD_IMPL="${DASHBOARD_ACCESS_PARITY_IMPL:-bash}"
unset PITHEAD_GO_CONFIG_DOCUMENT_BINARY PITHEAD_GO_HELPER

# shellcheck source=/dev/null
source "$root/lib/pithead/00-prelude.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/19-small-utilities.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/19a-config-defaults.sh"
config_platform() {
    if [ "${PITHEAD_APPLIANCE:-0}" = 1 ]; then printf appliance; else printf diy; fi
}
if [ -n "${DASHBOARD_ACCESS_DEFAULTS_FILE:-}" ]; then
    config_defaults_json() { cat "$DASHBOARD_ACCESS_DEFAULTS_FILE"; }
fi
# shellcheck source=/dev/null
source "$root/lib/pithead/22-config-value-helpers.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/27f-go-dashboard-access.sh"
if [ "${DASHBOARD_ACCESS_WITHOUT_GO_HOOK:-0}" = 1 ]; then unset -f _parse_dashboard_access_go; fi

detect_host_timezone() {
    printf 'detect:%s:%s:%s:%s:%s\n' "$DASHBOARD_HOST" "$HOST_PORT" "$DASHBOARD_SECURE" \
        "$DASHBOARD_EXPOSE_PUBLIC_IP" "$DASHBOARD_TZ" >>"$DASHBOARD_ACCESS_CALL_LOG"
    printf '%s' "${DASHBOARD_ACCESS_TIMEZONE:-Europe/Test}"
    return "${DASHBOARD_ACCESS_TIMEZONE_RC:-0}"
}

# shellcheck disable=SC1090
source <(
    printf '_dashboard_access_block() {\n'
    sed -n '/^[[:space:]]*local dashboard_access_timezone$/,/^[[:space:]]*# Optional dashboard login/p' \
        "$root/lib/pithead/28-parse-and-validate-config.sh" | sed '$d'
    printf '}\n'
)

DASHBOARD_HOST=seed-host
HOST_PORT=seed-port
DASHBOARD_SECURE=seed-secure
DASHBOARD_EXPOSE_PUBLIC_IP=seed-expose
DASHBOARD_TZ=seed-timezone

_dashboard_access_finish() {
    local rc=$?
    trap - EXIT
    printf '\0%s\0%s\0%s\0%s\0%s\0' "$DASHBOARD_HOST" "$HOST_PORT" "$DASHBOARD_SECURE" \
        "$DASHBOARD_EXPOSE_PUBLIC_IP" "$DASHBOARD_TZ"
    exit "$rc"
}
trap _dashboard_access_finish EXIT
if [ "${DASHBOARD_ACCESS_ERR_TRAP:-0}" = 1 ]; then
    trap 'printf "err:%s\n" "$?" >>"$DASHBOARD_ACCESS_CALL_LOG"' ERR
fi
_dashboard_access_block
