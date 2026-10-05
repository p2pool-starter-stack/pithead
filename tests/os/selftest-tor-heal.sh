#!/usr/bin/env bash
# Pure harness controls: no containers, guests or network service.
set -euo pipefail
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:?}}"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:?}/tor-heal-selftest.XXXXXX")
trap 'rm -rf "$work"' EXIT
# shellcheck disable=SC2034 # sourced phase reads both globals.
OS_RUN_SUITE=1 SCRIPT_DIR="$ROOT/tests/os"
# shellcheck source=tests/os/phases/tor-heal.sh
source "$ROOT/tests/os/phases/tor-heal.sh"
ok() { printf '%s\n' "$*" >>"$work/pass"; }
bad() { printf '%s\n' "$*" >>"$work/fail"; }
_phase_provision_initial() { return "${provision_rc:-0}"; }
_ssh() {
    [ "$SSH_TIMEOUT" = 13000 ] && [ "$1" = 'timeout 12500 bash -s' ]
    cat >"$work/guest-script"
    return "${guest_rc:-0}"
}
phase_tor_heal
cmp "$ROOT/tests/os/tor-heal-guest.sh" "$work/guest-script"
grep -q '#3118' "$work/pass"
rm "$work/guest-script"
provision_rc=1
if phase_tor_heal; then exit 1; fi
[ ! -e "$work/guest-script" ]
provision_rc=0 guest_rc=17
phase_tor_heal
[ "$(wc -l <"$work/fail")" = 2 ]
# A Docker command that accepts no stdin must not make the offline test pass.
docker() {
    case " $* " in
    *' -i '*)
        cat >/dev/null
        echo 'Tor offline recovery assertions complete'
        ;;
    *) return 0 ;;
    esac
}
export -f docker
bash "$ROOT/tests/stack/standalone/test_tor_saturated_image.sh" fixture >"$work/image-output"
sed 's/docker run -i /docker run /' "$ROOT/tests/stack/standalone/test_tor_saturated_image.sh" >"$work/broken-image-test.sh"
if bash "$work/broken-image-test.sh" fixture >"$work/broken-output"; then
    echo 'offline image test accepted missing Docker stdin' >&2
    exit 1
fi
echo 'tor-heal harness controls PASS'
