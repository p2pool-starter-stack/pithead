#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/os/headless-install-leg.sh
source "$HERE/headless-install-leg.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
jar="$work/jar" SERIAL="$work/serial" ip=fixture
DISK="$work/disk.img" loop_fixture="$work/loop"
mkdir "$work/esp"
touch "${loop_fixture}p1"
losetup() {
    printf '%s\n' "$*" >"$work/last-loop-call"
    [[ "$*" != *--show* ]] || printf '%s' "$loop_fixture"
}
mount() {
    touch "$work/mount-called"
    [ "$mode" != mount-error ] && cp -R "$work/esp/." "${!#}/"
}
umount() {
    rm -f "$work/esp/pithead-token.txt" "$work/esp/pithead-config.json"
    cp -R "$1/." "$work/esp/"
    rm -f "$1/pithead-token.txt" "$1/pithead-config.json"
}
mode=ready
headless_install_stage '{"fixture":true}'
test "$(cat "$work/esp/pithead-token.txt")" = PiT-K7m2Qx
jq -e '.fixture == true' "$work/esp/pithead-config.json" >/dev/null
headless_install_stage
test ! -e "$work/esp/pithead-token.txt"
test ! -e "$work/esp/pithead-config.json"
rm -f "${loop_fixture}p1" "$work/mount-called"
sleep() { :; }
! headless_install_stage '{}' || exit 1
test ! -e "$work/mount-called"
test "$(cat "$work/last-loop-call")" = "-d $loop_fixture"
touch "${loop_fixture}p1"
mode=mount-error
! headless_install_stage '{}' || exit 1
mode=ready
ok() { :; }
bad() { printf 'expected refusal: %s\n' "$*"; }
prefill='{"mode":"installer","stage":"installer","new_machine":false,"install_attempt":{},"config":{"monero":{"wallet_address":"staged"},"tari":{"wallet_address":"staged"}}}'
staged='{"monero":{"wallet_address":"staged"},"tari":{"wallet_address":"staged"}}'
headless_install_prefill_valid "$prefill" "$staged"
for change in '.new_machine=true' '.install_attempt={disk:"vda",wipe:"all"}' '.config.monero.wallet_address="wrong"' '.stage="setup"'; do
    ! headless_install_prefill_valid "$(jq "$change" <<<"$prefill")" "$staged" || exit 1
done
blank=$(jq --slurpfile reference "$HERE/../../config.reference.json" \
    '.new_machine=true | .reference=$reference[0] |
     .config.monero.wallet_address=.reference.monero.wallet_address |
     .config.tari.wallet_address=.reference.tari.wallet_address' <<<"$prefill")
headless_install_blank_valid "$blank"
! headless_install_blank_valid "$prefill" || exit 1
! headless_install_blank_valid "$(jq '.install_attempt={disk:"vda",wipe:"keep"}' <<<"$blank")" || exit 1
! headless_install_blank_valid "$(jq '.config.monero.wallet_address="stale"' <<<"$blank")" || exit 1
! headless_install_blank_valid "$(jq '.config.tari.wallet_address="stale"' <<<"$blank")" || exit 1
! headless_install_blank_valid "$(jq 'del(.reference)' <<<"$blank")" || exit 1
! headless_install_blank_valid '{}' || exit 1

curl() {
    local arg variant=""
    for arg in "$@"; do [[ "$arg" != token=* ]] || variant="${arg#token=}"; done
    if [ -n "$variant" ]; then
        printf '%s\n' "$variant" >>"$work/variants"
        [ "$mode" != http-error ] || return 1
        [ "$mode" = no-session ] || printf wizard_session >"$jar"
    else
        printf '%s' "$state"
    fi
}
mode=ready
headless_install_auth
test "$(wc -l <"$work/variants" | tr -d ' ')" = 5
for mode in http-error no-session; do
    ! headless_install_auth || exit 1
done
mode=ready state="$blank" boot=ready console=ready
_ssh() { return 0; }
_reboot_wait() { [ "$boot" = ready ]; }
_wait_setup_page() { [ "$mode" = ready ]; }
wait_serial() { [ "$console" = ready ]; }
headless_install_rejection
state="$prefill"
! headless_install_rejection || exit 1
state="$blank" console=missing
! headless_install_rejection || exit 1
console=ready boot=failed
! headless_install_rejection || exit 1
printf 'PASS: headless installer prefill, blank-form, token-session and rejection controls\n'
