#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
export PITHEAD_CONFIG_FILE=$2
export PITHEAD_IMPL="${WALLET_SETTINGS_PARITY_IMPL:-bash}"
unset PITHEAD_GO_CONFIG_DOCUMENT_BINARY PITHEAD_GO_HELPER

# shellcheck source=/dev/null
source "$root/lib/pithead/00-prelude.sh"
is_appliance() { return 1; }
# shellcheck source=/dev/null
source "$root/lib/pithead/19a-config-defaults.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/27j-go-wallet-settings.sh"
if [ "${WALLET_SETTINGS_WITHOUT_GO_HOOK:-0}" = 1 ]; then unset -f _parse_wallet_settings_go; fi

eval "$(declare -f config_get | sed '1s/config_get/_wallet_settings_config_get/')"
config_get() {
    printf 'get:%s\n' "$1" >>"$WALLET_SETTINGS_CALL_LOG"
    _wallet_settings_config_get "$@"
}
monero_address_type() {
    printf 'monero:%s\n' "$1" >>"$WALLET_SETTINGS_CALL_LOG"
    printf '%s' "${WALLET_SETTINGS_MONERO_KIND:-primary}"
    return "${WALLET_SETTINGS_MONERO_RC:-0}"
}
tari_address_type() {
    printf 'tari:%s\n' "$1" >>"$WALLET_SETTINGS_CALL_LOG"
    printf '%s' "${WALLET_SETTINGS_TARI_KIND:-ok}"
    return "${WALLET_SETTINGS_TARI_RC:-0}"
}

# shellcheck disable=SC1090
source <(
    printf '_wallet_settings_block() {\n'
    sed -n '/^[[:space:]]*TARI_MODE=$(config_get \.tari\.mode)/,/^[[:space:]]*if ! command -v _parse_payout_monero_go /p' \
        "$root/lib/pithead/28-parse-and-validate-config.sh" | sed '$d'
    printf '}\n'
)

TARI_MODE=seed-mode
MONERO_WALLET=seed-monero-wallet
TARI_WALLET=seed-tari-wallet

_wallet_settings_finish() {
    local rc=$?
    trap - EXIT
    printf '\0%s\0%s\0%s\0' "$TARI_MODE" "$MONERO_WALLET" "$TARI_WALLET"
    exit "$rc"
}
trap _wallet_settings_finish EXIT
if [ "${WALLET_SETTINGS_ERR_TRAP:-0}" = 1 ]; then
    trap 'printf "err:%s\n" "$?" >>"$WALLET_SETTINGS_TRAP_LOG"' ERR
fi
_wallet_settings_block
