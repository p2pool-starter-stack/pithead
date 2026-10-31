#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
operation=$2
export REFERENCE_OS=$3
export PITHEAD_APPLIANCE=$4
fixture_binds=("$5" "$6" "$7")
shift 7
export PITHEAD_IMPL=bash
export NO_COLOR=1

# shellcheck source=/dev/null
source "$root/pithead"
env_get() {
    case "$1" in
    MONERO_RPC_BIND) printf '%s' "${fixture_binds[0]}" ;;
    MONERO_ZMQ_BIND) printf '%s' "${fixture_binds[1]}" ;;
    TARI_GRPC_BIND) printf '%s' "${fixture_binds[2]}" ;;
    esac
}

case "$operation" in
published)
    lan_guard_published
    exit
    ;;
container)
    lan_guard_container "$1"
    exit
    ;;
reason)
    lan_guard_reason "$1"
    exit
    ;;
boot)
    tor_egress_boot_unit_applies
    exit
    ;;
readback)
    lan_guard_enforced "$@"
    exit
    ;;
esac

rows=$(/usr/bin/mktemp)
trap '/bin/rm -f "$rows"' EXIT
export DR_JSON_FILE="$rows"
case "$operation" in
hold) check_lan_guard_hold "$@" >&2 || exit $? ;;
findings) check_lan_guard >&2 || exit $? ;;
*) exit 64 ;;
esac
/bin/cat "$rows"
