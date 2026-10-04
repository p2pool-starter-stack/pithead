#!/usr/bin/env bash
# Recovery evidence from the dashboard heal's own NEWNYM record, and the read-only
# tor-history verb (#3052). No engine or bench access.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:?}/pithead-tor-heal-outage.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=lib/pithead/02e-tor-recovery.sh
source "$ROOT/lib/pithead/02e-tor-recovery.sh"
# shellcheck source=lib/pithead/22a-config-document.sh
source "$ROOT/lib/pithead/22a-config-document.sh"
# shellcheck source=lib/pithead/49-control-request-loop.sh
source "$ROOT/lib/pithead/49-control-request-loop.sh"
echo "== tor-recover accepts a sustained heal outage on a synchronized Monero =="
mkdir -p "$WORK/tor/p2pool" "$WORK/control/audit" "$WORK/control/results" "$WORK/bin"
printf 'identity\n' >"$WORK/tor/p2pool/hs_ed25519_secret_key"
printf 'CircuitBuildAbandonedCount 1000\nTotalBuildTimes 1000\n' >"$WORK/tor/state"
sudo() {
    [ "${1:-}" != -n ] || shift
    "$@"
}
sleep() { :; }
log() { :; }
warn() { :; }
require_deployed() { :; }
mutation_lock_acquire() { _PITHEAD_LOCK_OWNED=1; }
mutation_lock_release() { :; }
control_audit() { printf '%s\n' "$5" >>"$WORK/audit"; }
control_write_result() {
    printf '%s\n' "$3" >"$1/$2.json"
    [ "$2" = tor-heal-outage ] || cp "$1/$2.json" "$WORK/result"
}
tor_recovery_mount() { printf '%s\n' "$WORK/tor"; }
env_get() {
    case "$1" in
    CONTROL_DIR) printf '%s\n' "$WORK/control" ;;
    TOR_AUTO_HEAL) printf 'true\n' ;;
    NETWORK_PREFIX) printf '172.28.0\n' ;;
    esac
}
docker() { case "$*" in *'.State.Running'*) printf 'true\n' ;; esac }
# Monero has outgoing peers: the stalled-Monero class must not qualify (#3033).
tor_recovery_info() { printf '{"status":"OK","synchronized":true,"height":42,"outgoing_connections_count":3}\n'; }
tor_recovery_bootstrap_stalled() { return 1; }
# Fake curl: egress is down unless EGRESS=up.
cat >"$WORK/bin/curl" <<'SH'
#!/bin/sh
case "${EGRESS:-down}" in
up) exit 0 ;;
http-error)
    # curl -f treats a delivered HTTP 503 as exit 22; plain curl received a response.
    case " $* " in *" -f"*) exit 22 ;; *) exit 0 ;; esac ;;
esac
exit 1
SH
chmod +x "$WORK/bin/curl"
PATH="$WORK/bin:$PATH"

