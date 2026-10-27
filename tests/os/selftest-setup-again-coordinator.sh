#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch=$(mktemp -d)
trap 'rm -f "$scratch"/*; rmdir "$scratch"' EXIT
# shellcheck source=tests/os/setup-again-leg.sh
source "$HERE/setup-again-leg.sh"
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
info() { :; }
ok() { printf '%s\n' "$*" >>"$scratch/pass"; }
bad() { printf '%s\n' "$*" >>"$scratch/fail"; }
sleep() { [ "$1" = 5 ] || fail "unexpected sleep"; }
_setup_again_boot() { [ "$1" = 300 ] || fail "unexpected boot wait"; }
_setup_again_session() { jar="$scratch/cookies"; }
_ssh() {
    case "$*" in
    'grub-editenv /boot/efi/grub/grubenv list') printf 'B_OK=1 B_TRY=0\n' ;;
    'cat /proc/cmdline') printf 'pithead.setup=1 rauc.slot=B\n' ;;
    'cat /data/pithead/machine-role') printf '%s\n' "$marker" ;;
    'test -s /data/pithead/config.json' | 'test ! -e /data/pithead/rig.json') return 0 ;;
    *) fail "unexpected SSH: $*" ;;
    esac
}
curl() {
    local data="" endpoint="" ack=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --data)
            data=$2
            shift
            ;;
        -X)
            [ "$2" = POST ] || fail "unexpected method"
            ack=1
            shift
            ;;
        https://*) endpoint=$1 ;;
        esac
        shift
    done
    case "$endpoint" in
    "https://$ip/submit")
        [ "$data" = "monero_wallet=$HARNESS_WALLET&tari_wallet=$HARNESS_TARI&pool=mini&role=pithead" ] || fail "coordinator POST lacks the explicit role or expected wallet/pool fields"
        printf '%s\n' "$data" >"$scratch/form"
        printf '200'
        ;;
    "https://$ip/api/handoff")
        [ -s "$scratch/form" ] || fail "handoff before submission"
        printf '{"password":"fixture"}'
        ;;
    "https://$ip/handoff-ack")
        [ "$ack" = 1 ] || fail "ack was not POST"
        : >"$scratch/ack"
        ;;
    *) fail "unexpected URL: $endpoint" ;;
    esac
}
ip=coordinator.invalid HARNESS_WALLET=fixture-monero HARNESS_TARI=fixture-tari
for marker in pithead both; do
    : >"$scratch/pass"
    : >"$scratch/fail"
    rm -f "$scratch/form" "$scratch/ack"
    rig_setup_again_coordinator_leg fixture-token
    [ -s "$scratch/form" ] && [ -e "$scratch/ack" ] || fail "submission/ack missing"
    grep -Fxq "the coordinator's config.json was written" "$scratch/pass" || fail "config assertion missing"
    grep -Fxq 'rig.json (and the token in it) went with the rig role' "$scratch/pass" || fail "rig-data assertion missing"
    if [ "$marker" = pithead ]; then
        [ ! -s "$scratch/fail" ] || fail "coordinator transition failed"
        grep -Fxq 'the role marker was replaced: rig -> pithead' "$scratch/pass" || fail "marker assertion missing"
    else
        grep -Fxq "the role marker still says 'both' 90 s after the ack" "$scratch/fail" || fail "combined role was accepted"
        [ "$(wc -l <"$scratch/fail")" -eq 1 ] || fail "unexpected failures"
    fi
done
printf 'selftest-setup-again-coordinator: explicit POST and strict role assertions passed\n'
