#!/usr/bin/env bash
set -euo pipefail
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:-/tmp}}"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:?}/monerod-redial-selftest.XXXXXX")
trap 'rm -rf "$work"' EXIT
# shellcheck disable=SC2034
OS_RUN_SUITE=1 SCRIPT_DIR="$ROOT/tests/os"
# shellcheck source=tests/os/phases/monerod-redial.sh
source "$ROOT/tests/os/phases/monerod-redial.sh"
ok() { printf '%s\n' "$*" >>"$work/pass"; }
bad() { printf '%s\n' "$*" >>"$work/fail"; }
it_skip_leg() { printf '%s|%s|%s\n' "$1" "$2" "$3" >>"$work/skip"; }
_phase_provision_initial() { return "${provision_rc:-0}"; }
_ssh() {
    [ "$SSH_TIMEOUT" = 28500 ] || return 1
    [ "$1" = 'timeout 28000 bash -s' ] || return 1
    cat >"$work/guest-script"
    return "${guest_rc:-0}"
}
phase_monerod_redial
cmp "$ROOT/tests/os/monerod-redial-guest.sh" "$work/guest-script"
grep -q '#4157' "$work/pass"
rm "$work/guest-script"
provision_rc=1
if phase_monerod_redial; then exit 1; fi
[ ! -e "$work/guest-script" ]
provision_rc=0 guest_rc=77
phase_monerod_redial
grep -q '|missing$' "$work/skip"
[ "$(wc -l <"$work/pass" | tr -d ' ')" = 1 ]
guest_rc=78
phase_monerod_redial
[ "$(wc -l <"$work/pass" | tr -d ' ')" = 2 ]
[ "$(wc -l <"$work/skip" | tr -d ' ')" = 2 ]
guest_rc=17
SSH_ERR="$work/ssh-err"
echo 'monerod redial guest failed at cooldown-hold (line 1, exit 17)' >"$SSH_ERR"
phase_monerod_redial >"$work/phase-output"
grep -q 'Guest stderr: monerod redial guest failed at cooldown-hold' "$work/phase-output"
[ "$(wc -l <"$work/fail" | tr -d ' ')" = 2 ]
bash -n "$ROOT/tests/os/monerod-redial-guest.sh"

guest="$ROOT/tests/os/monerod-redial-guest.sh"
(
    eval "$(sed -n '/^must_not() {/,/^}/p' "$guest")"
    must_not false
    if must_not true; then exit 1; fi
)
(
    eval "$(sed -n '/^peers_out() {/,/^}/p' "$guest")"
    docker() {
        printf '%s\n' '[{"Output":"noise\npithead-monero-peers {\"outgoing\":7,\"incoming\":2}\n"}]'
    }
    [ "$(peers_out)" = 7 ]
    docker() { printf '%s\n' '[{"Output":"no marker"}]'; }
    [ -z "$(peers_out)" ]
    docker() { printf '%s\n' '[]'; }
    [ -z "$(peers_out)" ]
)
grep -Fq 'Restarting monerod to re-dial its peers through Tor' "$ROOT/dashboard/mining_dashboard/service/health/monerod_redial.py"
grep -Fq 'monerod restarts are held: all %d automatic restarts' "$ROOT/dashboard/mining_dashboard/service/health/monerod_redial.py"
grep -Fq 'monerod restarts are held: all 3 automatic restarts' "$guest"
grep -Fq 'DAILY_CAP = 3' "$ROOT/dashboard/mining_dashboard/service/health/monerod_redial.py"
grep -Fq '"health", "monerod-redial", "restart", status' "$ROOT/dashboard/mining_dashboard/service/data_setup.py"
echo 'selftest-monerod-redial: PASS'
