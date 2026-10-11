#!/usr/bin/env bash
# Failed real verdicts retain bounded evidence before the injection is cleaned up.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-${RUNNER_TEMP:?}}/miner-diagnostics.XXXXXX")
trap 'rm -rf "$work"' EXIT
# shellcheck source=tests/os/appliance-miner-recovery-leg.sh
source "$ROOT/tests/os/appliance-miner-recovery-leg.sh"
T3375=$work/control
BOUND_RECONNECT=0
miner_counts() { printf '%s\n' '[0,0]'; }
timeout() {
    [ "$1" = 10 ] || return 99
    shift
    "$@"
}
systemctl() { printf '%s\n' 'ActiveState=failed' 'Result=exit-code' 'ExecMainStatus=1'; }
journalctl() {
    [ -e "$T3375/armed" ] || return 99
    case "$*" in
    '--no-pager -n 40 --since -20 minutes -u pithead-t3375-watcher.service') printf '%s\n' 'fixture watcher failure' ;;
    '--no-pager -n 40 --since -20 minutes -u pithead-miner-recovery.service -u xmrig.service') printf '%s\n' 'fixture miner journal' ;;
    *) return 99 ;;
    esac
    return "${JOURNAL_RC:-0}"
}
miner_cleanup() { rm -rf "$T3375"; }
for journal_rc in 0 1; do
    mkdir "$T3375"
    touch "$T3375/armed"
    rc=0
    (JOURNAL_RC=$journal_rc miner_guest_dispatch verdict old) >"$work/log" 2>&1 || rc=$?
    [ "$rc" = 1 ] && [ ! -e "$T3375" ]
    grep -Fx 'pithead-t3375: failure phase=verdict strand_recorded=no' "$work/log" >/dev/null
    grep -Fx 'pithead-t3375: local connections/accepted: [0,0]' "$work/log" >/dev/null
    grep -Fx 'Result=exit-code' "$work/log" >/dev/null
    grep -Fx 'fixture watcher failure' "$work/log" >/dev/null
    grep -Fx 'fixture miner journal' "$work/log" >/dev/null
done
echo 'PASS: failed verdict preserves bounded diagnostics before cleanup, including journal failure'
