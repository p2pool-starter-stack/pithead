#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
export PITHEAD_CONFIG_FILE=$2
export PITHEAD_IMPL="${PROXY_SETTINGS_PARITY_IMPL:-bash}"
unset PITHEAD_GO_CONFIG_DOCUMENT_BINARY PITHEAD_GO_HELPER

# shellcheck source=/dev/null
source "$root/lib/pithead/00-prelude.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/19-small-utilities.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/22-config-value-helpers.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/27e-go-proxy-settings.sh"
if [ "${PROXY_SETTINGS_WITHOUT_GO_HOOK:-0}" = 1 ]; then unset -f _parse_proxy_config_go; fi

env_get() {
    printf 'env_get:%s\n' "$1" >>"$PROXY_SETTINGS_CALL_LOG"
    printf '%s' "${PROXY_SETTINGS_PREVIOUS_PASSWORD:-}"
}
openssl() {
    [ "$*" = 'rand -hex 12' ] || return 97
    printf 'generate\n' >>"$PROXY_SETTINGS_CALL_LOG"
    printf '%s\n' 'a1b2c3d4e5f60718293a4b5c'
    return "${PROXY_SETTINGS_RANDOM_RC:-0}"
}

# shellcheck disable=SC1090
source <(
    printf '_proxy_settings_block() {\n'
    sed -n '/^[[:space:]]*# Optional miner authentication/,/^[[:space:]]*MONERO_USER=\$(jq /p' \
        "$root/lib/pithead/28-parse-and-validate-config.sh" | sed '$d'
    printf '}\n'
)

STRATUM_PASSWORD=seed-password
STRATUM_TLS=seed-tls
DONATE_LEVEL=seed-donation
_proxy_settings_finish() {
    local rc=$?
    trap - EXIT
    printf '\0%s\0%s\0%s\0' "$STRATUM_PASSWORD" "$STRATUM_TLS" "$DONATE_LEVEL"
    exit "$rc"
}
trap _proxy_settings_finish EXIT
_proxy_settings_block
