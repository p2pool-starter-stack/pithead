#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
operation=$2
shift 2
export PITHEAD_IMPL=bash
export NO_COLOR=1
export REFERENCE_OS="${REFERENCE_OS-Linux}"
export PITHEAD_APPLIANCE="${PITHEAD_APPLIANCE:-0}"

# shellcheck source=/dev/null
source "$root/pithead"
env_get() {
    case "$1" in
    TOR_EGRESS_FIREWALL) printf '%s' "${EGRESS_ENABLED:-}" ;;
    NETWORK_PREFIX) printf '%s' "${EGRESS_PREFIX:-}" ;;
    NETWORK_SUBNET) printf '%s' "${EGRESS_SUBNET:-}" ;;
    esac
}
tor_egress_sync_ips() {
    printf '%s' "${EGRESS_ACTIVE:-}"
}

case "$operation" in
tokenise) tor_egress_tokenise "$1" ;;
valid-cidr) tor_egress_valid_cidr "$1" ;;
overlaps) tor_egress_cidr_overlaps "$1" "$2" ;;
contains) tor_egress_cidr_contains "$1" "$2" ;;
shadows) tor_egress_rule_shadows "$1" "$2" ;;
canonical) tor_egress_iptables_canonical "$1" ;;
sync-accept) tor_egress_sync_iptables_accept "$1" "$2" ;;
rules) tor_egress_rules "$@" ;;
readback) tor_egress_enforced ;;
report)
    tor_egress_enforced() { return "$EGRESS_RC"; }
    rows=$(/usr/bin/mktemp)
    trap '/bin/rm -f "$rows"' EXIT
    export DR_JSON_FILE="$rows"
    check_egress_firewall_installed >&2 || exit $?
    /bin/cat "$rows"
    ;;
findings)
    rows=$(/usr/bin/mktemp)
    trap '/bin/rm -f "$rows"' EXIT
    export DR_JSON_FILE="$rows"
    check_egress_firewall_installed >&2 || exit $?
    /bin/cat "$rows"
    ;;
*) exit 64 ;;
esac
