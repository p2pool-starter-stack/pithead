#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
export PITHEAD_CONFIG_FILE=$2
TARI_MODE=$3
export PITHEAD_IMPL="${PAYOUT_SETTINGS_PARITY_IMPL:-bash}"
unset PITHEAD_GO_CONFIG_DOCUMENT_BINARY PITHEAD_GO_HELPER

# shellcheck source=/dev/null
source "$root/lib/pithead/00-prelude.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/27i-go-payout-settings.sh"
if [ "${PAYOUT_SETTINGS_WITHOUT_GO_HOOK:-0}" = 1 ]; then
    unset -f _parse_payout_monero_go _parse_payout_tari_go _validate_payout_birthday_go
fi

validate_payout_keys() {
    printf 'validate:%s:%s:%s:%s:%s:%s\n' "$MONERO_MODE" "${#MONERO_VIEW_KEY}" \
        "$PAYOUT_SCAN_HEIGHT" "${#TARI_VIEW_KEY}" "$TARI_WALLET_BIRTHDAY" \
        "$TARI_PAYOUT_CONFIRM_ENABLED" >>"$PAYOUT_SETTINGS_CALL_LOG"
    return "${PAYOUT_SETTINGS_VALIDATE_RC:-0}"
}

# shellcheck disable=SC1090
source <(
    printf '_payout_settings_block() {\n'
    sed -n '/^[[:space:]]*if ! command -v _parse_payout_monero_go /,/^[[:space:]]*validate_payout_keys$/p' \
        "$root/lib/pithead/28-parse-and-validate-config.sh"
    printf '}\n'
)

MONERO_MODE=seed-monero-mode
MONERO_VIEW_KEY=seed-monero-view-key
PAYOUT_SCAN_HEIGHT=seed-scan-height
PAYOUT_CONFIRM_ENABLED=seed-monero-enabled
TARI_VIEW_KEY=seed-tari-view-key
TARI_SPEND_PUBLIC_KEY=seed-tari-spend-key
TARI_WALLET_BIRTHDAY=seed-birthday
TARI_PAYOUT_CONFIRM_ENABLED=seed-tari-enabled

_payout_settings_finish() {
    local rc=$?
    trap - EXIT
    printf '\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
        "$MONERO_MODE" "$MONERO_VIEW_KEY" "$PAYOUT_SCAN_HEIGHT" \
        "$PAYOUT_CONFIRM_ENABLED" "$TARI_VIEW_KEY" "$TARI_SPEND_PUBLIC_KEY" \
        "$TARI_WALLET_BIRTHDAY" "$TARI_PAYOUT_CONFIRM_ENABLED"
    exit "$rc"
}
trap _payout_settings_finish EXIT
if [ "${PAYOUT_SETTINGS_ERR_TRAP:-0}" = 1 ]; then
    trap 'printf "err:%s\n" "$?" >>"$PAYOUT_SETTINGS_TRAP_LOG"' ERR
fi
export TARI_MODE
_payout_settings_block
