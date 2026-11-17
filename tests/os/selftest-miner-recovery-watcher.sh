#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-${RUNNER_TEMP:-/tmp}}/miner-watcher.XXXXXX")
trap 'rm -rf "$work"' EXIT
# shellcheck source=tests/os/appliance-miner-recovery-leg.sh
source "$ROOT/tests/os/appliance-miner-recovery-leg.sh"
T3375=$work/control
miner_stranded() { return 0; }
ss() { :; }
miner_workers() {
    case "$attempt" in
    0) echo '[]' ;;
    1) return 1 ;;
    *) echo '[["fixture-rig",0,1,0]]' ;;
    esac
}
timeout() {
    [ "$1 $2 $3 $4 $5 $6" = '15 podman exec dashboard python -c' ] || return 99
    [ "$attempt" -ge 3 ]
}
miner_delete_table() {
    [ "$attempt" -ge 3 ] || return 99
    rm "$T3375/table"
}
sleep() {
    attempt=$((attempt + 1))
    SECONDS=$((SECONDS + 300))
}
mkdir "$T3375"
touch "$T3375/armed" "$T3375/table"
attempt=0 SECONDS=0
miner_watch watch fixture-rig
[ "$(cat "$T3375/strand")" = recorded ] && [ ! -e "$T3375/table" ]
rm "$T3375/strand"
touch "$T3375/table"
miner_workers() { echo '[]'; }
attempt=0 SECONDS=0
miner_watch watch fixture-rig
[ ! -e "$T3375/strand" ] && [ -e "$T3375/table" ]
echo 'PASS: watcher retries absent/unreadable rig and zero aggregate; absent rig never records'
