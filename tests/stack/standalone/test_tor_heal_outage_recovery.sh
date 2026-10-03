#!/usr/bin/env bash
# Recovery evidence from the dashboard heal's own NEWNYM record, and the read-only
# tor-history verb (#3052). No engine or bench access.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:?}/pithead-tor-heal-outage.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=lib/pithead/02e-tor-recovery.sh
source "$ROOT/lib/pithead/02e-tor-recovery.sh"
# shellcheck source=lib/pithead/49-control-request-loop.sh
source "$ROOT/lib/pithead/49-control-request-loop.sh"
echo "== tor-recover accepts a sustained heal outage on a synchronized Monero =="
mkdir -p "$WORK/tor/p2pool" "$WORK/control/audit" "$WORK/bin"
printf 'identity\n' >"$WORK/tor/p2pool/hs_ed25519_secret_key"
printf 'CircuitBuildAbandonedCount 1000\nTotalBuildTimes 1000\n' >"$WORK/tor/state"
sudo() { [ "${1:-}" != -n ] || shift; "$@"; }
sleep() { :; }
log() { :; }
warn() { :; }
require_deployed() { :; }
mutation_lock_acquire() { _PITHEAD_LOCK_OWNED=1; }
mutation_lock_release() { :; }
control_audit() { printf '%s\n' "$5" >>"$WORK/audit"; }
control_write_result() { printf '%s\n' "$3" >"$WORK/result"; }
tor_recovery_mount() { printf '%s\n' "$WORK/tor"; }
env_get() {
    case "$1" in
    CONTROL_DIR) printf '%s\n' "$WORK/control" ;;
    TOR_AUTO_HEAL) printf 'true\n' ;;
    NETWORK_PREFIX) printf '172.28.0\n' ;;
    esac
}
docker() { case "$*" in *'.State.Running'*) printf 'true\n' ;; esac; }
# monerod stays synchronized and peerless: the stalled-Monero class must NOT qualify.
tor_recovery_info() { printf '{"status":"OK","synchronized":true,"height":42,"outgoing_connections_count":0}\n'; }
tor_recovery_bootstrap_stalled() { return 1; }
# Fake curl: egress is down unless EGRESS=up.
cat >"$WORK/bin/curl" <<'SH'
#!/bin/sh
[ "${EGRESS:-down}" = up ]
SH
chmod +x "$WORK/bin/curl"
PATH="$WORK/bin:$PATH"

# No heal record: refused, exactly as before.
if tor_recover check; then exit 1; fi
now=$(date +%s)
# One accepted round is not two heal rounds.
printf '%s 1\n' "$((now - 3600))" >"$WORK/control/tor-newnym-budget"
if tor_recover check; then exit 1; fi
# Two rounds but a hand-edited record younger than the minimum outage age (the host cannot write one).
printf '%s 2\n' "$((now - 60))" >"$WORK/control/tor-newnym-budget"
if tor_recover check; then exit 1; fi
# A stale record outside the 24h window.
printf '%s 2\n' "$((now - 90000))" >"$WORK/control/tor-newnym-budget"
if tor_recover check; then exit 1; fi
# Two rounds over a sustained outage, egress down, saturated: qualifies (read-only).
printf '%s 2\n' "$((now - 3600))" >"$WORK/control/tor-newnym-budget"
tor_recover check
[ ! -e "$WORK/control/tor-recovery-at" ] && [ -e "$WORK/tor/state" ]
# A healthy Tor (egress answers) stays refused.
export EGRESS=up
if tor_recover check; then exit 1; fi
export EGRESS=down
# An unsaturated history stays refused.
printf 'CircuitBuildAbandonedCount 3\nTotalBuildTimes 1000\n' >"$WORK/tor/state"
if tor_recover check; then exit 1; fi
printf 'CircuitBuildAbandonedCount 1000\nTotalBuildTimes 1000\n' >"$WORK/tor/state"
# A symlinked record is not evidence.
mv "$WORK/control/tor-newnym-budget" "$WORK/budget-real"
ln -s "$WORK/budget-real" "$WORK/control/tor-newnym-budget"
if tor_recover check; then exit 1; fi
rm "$WORK/control/tor-newnym-budget"
mv "$WORK/budget-real" "$WORK/control/tor-newnym-budget"

