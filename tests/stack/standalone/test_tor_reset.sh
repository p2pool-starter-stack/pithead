#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-${RUNNER_TEMP:-/tmp}}/pithead-tor-reset.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=lib/pithead/02e-tor-recovery.sh
source "$ROOT/lib/pithead/02e-tor-recovery.sh"
# shellcheck source=lib/pithead/22a-config-document.sh
source "$ROOT/lib/pithead/22a-config-document.sh"
# shellcheck source=lib/pithead/49-control-request-loop.sh
source "$ROOT/lib/pithead/49-control-request-loop.sh"
# shellcheck source=lib/pithead/48b-control-tor-recover.sh
source "$ROOT/lib/pithead/48b-control-tor-recover.sh"
bundle_redact_log() { cat; }
mkdir -p "$WORK/tor/p2pool" "$WORK/control/audit" "$WORK/control/results"
printf 'identity\n' >"$WORK/tor/p2pool/hs_ed25519_secret_key"
SATURATED='CircuitBuildAbandonedCount 1000\nTotalBuildTimes 1000\n'
UNSATURATED='CircuitBuildAbandonedCount 3\nTotalBuildTimes 1000\n'
sudo() {
    [ "${1:-}" != -n ] || shift
    "$@"
}
sleep() { :; }
log() { :; }
warn() { printf '%s\n' "$*"; }
require_deployed() { :; }
mutation_lock_acquire() { _PITHEAD_LOCK_OWNED=1; }
mutation_lock_release() { :; }
control_audit() { printf '%s %s %s\n' "$3" "$4" "$5" >>"$WORK/audit"; }
control_write_result() {
    printf '%s\n' "$3" >"$1/$2.json"
    cp "$1/$2.json" "$WORK/result"
}
tor_recovery_mount() { printf '%s\n' "$WORK/tor"; }
env_get() {
    case "$1" in
    CONTROL_DIR) printf '%s\n' "$WORK/control" ;;
    TOR_AUTO_HEAL) printf '%s\n' "${AUTO_HEAL:-true}" ;;
    esac
}
tor_recovery_heal_outage() { return 0; }
tor_recovery_egress_down() { return 0; }
tor_recovery_info() { printf '{"status":"OK","synchronized":true,"height":42,"outgoing_connections_count":%s}\n' "$([ -e "$WORK/stopped" ] && echo 0 || echo 3)"; }
docker() {
    case "$*" in
    'compose stop tor') : >"$WORK/stopped" ;;
    'compose start tor') rm -f "$WORK/stopped" ;;
    'compose restart monerod') printf 'redial\n' >>"$WORK/actions" ;;
    *'.State.Running'*) if [ -e "$WORK/stopped" ]; then printf 'false\n'; else printf 'true\n'; fi ;;
    *'.State.Health.Status'*) printf 'healthy\n' ;;
    esac
}
id=12345678-1234-4123-8123-123456789abc
request() { # <action> <actor> [extra json]
    jq -n --arg id "$id" --arg a "$1" --arg actor "$2" "{id:\$id,action:\$a,actor:\$actor${3:-}}" >"$WORK/request.json"
    control_process_request "$WORK/request.json" "$WORK/control"
}
reset_state() {
    rm -f "$WORK/audit" "$WORK/actions" "$WORK/stopped" "$WORK/control/tor-reset-at" "$WORK/control/tor-recovery-at"
    rm -rf "$WORK"/tor/state.backup.*
    printf "$SATURATED" >"$WORK/tor/state"
}
status() { jq -r .status "$WORK/result"; }
err() { jq -r '.error // ""' "$WORK/result"; }

echo "== reset is refused while Tor auto-heal is off =="
reset_state
AUTO_HEAL=false request tor-reset alice
[ "$(status)" = rejected ]
[[ "$(err)" == *TOR_AUTO_HEAL* ]]
[ ! -e "$WORK/actions" ]
[ ! -e "$WORK/stopped" ]
[ -e "$WORK/tor/state" ]
[ "$(tail -1 "$WORK/audit")" = "alice tor-reset rejected" ]

