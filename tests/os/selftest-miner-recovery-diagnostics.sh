#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-${RUNNER_TEMP:-/tmp}}/miner-diagnostics.XXXXXX")
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
systemctl() {
    case "$*" in
    *LoadState*) echo not-found ;;
    *ActiveState*) echo inactive ;;
    is-enabled*) echo not-found ;;
    *) return 99 ;;
    esac
}
miner_watchdog_receipt >"$work/control-receipt"
grep -Fx 'pithead-t3375: watchdog_unit=pithead-miner-recovery.timer load=not-found active=inactive enabled=not-found' "$work/control-receipt" >/dev/null
grep -Fx 'pithead-t3375: watchdog_absence=verified' "$work/control-receipt" >/dev/null
systemctl() { echo unexpected; }
if miner_watchdog_receipt >"$work/control-unreadable"; then
    echo 'FAIL: unreadable watchdog state passed'
    exit 1
fi
miner_watchdog_receipt() { [ "$trial" != control-unreadable ]; }
miner_diagnostics() { :; }
miner_cleanup() {
    [ "$trial" != cleanup-failed ] || return 1
    rm -rf "$T3375"
}
podman() {
    case "$*" in
    *'{{.Id}}'*) echo fixture-proxy ;;
    *'{{.State.StartedAt}}'*)
        if [ "$trial" = proxy-not-restarted ]; then echo old; else echo new; fi
        ;;
    *) return 99 ;;
    esac
}
miner_counts() {
    case "$trial" in
    workers-unreadable) return 1 ;;
    share-timeout) echo '[1,0]' ;;
    passed | rig-disconnected) echo '[1,1]' ;;
    *) echo '[0,0]' ;;
    esac
}
miner_workers() { echo '[]'; }
sleep() { SECONDS=$((SECONDS + 10)); }
for trial in backup-not-applied control-unreadable strand-timeout proxy-identity-changed proxy-not-restarted reconnect-timeout share-timeout cleanup-failed passed rig-disconnected workers-unreadable; do
    mkdir -p "$T3375"
    touch "$T3375/strand" "$T3375/backup-applied"
    echo fixture-proxy >"$T3375/proxy-id"
    case "$trial" in
    backup-not-applied) rm "$T3375/backup-applied" ;;
    strand-timeout) rm "$T3375/strand" ;;
    proxy-identity-changed) echo other-proxy >"$T3375/proxy-id" ;;
    esac
    rig=
    [ "$trial" != rig-disconnected ] || rig=fixture-rig
    rc=0
    (BOUND_STRAND=0 BOUND_RECONNECT=1 BOUND_SHARE=1 miner_guest_dispatch verdict old "$rig") >"$work/$trial.log" 2>&1 || rc=$?
    if [ "$trial" = passed ]; then
        [ "$rc" = 0 ]
        grep -Fx 'pithead-t3375: accepted_share=observed' "$work/$trial.log" >/dev/null
    else
        [ "$rc" = 1 ]
    fi
    case "$trial" in
    reconnect-timeout | share-timeout)
        grep -Fx "pithead-t3375: failure_reason=$trial" "$work/$trial.log" >/dev/null
        grep -Fx "pithead-t3375: verdict=$trial cleanup=verified recovery_failure=yes" "$work/$trial.log" >/dev/null
        ;;
    *)
        if grep -Fq 'recovery_failure=yes' "$work/$trial.log"; then
            echo "FAIL: $trial qualified as a recovery failure"
            exit 1
        fi
        ;;
    esac
    if [ "$trial" = cleanup-failed ]; then
        grep -Fx 'pithead-t3375: verdict=reconnect-timeout cleanup=failed recovery_failure=no' "$work/$trial.log" >/dev/null
        rm -rf "$T3375"
    fi
done
miner_precondition() { return 1; }
rc=0
(miner_guest_dispatch precondition) >"$work/precondition.log" 2>&1 || rc=$?
[ "$rc" = 1 ]
grep -Fx 'pithead-t3375: failure_reason=precondition-failed' "$work/precondition.log" >/dev/null
if grep -Fq 'recovery_failure=yes' "$work/precondition.log"; then exit 1; fi
echo 'PASS: bounded diagnostics and distinct trial, recovery and cleanup receipts'
