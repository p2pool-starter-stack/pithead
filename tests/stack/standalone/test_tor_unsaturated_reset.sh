#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-${RUNNER_TEMP:-/tmp}}/pithead-tor-unsaturated.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=lib/pithead/02e-tor-recovery.sh
source "$ROOT/lib/pithead/02e-tor-recovery.sh"
# shellcheck source=lib/pithead/02f-tor-recovery-reasons.sh
source "$ROOT/lib/pithead/02f-tor-recovery-reasons.sh"
# shellcheck source=lib/pithead/22a-config-document.sh
source "$ROOT/lib/pithead/22a-config-document.sh"
# shellcheck source=lib/pithead/49-control-request-loop.sh
source "$ROOT/lib/pithead/49-control-request-loop.sh"
# shellcheck source=lib/pithead/48b-control-tor-recover.sh
source "$ROOT/lib/pithead/48b-control-tor-recover.sh"
bundle_redact_log() { cat; }
mkdir -p "$WORK/tor/p2pool" "$WORK/control/audit" "$WORK/control/results" "$WORK/bin"
printf 'identity\n' >"$WORK/tor/p2pool/hs_ed25519_secret_key"
unsaturated() { printf 'CircuitBuildAbandonedCount 3\nTotalBuildTimes 1000\n' >"$WORK/tor/state"; }
unsaturated
sudo() {
    [ "${1:-}" != -n ] || shift
    "$@"
}
sleep() { :; }
log() { printf '%s\n' "$*" >>"$WORK/log"; }
warn() { printf '%s\n' "$*"; }
require_deployed() { :; }
mutation_lock_acquire() { _PITHEAD_LOCK_OWNED=1; }
mutation_lock_release() { :; }
control_audit() { printf '%s\n' "$5" >>"$WORK/audit"; }
control_write_result() {
    printf '%s\n' "$3" >"$1/$2.json"
    cp "$1/$2.json" "$WORK/result"
}
tor_recovery_mount() { printf '%s\n' "$WORK/tor"; }
env_get() {
    case "$1" in
    CONTROL_DIR) printf '%s\n' "$WORK/control" ;;
    TOR_AUTO_HEAL) printf 'true\n' ;;
    NETWORK_PREFIX) printf '172.28.0\n' ;;
    esac
}
docker() {
    case "$*" in
    'compose stop tor') : >"$WORK/stopped" ;;
    'compose start tor') rm -f "$WORK/stopped" ;;
    'compose restart monerod') ;;
    *'.State.Running'*) if [ -e "$WORK/stopped" ]; then printf 'false\n'; else printf 'true\n'; fi ;;
    *'.State.Health.Status'*) printf 'healthy\n' ;;
    esac
}
tor_recovery_info() { printf '{"status":"OK","synchronized":true,"height":42,"outgoing_connections_count":3}\n'; }
tor_recovery_bootstrap_persistent() { return 1; }
cat >"$WORK/bin/curl" <<'SH'
#!/bin/sh
[ "${EGRESS:-down}" = up ] && exit 0
exit 1
SH
chmod +x "$WORK/bin/curl"
PATH="$WORK/bin:$PATH"
export EGRESS=down

echo "== no reason holds on a healthy control port =="
tor_recovery_circuit_status() { printf 'circuit-established=1 pending=2\n'; }
if tor_recover check; then exit 1; fi
tor_recovery_circuit_status() { printf 'circuit-established=1 pending=%s\n' "$((TOR_RECOVERY_PENDING_LIMIT - 1))"; }
if tor_recover check; then exit 1; fi
tor_recovery_circuit_status() { return 1; }
if tor_recover check; then exit 1; fi

echo "== a wedged control port is a reset reason while egress is down =="
tor_recovery_circuit_status() { printf 'circuit-established=0 pending=0\n'; }
tor_recover check
grep -q 'reset reason: circuits-pending' "$WORK/log"
tor_recovery_circuit_status() { printf 'circuit-established=1 pending=%s\n' "$TOR_RECOVERY_PENDING_LIMIT"; }
tor_recover check
EGRESS=up
if tor_recover check; then exit 1; fi
EGRESS=down

echo "== the control port must stay wedged across both samples =="
rm -f "$WORK/samples"
tor_recovery_circuit_status() {
    if [ -e "$WORK/samples" ]; then printf 'circuit-established=1 pending=0\n'; else
        : >"$WORK/samples"
        printf 'circuit-established=0 pending=0\n'
    fi
}
if tor_recover check; then exit 1; fi

echo "== a persistent bootstrap stall is a reset reason =="
tor_recovery_circuit_status() { return 1; }
tor_recovery_bootstrap_persistent() { return 0; }
tor_recover check
grep -q 'reset reason: bootstrap-stalled' "$WORK/log"
EGRESS=up
if tor_recover check; then exit 1; fi
EGRESS=down
tor_recovery_bootstrap_persistent() { return 1; }

echo "== apply on an unsaturated reason keeps backup, cooldown, identity and audit =="
tor_recovery_circuit_status() { printf 'circuit-established=0 pending=40\n'; }
tor_recovery_info() { printf '{"status":"OK","synchronized":true,"height":42,"outgoing_connections_count":%s}\n' "$([ -e "$WORK/stopped" ] && echo 0 || echo 3)"; }
before=$(sha256sum "$WORK/tor/p2pool/hs_ed25519_secret_key")
id=12345678-1234-4123-8123-123456789abc
jq -n --arg id "$id" '{id:$id,action:"tor-recover",actor:"tor-heal"}' >"$WORK/recover.json"
control_process_request "$WORK/recover.json" "$WORK/control"
[ "$(jq -r .status "$WORK/result")" = applied ]
[ "$before" = "$(sha256sum "$WORK/tor/p2pool/hs_ed25519_secret_key")" ]
[ ! -e "$WORK/tor/state" ]
ls "$WORK"/tor/state.backup.* >/dev/null
[ -s "$WORK/control/tor-recovery-at" ]
[ "$(tail -1 "$WORK/audit")" = applied ]
unsaturated
control_process_request "$WORK/recover.json" "$WORK/control"
[ "$(jq -r .status "$WORK/result")" = failed ]
jq -e '.error | contains("six-hour cooldown")' "$WORK/result" >/dev/null
[ -e "$WORK/tor/state" ]
echo 'tor unsaturated reset PASS'
