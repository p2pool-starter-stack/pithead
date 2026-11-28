#!/usr/bin/env bash
set -euo pipefail
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:-/tmp}}"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:?}/tor-heal-dropcells-selftest.XXXXXX")
trap 'rm -rf "$work"' EXIT
# shellcheck disable=SC2034 # sourced phase reads both globals.
OS_RUN_SUITE=1 SCRIPT_DIR="$ROOT/tests/os"
# shellcheck source=tests/os/phases/tor-heal-dropcells.sh
source "$ROOT/tests/os/phases/tor-heal-dropcells.sh"
ok() { printf '%s\n' "$*" >>"$work/pass"; }
bad() { printf '%s\n' "$*" >>"$work/fail"; }
_phase_provision_initial() { return "${provision_rc:-0}"; }
_ssh() {
    [ "$SSH_TIMEOUT" = 12500 ] && [ "$1" = 'timeout 12000 bash -s' ]
    cat >"$work/guest-script"
    return "${guest_rc:-0}"
}
phase_tor_heal_dropcells
cmp "$ROOT/tests/os/tor-heal-dropcells-guest.sh" "$work/guest-script"
grep -q '#4280' "$work/pass"
rm "$work/guest-script"
provision_rc=1
if phase_tor_heal_dropcells; then exit 1; fi
[ ! -e "$work/guest-script" ]
provision_rc=0 guest_rc=17
SSH_ERR="$work/ssh-err"
echo 'Tor heal guest failed at fixture-stage (line 1, exit 17)' >"$SSH_ERR"
phase_tor_heal_dropcells >"$work/phase-output"
grep -q 'Guest stderr: Tor heal guest failed at fixture-stage' "$work/phase-output"
[ "$(wc -l <"$work/fail" | tr -d " ")" = 2 ]
echo "tor-heal-dropcells harness controls PASS"
