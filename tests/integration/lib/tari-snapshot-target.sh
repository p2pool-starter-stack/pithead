#!/usr/bin/env bash
set -euo pipefail
root=$1 action=$2
printf '%s\n' "$$" >"$root/worker.pid"
source "$root/live-state-support.sh"
rx() { bash -c "$1"; }
quote_arg() { printf '%q' "$1"; }
probe() { python3 "$root/tari-snapshot-state.py" "$1" "$root" "${@:2}"; }
journal() {
    (
        umask 077
        declare -p UPGRADE_STATE_SNAPSHOTS UPGRADE_STATE_VOLUMES UPGRADE_STATE_OLD_DIRS UPGRADE_SNAPSHOT_ROOT >"$root/journal.tmp"
    )
    sync "$root/journal.tmp"
    mv "$root/journal.tmp" "$root/journal.sh"
    sync "$root"
}
state_snapshot_checkpoint() { journal; }
stage() {
    printf '%s\n' "$1" >"$root/stage"
    sync "$root/stage" "$root"
}
stop_writers() {
    local service _destination source type
    while IFS=$'\t' read -r service _destination source type; do
        docker stop --time 120 "$service" >/dev/null
        [ "$(docker inspect -f '{{.State.Running}} {{.State.Restarting}}' "$service")" = 'false false' ]
    done <"$root/mounts.tsv"
    probe quiesced
}
case "$action" in
capture)
    probe init >"$root/mounts.tsv"
    UPGRADE_SNAPSHOT_ROOT="$root/snapshots"
    mkdir -m 700 "$UPGRADE_SNAPSHOT_ROOT"
    stage probing
    while IFS=$'\t' read -r service _destination source type; do
        size=$(sudo -n du -sb -- "$source" | cut -f1)
        free=$(df -B1 --output=avail "$source" | tail -n 1 | tr -d ' ')
        [ "$free" -ge "$((size * 2 + 1073741824))" ] || {
            stage untouched
            echo 'Tari snapshot refused: insufficient free space' >&2
            exit 1
        }
        if [ "$type" = bind ]; then
            testfile=$(mktemp "$source/.pithead-reflink.XXXXXX")
            printf 'reflink-required\n' >"$testfile"
            sudo -n cp --reflink=always -- "$testfile" "$root/reflink-probe" || {
                sudo -n rm -f -- "$testfile" "$root/reflink-probe"
                stage untouched
                exit 1
            }
            sudo -n rm -f -- "$testfile" "$root/reflink-probe"
        fi
    done <"$root/mounts.tsv"
    stage quiescing
    stop_writers
    stage capturing
    capture_state_snapshots "$(cat "$root/mounts.tsv")" || {
        echo "Tari snapshot refused: $UPGRADE_SNAPSHOT_REASON" >&2
        exit 1
    }
    journal
    stage captured
    probe metrics
    ;;
restore)
    current=$(cat "$root/stage" 2>/dev/null || echo untouched)
    case "$current" in
    captured | branch)
        probe wait 7180
        probe stop-observer
        stage stopping
        stop_writers
        source "$root/journal.sh"
        stage restoring
        restore_state_snapshots
        journal
        stage restored
        ;;
    untouched) ;;
    *)
        echo 'Tari snapshot restoration NOT PROVEN; recovery material retained' >&2
        exit 1
        ;;
    esac
    ;;
branch)
    [ "$(cat "$root/stage")" = captured ]
    probe wait 7180
    marker=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["marker"])' "$root/state.json")
    docker exec tari sh -c 'test ! -e "/var/tari/node/$1" && printf "branch marker\n" >"/var/tari/node/$1"' _ "$marker"
    probe restart
    stage branch
    ;;
verify)
    current=$(cat "$root/stage" 2>/dev/null || echo untouched)
    case "$current" in restored | untouched) ;; *) exit 1 ;; esac
    marker=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["marker"])' "$root/state.json")
    docker exec tari test ! -e "/var/tari/node/$marker"
    python3 - "$root" <<'PY'
import importlib.util, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('snapshot', root / 'tari-snapshot-state.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
state = json.loads((root / 'state.json').read_text())
if m.mounts() != state['mounts']:
    raise SystemExit('restored Tari mounts differ')
m.opened()
if any(row[0] == 'tari-wallet' for row in state['mounts']):
    m.command('docker', 'exec', '-e', 'PAYOUT_SCAN_GRACE_SEC=0', 'tari-wallet', '/wallet-config/wallet-healthcheck.sh')
m.atomic(root / 'proof.json', {**json.loads((root / 'identity.json').read_text()), 'mounts': state['mounts'], 'marker_absent': True, 'baseline_opened': True, 'container': m.inspect('tari')['Id']})
PY
    if [ "$current" = restored ]; then
        stage proven
    fi
    ;;
cleanup)
    [ "$(cat "$root/stage")" = proven ] || exit 0
    source "$root/journal.sh"
    UPGRADE_SNAPSHOT_STRICT=1 cleanup_state_snapshots
    stage verified
    ;;
*) exit 1 ;;
esac
