#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

if [ "${1:-}" = fixture ]; then
    source "$ROOT/lib/pithead/32-onion-provisioning.sh"
    source "$ROOT/lib/pithead/32a-tor-lifecycle-receipts.sh"
    source "$ROOT/lib/pithead/02b1-lan-guard-compose.sh"
    TOR_DATA_DIR="$2/tor"
    DASHBOARD_ONION_ENABLED=true DASHBOARD_ONION_CLIENT_AUTH=false
    MONERO_MODE=remote TARI_MODE=remote
    stop_rc="$3" up_rc="$4"
    require_env() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    log() { :; }
    warn() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    generate_caddyfile() { :; }
    provision_onion_client_auth() { :; }
    provision_dashboard_onion() { :; }
    resolve_pull_policy() { echo never; }
    wait_for_onion() { echo private.onion; }
    env_get() { echo true; }
    sudo() { :; }
    timeout() {
        shift
        "$@"
    }
    docker() {
        if [ "$1" = inspect ]; then
            printf '%064d\n' 1
        elif [ "$*" = 'compose stop tor' ]; then
            printf '%s\n' private-engine-error >&2
            return "$stop_rc"
        elif [ "$1 $2 $3" = 'compose up --pull' ]; then
            return "$up_rc"
        fi
    }
    lan_guard_scoped_up() { return 1; }
    finish_lan_guard_after_up() { return 0; }
    lan_guard_restore_stopped() { :; }
    mutation_lock_path() { echo ignored; }
    compose_up() { lan_guard_compose_up "$@"; }
    if [ "${5:-}" = broken ]; then tor_lifecycle_receipt() { return 19; }; fi
    rotate_dashboard_onion -y
    exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for stop_rc in 0 9; do
    for up_rc in 0 7; do
        rc=0
        bash "$0" fixture "$work" "$stop_rc" "$up_rc" >"$work/stdout" 2>"$work/receipts" || rc=$?
        [ "$rc" = "$up_rc" ] || {
            echo "FAIL: rotation status changed"
            exit 1
        }
        python3 - "$work/receipts" "$stop_rc" "$up_rc" <<'PY'
import json
import sys
from datetime import datetime

rows = [json.loads(line.removeprefix('pithead-tor-lifecycle ')) for line in open(sys.argv[1])]
assert [(r['action'], r['result']) for r in rows] == [
    ('stop', 'requested'), ('stop', sys.argv[2]), ('up', 'requested'), ('up', sys.argv[3])]
assert len({r['operation'] for r in rows}) == 1
assert all(r['container'] == '0' * 63 + '1' for r in rows)
assert all(r['caller'] == 'onion-rotation' for r in rows)
assert all(datetime.fromisoformat(r['timestamp'].replace('Z', '+00:00')) for r in rows)
assert 'private' not in open(sys.argv[1]).read()
PY
        rc=0
        bash "$0" fixture "$work" "$stop_rc" "$up_rc" broken >/dev/null 2>&1 || rc=$?
        [ "$rc" = "$up_rc" ] || {
            echo "FAIL: receipt failure changed rotation"
            exit 1
        }
    done
done
echo 'Tor rotation receipts: success, failure and broken-recorder controls PASS'
