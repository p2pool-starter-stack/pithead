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
printf '%s\n' 'PASS: every failure diagnosis carries the recovery journal and the restart-path verdict'