echo "== apply on the heal-outage class keeps cooldown, identity and audit =="
docker() {
    case "$*" in
    'compose stop tor') : >"$WORK/stopped" ;;
    'compose start tor') rm -f "$WORK/stopped" ;;
    'compose restart monerod') ;;
    *'.State.Running'*) if [ -e "$WORK/stopped" ]; then printf 'false\n'; else printf 'true\n'; fi ;;
    *'.State.Health.Status'*) printf 'healthy\n' ;;
    esac
}
tor_recovery_info() { printf '{"status":"OK","synchronized":true,"height":42,"outgoing_connections_count":%s}\n' "$([ -e "$WORK/stopped" ] && echo 0 || echo 3)"; }
before=$(sha256sum "$WORK/tor/p2pool/hs_ed25519_secret_key")
tor_recover apply
[ "$before" = "$(sha256sum "$WORK/tor/p2pool/hs_ed25519_secret_key")" ]
[ ! -e "$WORK/tor/state" ] && ls "$WORK"/tor/state.backup.* >/dev/null
[ -s "$WORK/control/tor-recovery-at" ] && [ "$(tail -1 "$WORK/audit")" = applied ]
if tor_recover apply; then exit 1; fi
rm -f "$WORK"/tor/state.backup.* "$WORK/control/tor-recovery-at" "$WORK/audit"
printf 'CircuitBuildAbandonedCount 1000\nTotalBuildTimes 1000\n' >"$WORK/tor/state"

echo "== tor-history reports the saturated signature read-only =="
id=12345678-1234-4123-8123-123456789abc
jq -n --arg id "$id" '{id:$id,action:"tor-history",actor:"tor-heal"}' >"$WORK/request.json"
control_process_request "$WORK/request.json" "$WORK/control"
[ "$(jq -r .status "$WORK/result")" = applied ]
[ "$(jq -r .saturated "$WORK/result")" = true ]
printf 'CircuitBuildAbandonedCount 3\nTotalBuildTimes 1000\n' >"$WORK/tor/state"
control_process_request "$WORK/request.json" "$WORK/control"
[ "$(jq -r .saturated "$WORK/result")" = false ]
AUTO_HEAL_OFF=1
env_get() {
    case "$1" in
    CONTROL_DIR) printf '%s\n' "$WORK/control" ;;
    TOR_AUTO_HEAL) if [ "${AUTO_HEAL_OFF:-0}" = 1 ]; then printf 'false\n'; else printf 'true\n'; fi ;;
    NETWORK_PREFIX) printf '172.28.0\n' ;;
    esac
}
control_process_request "$WORK/request.json" "$WORK/control"
[ "$(jq -r .status "$WORK/result")" = rejected ]
AUTO_HEAL_OFF=0
jq '.extra="x"' "$WORK/request.json" >"$WORK/extra.json"
control_process_request "$WORK/extra.json" "$WORK/control"
[ "$(jq -r .status "$WORK/result")" = rejected ]
echo "== doctor FAILs a saturated history under a sustained heal outage =="
# shellcheck source=lib/pithead/21-doctor-stack-checks.sh
source "$ROOT/lib/pithead/21-doctor-stack-checks.sh"
container_is_running() { return 0; }
dr_fail() { printf '%s\n' "$1" >>"$WORK/doctor"; }
printf 'CircuitBuildAbandonedCount 1000\nTotalBuildTimes 1000\n' >"$WORK/tor/state"
check_tor_circuit_history
grep -q "pithead tor-recover check" "$WORK/doctor"
rm "$WORK/doctor"
export EGRESS=up
check_tor_circuit_history
export EGRESS=down
rm "$WORK/control/tor-newnym-budget"
check_tor_circuit_history
[ ! -e "$WORK/doctor" ]
echo 'tor heal outage recovery PASS'
