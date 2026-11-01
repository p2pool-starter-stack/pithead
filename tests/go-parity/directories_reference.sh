#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
workdir=$2
export PITHEAD_CONFIG_FILE=$3
export PITHEAD_IMPL="${DIRECTORIES_PARITY_IMPL:-bash}"
unset PITHEAD_GO_CONFIG_DOCUMENT_BINARY PITHEAD_GO_HELPER
cd -P "$workdir"

# shellcheck source=/dev/null
source "$root/lib/pithead/00-prelude.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/19-small-utilities.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/27h-go-directories.sh"
if [ "${DIRECTORIES_WITHOUT_GO_HOOK:-0}" = 1 ]; then unset -f _parse_directories_go; fi

eval "$(declare -f assert_safe_dir | sed '1s/assert_safe_dir/_directories_actual_assert_safe_dir/')"
directories_assert_count=0
assert_safe_dir() {
    local d=$1
    directories_assert_count=$((directories_assert_count + 1))
    # shellcheck disable=SC2154
    printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
        "$d" "$MONERO_DIR" "$TARI_DIR" "$P2POOL_DIR" "$TOR_DATA_DIR" \
        "$DASHBOARD_DIR" "$DASHBOARD_DIR_IS_DEFAULT" "$PROXY_TLS_DIR" \
        "$CLEARNET_STATE_DIR" "$CONTROL_DIR" "$CADDY_LOG_DIR" "$_data_root" "$_dash_cfg" \
        >>"$DIRECTORIES_CALL_LOG"
    if [ "$directories_assert_count" = "${DIRECTORIES_FAIL_INDEX:-0}" ]; then
        [ "${DIRECTORIES_RETURN_RC:-0}" = 0 ] || return "$DIRECTORIES_RETURN_RC"
        _directories_actual_assert_safe_dir "${DIRECTORIES_FAIL_PATH:-/}"
    else
        _directories_actual_assert_safe_dir "$d"
    fi
}

# shellcheck disable=SC1090
source <(
    printf '_directories_block() {\n'
    sed -n '/^[[:space:]]*local _data_root _dash_cfg$/,/^[[:space:]]*local dashboard_access_timezone$/p' \
        "$root/lib/pithead/28-parse-and-validate-config.sh" | sed '$d'
    printf '_directories_finish\n}\n'
)

MONERO_DIR=seed-monero
TARI_DIR=seed-tari
P2POOL_DIR=seed-p2pool
TOR_DATA_DIR=seed-tor
DASHBOARD_DIR=seed-dashboard
DASHBOARD_DIR_IS_DEFAULT=seed-dashboard-default
PROXY_TLS_DIR=seed-proxy-tls
CLEARNET_STATE_DIR=seed-clearnet
CONTROL_DIR=seed-control
CADDY_LOG_DIR=seed-caddy-log

_directories_finish() {
    local rc=$?
    trap - EXIT
    printf 'exit:%s\0' "$rc" >>"$DIRECTORIES_TRAP_LOG"
    printf '\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
        "$MONERO_DIR" "$TARI_DIR" "$P2POOL_DIR" "$TOR_DATA_DIR" "$DASHBOARD_DIR" \
        "$DASHBOARD_DIR_IS_DEFAULT" "$PROXY_TLS_DIR" "$CLEARNET_STATE_DIR" \
        "$CONTROL_DIR" "$CADDY_LOG_DIR" "${_data_root:-}" "${_dash_cfg:-}"
    exit "$rc"
}
trap _directories_finish EXIT
if [ "${DIRECTORIES_ERR_TRAP:-0}" = 1 ]; then
    trap 'printf "err:%s\0" "$?" >>"$DIRECTORIES_TRAP_LOG"' ERR
fi
_directories_block
