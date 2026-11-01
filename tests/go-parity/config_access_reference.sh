#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
operation=$2
export PITHEAD_CONFIG_FILE=$3
export PITHEAD_IMPL="${CONFIG_ACCESS_PARITY_IMPL:-bash}"
unset PITHEAD_GO_CONFIG_DOCUMENT_BINARY PITHEAD_GO_HELPER
[ -n "${BASHPID:-}" ] || BASHPID=$$

# shellcheck source=/dev/null
source "$root/lib/pithead/00-prelude.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/23-setup-and-credentials.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/27k-go-config-access.sh"

eval "$(declare -f cred_needs_generating | sed '1s/^cred_needs_generating/_config_access_cred_needs_generating/')"

is_appliance() {
    printf 'is-appliance\n' >>"$CONFIG_ACCESS_CALL_LOG"
    [ "${CONFIG_ACCESS_APPLIANCE:-0}" = 1 ]
}

appliance_variant() {
    printf 'variant\n' >>"$CONFIG_ACCESS_CALL_LOG"
    printf '%s' "${CONFIG_ACCESS_VARIANT:-release}"
}

cred_needs_generating() {
    local placeholder=$2 label=user
    [ "$placeholder" = "$PLACEHOLDER_NODE_PASS" ] && label=pass
    printf 'needs:%s\n' "$label" >>"$CONFIG_ACCESS_CALL_LOG"
    _config_access_cred_needs_generating "$@"
}

default_node_username() {
    printf 'default-user\n' >>"$CONFIG_ACCESS_CALL_LOG"
    printf generated-user
    return "${CONFIG_ACCESS_DEFAULT_RC:-0}"
}

generate_node_password() {
    printf 'generate-pass\n' >>"$CONFIG_ACCESS_CALL_LOG"
    printf generated-pass
    return "${CONFIG_ACCESS_GENERATE_RC:-0}"
}

digest() {
    printf '%s' "$1" | openssl dgst -sha256 | sed 's/^.*= //'
}

persist_node_credentials() {
    printf 'persist:%s:%s:%s:%s\n' "${#1}" "$(digest "$1")" "${#2}" "$(digest "$2")" \
        >>"$CONFIG_ACCESS_CALL_LOG"
    return "${CONFIG_ACCESS_PERSIST_RC:-0}"
}

log() { printf 'log\n' >>"$CONFIG_ACCESS_CALL_LOG"; }

# shellcheck disable=SC1090
case "$operation" in
ssh)
    source <(
        printf '_config_access_block() {\n'
        sed -n '/^[[:space:]]*local _ssh_release=/p' \
            "$root/lib/pithead/28-parse-and-validate-config.sh"
        sed -n '/^[[:space:]]*if is_appliance /,/^[[:space:]]*TARI_MODE=/p' \
            "$root/lib/pithead/28-parse-and-validate-config.sh" | sed '$d'
        printf '}\n'
    )
    ;;
node)
    source <(
        printf '_config_access_block() {\n'
        sed -n '/^[[:space:]]*MONERO_USER=\$(jq -r/,/^[[:space:]]*local _data_root/p' \
            "$root/lib/pithead/28-parse-and-validate-config.sh" | sed '$d'
        printf '}\n'
    )
    ;;
node-hook) ;;
*) exit 64 ;;
esac

# shellcheck disable=SC2034
MONERO_MODE=${CONFIG_ACCESS_MONERO_MODE:-local}
MONERO_USER=seed-user
MONERO_PASS=seed-pass
_node_generate_user=''
_node_generate_pass=''

_config_access_finish() {
    local rc=$?
    trap - EXIT
    printf '\0%s\0%s\0' "$MONERO_USER" "$MONERO_PASS"
    exit "$rc"
}
trap _config_access_finish EXIT
if [ "${CONFIG_ACCESS_ERR_TRAP:-0}" = 1 ]; then
    trap 'printf "err:%s\n" "$?" >>"$CONFIG_ACCESS_TRAP_LOG"' ERR
fi
if [ "$operation" = node-hook ]; then
    _parse_config_access_node_go
else
    _config_access_block
fi
