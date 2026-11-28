#!/usr/bin/env bash
set -euo pipefail
export TMPDIR="${TMPDIR:-/tmp}"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:?}/miner-recovery-leg.XXXXXX")
trap 'rm -rf "$work"' EXIT
# shellcheck source=tests/os/appliance-miner-recovery-leg.sh
source "$ROOT/tests/os/appliance-miner-recovery-leg.sh"
T3375="$work/strand"
mkdir "$T3375"
miner_counts() { return 1; }
timeout() {
    if [ "$1" = 10 ]; then
        shift
        "$@"
    else
        command timeout "$@"
    fi
}
systemctl() { return 0; }
journalctl() {
    case "$*" in
    *'--since @'*)
        [ -r "$work/recovery-journal" ] || return 1
        cat "$work/recovery-journal"
        ;;
    *'-u pithead-t3375-watcher.service') printf '%s\n' 'watcher noise' ;;
    *'-u pithead-miner-recovery.service') printf '%s\n' 'recovery fallback' ;;
    *'-u xmrig.service') printf '%s\n' 'xmrig noise' ;;
    esac
}
MINER_PHASE=verdict
echo 0 >"$T3375/backup-at"
printf '%s\n' 'pithead-miner-recovery: active local miner disconnected for 300 seconds; restarting xmrig' >"$work/recovery-journal"
out=$(miner_diagnostics)
grep -Fq 'local connections/accepted: unreadable' <<<"$out"
grep -Fq 'pithead-t3375: fastpath_restart=missing timer_restart=observed' <<<"$out"
grep -Fq 'disconnected for 300 seconds' <<<"$out"
printf '%s\n' 'pithead-miner-recovery: local miner proxy was recreated while the miner was disconnected; restarting xmrig' >"$work/recovery-journal"
out=$(miner_diagnostics)
grep -Fq 'pithead-t3375: fastpath_restart=observed timer_restart=absent' <<<"$out"
printf '%s\n' \
    'pithead-miner-recovery: local miner proxy was recreated while the miner was disconnected; restarting xmrig' \
    'pithead-miner-recovery: active local miner disconnected for 300 seconds; restarting xmrig' >"$work/recovery-journal"
out=$(miner_diagnostics)
grep -Fq 'pithead-t3375: fastpath_restart=observed timer_restart=observed' <<<"$out"
rm "$work/recovery-journal"
out=$(miner_diagnostics)
grep -Fq 'pithead-t3375: recovery_journal=unreadable' <<<"$out"
grep -Fq 'xmrig noise' <<<"$out"
! grep -Fq 'fastpath_restart=' <<<"$out"
rm "$T3375/backup-at"
out=$(miner_diagnostics)
grep -Fq 'recovery fallback' <<<"$out"
! grep -Fq 'fastpath_restart=' <<<"$out"
journalctl() {
    printf '%s\n' "$*" >"$work/journal-args"
    printf '%s\n' 'pithead-miner-recovery: local miner proxy was recreated while the miner was disconnected; restarting xmrig'
}
printf '%s\n' 'proxy was recreated' >"$work/recovery-bin"
echo 100 >"$T3375/backup-start-at"
echo 200 >"$T3375/backup-at"
PITHEAD_MINER_RECOVERY_BIN="$work/recovery-bin" miner_fastpath_receipt | grep -Fq 'fastpath_restart=observed'
grep -Fq -- '--since @100' "$work/journal-args"
rm "$T3375/backup-start-at"
PITHEAD_MINER_RECOVERY_BIN="$work/recovery-bin" miner_fastpath_receipt >/dev/null
grep -Fq -- '--since @200' "$work/journal-args"
sleep() { :; }
echo 0 >"$work/misses"
miner_counts() {
    local n
    n=$(cat "$work/misses")
    if [ "$n" -lt 2 ]; then
        echo $((n + 1)) >"$work/misses"
        return 1
    fi
    echo '[1,7]'
}
[ "$(miner_read_accepted 120)" = 7 ]
miner_counts() { return 1; }
! miner_read_accepted 0 >/dev/null
printf '%s\n' 'PASS: every failure diagnosis carries the recovery journal and the restart-path verdict; the fast-path receipt reads from before the backup request; the precondition retries an unreadable worker list'
