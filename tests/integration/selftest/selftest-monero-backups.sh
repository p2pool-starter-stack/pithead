#!/usr/bin/env bash
set -euo pipefail
echo "== unit: Monero backup failover evidence and restoration =="
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/run-monero-backups.sh
source "$HERE/../lib/run-monero-backups.sh"
set -euo pipefail

backup_zmq=28083 backup_height=10 backup_proxy_started=original
height=11 badge=healthy proxy_started=original connected=true primary_state=exited
tcp_endpoint=0200007F:6DB3 tcp_state=01
rx() {
    case "$*" in
    *'/proc/net/tcp'*) if [ "$connected" = true ]; then printf '0: 0100007F:1234 %s %s\n' "$tcp_endpoint" "$tcp_state"; fi ;;
    *'docker inspect'*) printf '%s' "$proxy_started" ;;
    *) return 1 ;;
    esac
}
api_state() { printf '{"network":{"height":%s},"badges":[{"text":"%s"}]}' "$height" "$badge"; }
service_state() { if [ "$1" = monerod ]; then echo "$primary_state"; else echo running; fi; }
svc_state_of() { echo "$1"; }
_backup_node_serving
primary_state=running
if _backup_node_serving; then
    echo 'FAIL: running primary accepted as a failover witness'
    exit 1
fi
primary_state=exited tcp_endpoint=0100007F:6DB3
if _backup_node_serving; then
    echo 'FAIL: primary socket accepted as backup'
    exit 1
fi
tcp_endpoint=0200007F:6DB3 tcp_state=02
if _backup_node_serving; then
    echo 'FAIL: unestablished backup socket accepted'
    exit 1
fi
tcp_state=01
height=10
if _backup_node_serving; then
    echo 'FAIL: stale data accepted'
    exit 1
fi
height=11 badge='Workers rejected'
if _backup_node_serving; then
    echo 'FAIL: rejected workers accepted'
    exit 1
fi
badge=healthy proxy_started=restarted
if _backup_node_serving; then
    echo 'FAIL: restarted listener accepted'
    exit 1
fi
proxy_started=original connected=false
if _backup_node_serving; then
    echo 'FAIL: absent backup connection accepted'
    exit 1
fi

REMOTE_MONERO_HOST=provider.example REMOTE_MONERO_RPC_PORT=28081 REMOTE_MONERO_ZMQ_PORT=28083
IT_FAIL=0 OUT_DIR=unused
fixture_original='{"monero":{"node_username":"fixture-user","node_password":"fixture-pass"}}'
restored=false stopped=false
rx() {
    case "$*" in
    'cat config.json') printf '%s' "$fixture_original" ;;
    'docker compose stop monerod') stopped=true ;;
    'docker compose start monerod') : ;;
    *'docker logs'*) : ;;
    *'docker inspect'*) echo original ;;
    *date*) echo 100 ;;
    *) return 1 ;;
    esac
}
push_config() {
    if [ "$1" = "$fixture_original" ]; then restored=true; else
        printf '%s' "$1" | jq -e '.network.tor_egress_firewall and (.p2pool.clearnet == false)
            and .monero.backup_nodes == [{host:"provider.example",rpc_port:28081,zmq_port:28083,rpc_login:"fixture-user:fixture-pass"}]' >/dev/null
    fi
}
pithead() { :; }
wait_for() { [ "$1" != 600 ]; }
wait_status_ok() { :; }
env_on_box() { case "$1" in TOR_EGRESS_FIREWALL) echo true ;; *) echo false ;; esac }
it_pass() { :; }
it_fail() { IT_FAIL=$((IT_FAIL + 1)); }
assert_eq() { [ "$2" = "$3" ] || IT_FAIL=$((IT_FAIL + 1)); }
capture_artifacts() { :; }
fault_monero_backups
[ "$stopped" = true ] && [ "$restored" = true ] && [ "$IT_FAIL" -eq 1 ]
echo 'Monero backup evidence refuses missing witnesses and restores after a failed fault.'