# No outage record: refused, even with a daily budget accumulated across old outages.
printf '%s 2\n' "$(($(date +%s) - 3600))" >"$WORK/control/tor-newnym-budget"
if tor_recover check; then exit 1; fi
now=$(date +%s)
id=12345678-1234-4123-8123-123456789abc
record="$WORK/control/results/tor-heal-outage.json"
write_outage() {
    jq -n --arg outage "$id" --argjson first "$1" --argjson last "$2" --argjson rounds "$3" --argjson at "$now" \
        '{outage:$outage,first:$first,last:$last,rounds:$rounds,observed_at:$at}' >"$record"
}
write_outage "$((now - 3600))" "$now" 1
if tor_recover check; then exit 1; fi
write_outage "$((now - 60))" "$now" 2
if tor_recover check; then exit 1; fi
write_outage "$((now - 90000))" "$now" 2
if tor_recover check; then exit 1; fi
# Two failed rounds over the same sustained outage, egress down, saturated: qualifies read-only.
write_outage "$((now - 3600))" "$now" 2
tor_recover check
[ ! -e "$WORK/control/tor-recovery-at" ] && [ -e "$WORK/tor/state" ]
# A healthy Tor (egress answers) stays refused.
export EGRESS=up
if tor_recover check; then exit 1; fi
export EGRESS=http-error
if tor_recover check; then exit 1; fi
export EGRESS=down
# An unsaturated history stays refused.
printf 'CircuitBuildAbandonedCount 3\nTotalBuildTimes 1000\n' >"$WORK/tor/state"
if tor_recover check; then exit 1; fi
printf 'CircuitBuildAbandonedCount 1000\nTotalBuildTimes 1000\n' >"$WORK/tor/state"
# A symlinked record is not evidence.
mv "$record" "$WORK/budget-real"
ln -s "$WORK/budget-real" "$record"
if tor_recover check; then exit 1; fi
rm "$record"
mv "$WORK/budget-real" "$record"

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
jq -n --arg id "$id" --argjson now "$now" '{id:$id,action:"tor-history",actor:"tor-heal",outage:$id,observed_at:$now}' >"$WORK/request.json"
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
echo "== host evidence separates outages and ignores delayed or duplicate observations =="
# Host timestamps the first round; repeat reads cannot become a second round.
rm "$record"
control_process_request "$WORK/request.json" "$WORK/control"
control_process_request "$WORK/request.json" "$WORK/control"
[ "$(jq .rounds "$record")" = 1 ]
if tor_recovery_heal_outage "$WORK/control"; then exit 1; fi
# A new outage resets the rounds, even when the daily NEWNYM budget has two requests.
write_outage "$((now - 3600))" "$((now - 1800))" 2
jq --arg outage "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" '.outage=$outage | .observed_at += 1' "$WORK/request.json" >"$WORK/new.json"
control_process_request "$WORK/new.json" "$WORK/control"
[ "$(jq .rounds "$record")" = 1 ]
if tor_recovery_heal_outage "$WORK/control"; then exit 1; fi
# Recovery writes a tombstone; an old request cannot resurrect evidence.
jq '.outage="" | .observed_at += 2' "$WORK/request.json" >"$WORK/recovered.json"
control_process_request "$WORK/recovered.json" "$WORK/control"
control_process_request "$WORK/request.json" "$WORK/control"
[ "$(jq .rounds "$record")" = 0 ]
if tor_recovery_heal_outage "$WORK/control"; then exit 1; fi
# Two spaced host observations qualify; stale requests and malformed schemas refuse.
write_outage "$((now - 3600))" "$((now - 1800))" 1
jq '.observed_at -= 1' "$record" >"$WORK/older.json"
mv "$WORK/older.json" "$record"
control_process_request "$WORK/request.json" "$WORK/control"
tor_recovery_heal_outage "$WORK/control"
# Both count and byte-cap pruning preserve the one persistent bounded evidence record.
CONTROL_RESULT_MAX_COUNT=0 CONTROL_RESULTS_MAX_BYTES=1 control_prune_results "$WORK/control"
[ -f "$record" ]
# A continuing outage renews its last two rounds beyond the first day's window.
write_outage "$((now - 100000))" "$((now - 1800))" 2
jq '.observed_at -= 1' "$record" >"$WORK/older.json"
mv "$WORK/older.json" "$record"
control_process_request "$WORK/request.json" "$WORK/control"
[ "$(jq .first "$record")" = "$((now - 1800))" ]
tor_recovery_heal_outage "$WORK/control"
jq '.observed_at -= 1000' "$WORK/request.json" >"$WORK/stale.json"
control_process_request "$WORK/stale.json" "$WORK/control"
[ "$(jq -r .status "$WORK/result")" = failed ]
jq '.outage=42' "$WORK/request.json" >"$WORK/bad.json"
control_process_request "$WORK/bad.json" "$WORK/control"
[ "$(jq -r .status "$WORK/result")" = rejected ]
echo "== doctor FAILs a saturated history under a sustained heal outage =="
# shellcheck source=lib/pithead/21-doctor-stack-checks.sh
source "$ROOT/lib/pithead/21-doctor-stack-checks.sh"
container_is_running() { return 0; }
dr_fail_surface() { printf '%s\n' "$1" >>"$WORK/doctor"; }
printf 'CircuitBuildAbandonedCount 1000\nTotalBuildTimes 1000\n' >"$WORK/tor/state"
check_tor_circuit_history
grep -q "pithead tor-recover check" "$WORK/doctor"
rm "$WORK/doctor"
export EGRESS=up
check_tor_circuit_history
export EGRESS=down
rm "$record"
check_tor_circuit_history
[ ! -e "$WORK/doctor" ]
echo 'tor heal outage recovery PASS'
