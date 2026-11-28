#!/usr/bin/env bash
set -euo pipefail
export TMPDIR="${TMPDIR:-/tmp}"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:?}/miner-recovery-rig.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/stack"
cat >"$work/bin/systemctl" <<'SH'
#!/bin/bash
case "$*" in
'is-active --quiet xmrig.service') exit 0 ;;
'--no-block try-restart xmrig.service') echo restart >>"$RECOVERY_CALLS" ;;
*) exit 99 ;;
esac
SH
cat >"$work/bin/curl" <<'SH'
#!/bin/bash
[ "${API_FAIL:-0}" = 0 ] || exit 7
case "$*" in *'-H Authorization: Bearer fixture-token'*'http://127.0.0.1:18080/2/summary') ;; *) exit 98 ;; esac
printf '%s\n' "$SUMMARY"
SH
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"
export PITHEAD_DIR="$work/stack" PITHEAD_MINER_RECOVERY_STATE="$work/state"
export PITHEAD_MINER_RECOVERY_UPTIME="$work/uptime" RECOVERY_CALLS="$work/calls"
export PITHEAD_MINER_RECOVERY_CONFIG="$work/xmrig.json"
printf '%s\n' rig >"$work/stack/machine-role"
printf '{"http":{"port":18080,"access-token":"fixture-token"}}\n' >"$work/xmrig.json"
healthy='{"connection":{"uptime":50},"hashrate":{"total":[1200.5,1100,1000]},"results":{"shares_total":4}}'
nopool='{"connection":{"uptime":0},"hashrate":{"total":[null,null,null]},"results":{"shares_total":4}}'
idle='{"connection":{"uptime":900},"hashrate":{"total":[0,0,0]},"results":{"shares_total":4}}'
tick() {
    printf '%s.00 0\n' "$1" >"$work/uptime"
    SUMMARY=$2 bash "$ROOT/os/overlay/pithead-miner-recovery" >"$work/output"
}
no_restart() { [ ! -s "$work/calls" ]; }
tick 100 "$nopool"
tick 219 "$nopool"
no_restart
tick 220 "$nopool"
[ "$(cat "$work/calls")" = restart ]
grep -Fq 'rig miner stalled for 120 seconds; restarting xmrig' "$work/output"
[ ! -e "$work/state" ]
rm "$work/calls"
tick 230 "$nopool"
tick 400 "$nopool"
no_restart
tick 520 "$nopool"
[ "$(cat "$work/calls")" = restart ]
rm "$work/calls"
tick 600 "$nopool"
tick 650 "$healthy"
[ ! -e "$work/state" ]
tick 700 "$nopool"
tick 800 "$nopool"
no_restart
tick 850 "$healthy"
tick 900 "$idle"
tick 1030 "$idle"
[ "$(cat "$work/calls")" = restart ]
rm "$work/calls"
tick 1100 "$healthy"
[ ! -e "$work/state" ]
export API_FAIL=1
tick 1200 "$nopool"
tick 1400 "$nopool"
no_restart
[ ! -e "$work/state" ]
unset API_FAIL
tick 1500 'not json'
tick 1700 'not json'
no_restart
printf '{"http":{"port":18080}}\n' >"$work/xmrig.json"
printf '{"access_token":"fixture-token"}\n' >"$work/stack/rig.json"
tick 2000 "$nopool"
tick 2120 "$nopool"
[ "$(cat "$work/calls")" = restart ]
echo 'PASS: rig watchdog restarts after a 120 s stall, honours the cooldown and tolerates an unreachable API'
