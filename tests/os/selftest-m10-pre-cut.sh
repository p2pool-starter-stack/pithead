#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
td="$(mktemp -d)"
trap 'rm -rf "$td"' EXIT
# shellcheck disable=SC2034
OS_RUN_SUITE=1 VM=selftest
# shellcheck source=tests/os/phases/provision-power-cut.sh
source "$HERE/phases/provision-power-cut.sh"
info() { :; }
bad() { printf '%s\n' "$1" >>"$td/verdict"; }
_monerod_height() {
    echo poll >>"$td/actions"
    printf '%s' "$height"
}
sleep() { :; }
_ssh() {
    if [ "$1" = sync ]; then
        echo sync >>"$td/actions"
        return 1
    fi
    printf 'baseline\n'
}
_boot_id() { echo boot >>"$td/actions"; }
virsh() { echo power >>"$td/actions"; }
for height in '' invalid 0 42; do
    : >"$td/actions"
    : >"$td/verdict"
    rc=0
    _phase_provision_power_cut || rc=$?
    [ "$rc" -eq 1 ] || exit 1
    if [ -z "$height" ]; then
        [ "$(grep -c '^poll$' "$td/actions")" -eq 18 ] || exit 1
        ! grep -Eq '^(sync|boot|power)$' "$td/actions" || exit 1
        grep -Fxq 'M10.1: empty pre-cut monerod height read' "$td/verdict" || exit 1
    elif [ "$height" = invalid ]; then
        [ "$(cat "$td/actions")" = poll ] || exit 1
        grep -Fxq 'M10.1: invalid pre-cut monerod height read' "$td/verdict" || exit 1
    else
        [ "$(cat "$td/actions")" = $'poll\nsync' ] || exit 1
        grep -Fxq 'M10.1: could not flush the guest before the power cut' "$td/verdict" || exit 1
    fi
done
echo 'm10-pre-cut: PASS'
