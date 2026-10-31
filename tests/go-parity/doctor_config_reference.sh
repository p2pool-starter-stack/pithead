#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
operation=$2
export PITHEAD_APPLIANCE=$3
export PITHEAD_CONFIG_FILE=$4
fixture_variant=$5
fixture_ssh=$6
fixture_monero=$7
fixture_tari=$8
export MONERO_ADDRESS_KEY_ONLY=$9
export TARI_ADDRESS_KEY_ONLY=${10}
export PITHEAD_IMPL=bash
export NO_COLOR=1

# shellcheck source=/dev/null
source "$root/pithead"
appliance_variant() { printf '%s' "$fixture_variant"; }
jq() {
    case "$2" in
    '.ssh.enabled // false') printf '%s' "$fixture_ssh" ;;
    '.monero.wallet_address // empty') printf '%s' "$fixture_monero" ;;
    '.tari.wallet_address // empty') printf '%s' "$fixture_tari" ;;
    *) return 64 ;;
    esac
}

case "$operation" in
monero)
    monero_address_type "$fixture_monero"
    exit
    ;;
tari)
    tari_address_type "$fixture_tari"
    exit
    ;;
esac

config_reference() {
    local body starts
    # shellcheck disable=SC2016
    starts=$(grep -Fxc '    if [ -f "$CONFIG_FILE" ]; then' "$root/lib/pithead/06-doctor.sh")
    [ "$starts" = 1 ]
    body=$(awk '$0 == "    if [ -f \"$CONFIG_FILE\" ]; then"{found=1} found{print} found && $0 == "    fi"{exit}' "$root/lib/pithead/06-doctor.sh")
    eval "$body"
}

rows=$(/usr/bin/mktemp)
trap '/bin/rm -f "$rows"' EXIT
export DR_JSON_FILE="$rows"
config_reference >&2
/bin/cat "$rows"
