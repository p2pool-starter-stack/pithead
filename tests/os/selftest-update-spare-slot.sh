#!/usr/bin/env bash
# Exercise the fresh-spare observation with changing live RAUC replies and bounded probes.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_RUN_SUITE=1
# shellcheck source=tests/os/phases/update-spare-slot.sh
. "$HERE/phases/update-spare-slot.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
ok() { printf 'pass: %s\n' "$*" >>"$scratch/rows"; }
bad() { printf 'fail: %s\n' "$*" >>"$scratch/rows"; }
_wait_setup_page() { [ "$1" = 120 ] && [ "$fixture" != no-page ]; }
sleep() { SECONDS=$((SECONDS + 60)); }
_ssh() {
    [ "${SSH_TIMEOUT:-}" = 20 ] || return 2
    [ "$*" = 'rauc status --output-format=json' ] || return 2
    local n
    n=$(cat "$scratch/probes")
    printf '%s\n' "$((n + 1))" >"$scratch/probes"
    case "$fixture" in
    unreadable) return 1 ;;
    committed) printf '{"booted":"B","slots":[{"rootfs.1":{"state":"booted","boot_status":"good"}}]}' ;;
    wrong-slot) printf '{"booted":"A","slots":[{"rootfs.1":{"state":"inactive","boot_status":"bad"}}]}' ;;
    delayed)
        [ "$n" -gt 0 ] || return 1
        printf '{"booted":"B","slots":[{"rootfs.1":{"state":"booted","boot_status":"bad"}}]}'
        ;;
    esac
}
for fixture in delayed committed wrong-slot unreadable no-page; do
    : >"$scratch/rows"
    printf '0\n' >"$scratch/probes"
    SECONDS=0
    _update_spare_slot_uncommitted
    if [ "$fixture" = delayed ]; then
        grep -qx 'pass: unprovisioned B with its setup page open remains uncommitted' "$scratch/rows"
        [ "$(cat "$scratch/probes")" = 2 ]
    else
        grep -q '^fail:' "$scratch/rows"
        ! grep -q '^pass:' "$scratch/rows"
    fi
    echo "PASS: $fixture"
done
