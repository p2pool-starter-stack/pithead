#!/usr/bin/env bash
# shellcheck disable=SC2034
set -Eeuo pipefail

root=$1
work=$2
operation=$3

cd "$work"
export PITHEAD_IMPL="${PAYOUT_KEYS_PARITY_IMPL:-bash}"
unset PITHEAD_GO_HELPER

C_RED=''
C_RESET=''
DOCS_URL=https://docs.example
error() {
    echo -e "[ERROR] $1" >&2
    exit 1
}

# shellcheck source=/dev/null
source "$root/lib/pithead/25b-payout-keys.sh"
# shellcheck source=/dev/null
if [ "${PAYOUT_KEYS_WITHOUT_GO_HOOK:-0}" != 1 ]; then
    source "$root/lib/pithead/25c-go-payout-keys.sh"
fi

read_field() { IFS= read -r -d '' "$1"; }

case "$operation" in
derive)
    chain=''
    private=''
    read_field chain
    read_field private
    payout_public_view_key "$chain" "$private"
    ;;
validate)
    MONERO_VIEW_KEY=''
    MONERO_WALLET=''
    MONERO_ADDRESS_KEYS=''
    MONERO_ADDRESS_RC=0
    TARI_VIEW_KEY=''
    TARI_WALLET=''
    TARI_ADDRESS_KEYS=''
    TARI_ADDRESS_RC=0
    TARI_SPEND_PUBLIC_KEY=''
    read_field MONERO_VIEW_KEY
    read_field MONERO_WALLET
    read_field MONERO_ADDRESS_KEYS
    read_field MONERO_ADDRESS_RC
    read_field TARI_VIEW_KEY
    read_field TARI_WALLET
    read_field TARI_ADDRESS_KEYS
    read_field TARI_ADDRESS_RC
    read_field TARI_SPEND_PUBLIC_KEY
    monero_address_type() {
        printf '%s' "$MONERO_ADDRESS_KEYS"
        return "$MONERO_ADDRESS_RC"
    }
    tari_address_type() {
        printf '%s' "$TARI_ADDRESS_KEYS"
        return "$TARI_ADDRESS_RC"
    }
    _payout_keys_finish() {
        local rc=$?
        trap - EXIT
        printf '\0%s\0' "$TARI_SPEND_PUBLIC_KEY"
        exit "$rc"
    }
    trap _payout_keys_finish EXIT
    validate_payout_keys
    ;;
*) exit 64 ;;
esac
