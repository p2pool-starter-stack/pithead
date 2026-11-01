#!/usr/bin/env bash
# shellcheck disable=SC2034
set -Eeuo pipefail

root=$1
work=$2

cd "$work"
export PITHEAD_IMPL="${PAYOUT_OWNERSHIP_PARITY_IMPL:-bash}"
unset PITHEAD_GO_HELPER

C_RED=''
C_RESET=''
DOCS_URL=https://docs.example
trace=$work/callbacks
: >"$trace"

error() {
    printf 'error\n' >>"$trace"
    printf '[ERROR] %s\n' "$1" >&2
    exit 1
}

# shellcheck source=/dev/null
source "$root/lib/pithead/25-address-types.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/25b-payout-keys.sh"
# shellcheck source=/dev/null
if [ "${PAYOUT_OWNERSHIP_WITHOUT_GO_HOOK:-0}" != 1 ]; then
    source "$root/lib/pithead/25c-go-payout-keys.sh"
fi

read_field() { IFS= read -r -d '' "$1"; }

mode=''
MONERO_VIEW_KEY=''
MONERO_WALLET=''
MONERO_ADDRESS_KEYS=''
MONERO_ADDRESS_RC=0
MONERO_DERIVED=''
MONERO_DERIVE_RC=0
TARI_VIEW_KEY=''
TARI_WALLET=''
TARI_ADDRESS_KEYS=''
TARI_ADDRESS_RC=0
TARI_DERIVED=''
TARI_DERIVE_RC=0
TARI_SPEND_PUBLIC_KEY=''
read_field mode
read_field MONERO_VIEW_KEY
read_field MONERO_WALLET
read_field MONERO_ADDRESS_KEYS
read_field MONERO_ADDRESS_RC
read_field MONERO_DERIVED
read_field MONERO_DERIVE_RC
read_field TARI_VIEW_KEY
read_field TARI_WALLET
read_field TARI_ADDRESS_KEYS
read_field TARI_ADDRESS_RC
read_field TARI_DERIVED
read_field TARI_DERIVE_RC
read_field TARI_SPEND_PUBLIC_KEY
read_field DOCS_URL

if [ "$mode" = stub ]; then
    monero_address_type() {
        printf 'monero-address\n' >>"$trace"
        printf '%s' "$MONERO_ADDRESS_KEYS"
        return "$MONERO_ADDRESS_RC"
    }
    tari_address_type() {
        printf 'tari-address\n' >>"$trace"
        printf '%s' "$TARI_ADDRESS_KEYS"
        return "$TARI_ADDRESS_RC"
    }
    payout_public_view_key() {
        printf '%s-derive\n' "$1" >>"$work/derivations"
        case "$1" in
        monero)
            printf '%s\n' "$MONERO_DERIVED"
            return "$MONERO_DERIVE_RC"
            ;;
        tari)
            printf '%s\n' "$TARI_DERIVED"
            return "$TARI_DERIVE_RC"
            ;;
        esac
        return 64
    }
else
    monero_definition=$(declare -f monero_address_type)
    tari_definition=$(declare -f tari_address_type)
    eval "${monero_definition/monero_address_type/original_monero_address_type}"
    eval "${tari_definition/tari_address_type/original_tari_address_type}"
    monero_address_type() {
        printf 'monero-address\n' >>"$trace"
        original_monero_address_type "$@"
    }
    tari_address_type() {
        printf 'tari-address\n' >>"$trace"
        original_tari_address_type "$@"
    }
fi

finish() {
    local rc=$? calls
    trap - EXIT
    calls=$(<"$trace")
    printf '\0%s\0%s\0' "$TARI_SPEND_PUBLIC_KEY" "$calls"
    exit "$rc"
}
trap finish EXIT
validate_payout_keys