echo "== reset rejects unexpected request keys and the tor-heal actor =="
reset_state
request tor-reset alice ',confirm:"x"'
[ "$(status)" = rejected ]
[ -e "$WORK/tor/state" ]
request tor-reset tor-heal
[ "$(status)" = rejected ]
[ ! -e "$WORK/stopped" ]

echo "== each 02e gate refuses the dashboard reset with its own reason =="
reset_state
printf "$UNSATURATED" >"$WORK/tor/state"
request tor-reset alice
[ "$(status)" = failed ]
[[ "$(err)" == *"circuit history is not saturated"* ]]
[ "$(tail -1 "$WORK/audit")" = "alice tor-reset failed" ]
[ ! -e "$WORK/stopped" ]
reset_state
date +%s >"$WORK/control/tor-recovery-at"
request tor-reset alice
[ "$(status)" = failed ]
[[ "$(err)" == *"six-hour cooldown"* ]]
reset_state
tor_recovery_heal_outage() { return 1; }
docker_real=$(declare -f docker)
docker() { case "$*" in *'.State.Running'*) printf 'false\n' ;; esac }
tor_recovery_bootstrap_stalled() { return 1; }
request tor-reset alice
[ "$(status)" = failed ]
[[ "$(err)" == *"not corroborated"* ]]
tor_recovery_heal_outage() { return 0; }
eval "$docker_real"
reset_state
mutation_lock_acquire() { _PITHEAD_LOCK_OWNED=0; }
request tor-reset alice
[ "$(status)" = failed ]
[[ "$(err)" == *"mutation lock is unavailable"* ]]
mutation_lock_acquire() { _PITHEAD_LOCK_OWNED=1; }

echo "== a satisfied reset applies once and re-dials monerod =="
reset_state
request tor-reset alice
[ "$(status)" = applied ]
[ "$(jq -r .action "$WORK/result")" = tor-reset ]
[ ! -e "$WORK/tor/state" ]
ls "$WORK"/tor/state.backup.* >/dev/null
grep -q redial "$WORK/actions"
grep -qx 'alice tor-reset applied' "$WORK/audit"
[ -s "$WORK/control/tor-reset-at" ]

echo "== a repeat inside the reset's own cooldown is rejected without touching Tor =="
rm -f "$WORK/actions" "$WORK/control/tor-recovery-at"
printf "$SATURATED" >"$WORK/tor/state"
request tor-reset alice
[ "$(status)" = rejected ]
[[ "$(err)" == *"already requested"* ]]
[ ! -e "$WORK/actions" ]
[ -e "$WORK/tor/state" ]
[ "$(tail -1 "$WORK/audit")" = "alice tor-reset rejected" ]
printf '%s\n' "$(($(date +%s) + 5000))" >"$WORK/control/tor-reset-at"
rm -rf "$WORK"/tor/state.backup.*
request tor-reset alice
[ "$(status)" = applied ]
rm -f "$WORK/control/tor-recovery-at"
rm -rf "$WORK"/tor/state.backup.*
printf "$SATURATED" >"$WORK/tor/state"
printf '%s\n' "$(($(date +%s) - 2000))" >"$WORK/control/tor-reset-at"
request tor-reset alice
[ "$(status)" = applied ]
rm -rf "$WORK"/tor/state.backup.*

echo "== tor-heal's tor-recover path is unchanged =="
reset_state
request tor-recover alice
[ "$(status)" = rejected ]
[ -e "$WORK/tor/state" ]
request tor-recover tor-heal
[ "$(status)" = applied ]
[ "$(jq -r .action "$WORK/result")" = tor-recover ]
grep -qx 'tor-heal tor-recover applied' "$WORK/audit"
[ ! -e "$WORK/control/tor-reset-at" ]
echo "tor reset contract passed"
