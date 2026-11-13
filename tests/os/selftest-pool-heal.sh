#!/usr/bin/env bash
set -euo pipefail
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:-/tmp}}"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:?}/pool-heal-selftest.XXXXXX")
trap 'rm -rf "$work"' EXIT
# shellcheck disable=SC2034
OS_RUN_SUITE=1 SCRIPT_DIR="$ROOT/tests/os"
# shellcheck source=tests/os/phases/pool-heal.sh
source "$ROOT/tests/os/phases/pool-heal.sh"
ok() { printf '%s\n' "$*" >>"$work/pass"; }
bad() { printf '%s\n' "$*" >>"$work/fail"; }
it_skip_leg() { printf '%s|%s|%s\n' "$1" "$2" "$3" >>"$work/skip"; }
_phase_provision_initial() { return "${provision_rc:-0}"; }
_ssh() {
    [ "$SSH_TIMEOUT" = 6000 ] && [ "$1" = 'timeout 5800 bash -s' ]
    cat >"$work/guest-script"
    return "${guest_rc:-0}"
}
phase_p2pool_heal
cmp "$ROOT/tests/os/pool-heal-guest.sh" "$work/guest-script"
grep -q '#4077' "$work/pass"
rm "$work/guest-script"
provision_rc=1
if phase_p2pool_heal; then exit 1; fi
[ ! -e "$work/guest-script" ]
provision_rc=0 guest_rc=77
phase_p2pool_heal
grep -q '|missing$' "$work/skip"
[ "$(wc -l <"$work/pass" | tr -d ' ')" = 1 ]
guest_rc=17
SSH_ERR="$work/ssh-err"
echo 'P2Pool heal guest failed at first-restart (line 1, exit 17)' >"$SSH_ERR"
phase_p2pool_heal >"$work/phase-output"
grep -q 'Guest stderr: P2Pool heal guest failed at first-restart' "$work/phase-output"
[ "$(wc -l <"$work/fail" | tr -d ' ')" = 2 ]
bash -n "$ROOT/tests/os/pool-heal-guest.sh"
echo 'selftest-pool-heal: PASS'
