#!/usr/bin/env bash
# Pure CLI recovery contract: no engine or bench access.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:?}/pithead-tor-recovery.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=lib/pithead/02e-tor-recovery.sh
source "$ROOT/lib/pithead/02e-tor-recovery.sh"
echo "== tor recovery refuses unsafe state and preserves identities =="
mkdir -p "$WORK/tor/p2pool" "$WORK/control/audit"
printf 'identity\n' >"$WORK/tor/p2pool/hs_ed25519_secret_key"
printf 'chain-data\n' >"$WORK/chain"
printf 'CircuitBuildAbandonedCount 1000\nTotalBuildTimes 1000\n' >"$WORK/tor/state"
bad='{"status":"OK","synchronized":false,"height":42,"outgoing_connections_count":0}'
good='{"status":"OK","synchronized":true,"height":43,"outgoing_connections_count":2}'
tor_recovery_signature "$WORK/tor/state" "$bad" "$bad"
if tor_recovery_signature "$WORK/tor/state" "$bad" "$good"; then exit 1; fi
printf 'CircuitBuildTimeBin 1 2\n' >>"$WORK/tor/state"
if tor_recovery_signature "$WORK/tor/state" "$bad" "$bad"; then exit 1; fi
sed -i.bak '/CircuitBuildTimeBin/d' "$WORK/tor/state"
rm -f "$WORK/tor/state.bak"
ln -s state "$WORK/tor/linked"
if tor_recovery_signature "$WORK/tor/linked" "$bad" "$bad"; then exit 1; fi

realpath() { if command -v grealpath >/dev/null; then grealpath "$@"; else command realpath "$@"; fi; }
TOR_EXPECTED="$WORK/tor"
MOUNT_COUNT=x
env_get() { case "$1" in TOR_DATA_DIR) printf '%s\n' "$TOR_EXPECTED" ;; esac }
docker() {
    case "$*" in
    *'.Config.Labels'*) printf 'tor\n' ;;
    *'.Source'*) printf '%s\n' "$WORK/tor" ;;
    *'.Destination'*) printf '%s\n' "$MOUNT_COUNT" ;;
    esac
}
[ "$(tor_recovery_mount)" = "$WORK/tor" ]
MOUNT_COUNT=xx
if tor_recovery_mount >/dev/null; then exit 1; fi
MOUNT_COUNT=x
ln -s tor "$WORK/tor-symlink"
TOR_EXPECTED="$WORK/tor-symlink"
if tor_recovery_mount >/dev/null; then exit 1; fi
TOR_EXPECTED="$WORK/tor"
mv "$WORK/tor/state" "$WORK/tor/state-real"
ln -s state-real "$WORK/tor/state"
if tor_recovery_mount >/dev/null; then exit 1; fi
rm "$WORK/tor/state"
mv "$WORK/tor/state-real" "$WORK/tor/state"

require_deployed() { :; }
mutation_lock_acquire() { [ "${ACTIVE:-0}" = 0 ] && _PITHEAD_LOCK_OWNED=1; }
mutation_lock_release() { :; }
tor_recovery_mount() { printf '%s\n' "$WORK/tor"; }
env_get() { case "$1" in CONTROL_DIR) printf '%s\n' "$WORK/control" ;; TOR_AUTO_HEAL) printf '%s\n' "${AUTO_HEAL:-true}" ;; esac }
tor_recovery_info() {
    if [ -e "$WORK/started" ]; then printf '%s\n' "$good"; else printf '%s\n' "$bad"; fi
}
sleep() { :; }
log() { :; }
warn() { :; }
control_audit() { printf '%s\n' "$5" >>"$WORK/audit"; }
sudo() { "$@"; }
docker() {
    case "$*" in
    'exec tor /usr/local/bin/tor-control-signal.sh NEWNYM') printf 'newnym\n' >>"$WORK/actions" ;;
    'compose stop tor')
        printf 'stop\n' >>"$WORK/actions"
        if [ "${STOP_FAIL:-0}" = 1 ]; then return 1; fi
        : >"$WORK/stopped"
        if [ "${STOP_FAIL:-0}" = 2 ]; then return 1; fi
        ;;
    'compose start tor')
        printf 'start\n' >>"$WORK/actions"
        if [ "${ALTER_IDENTITY:-0}" = 1 ]; then printf 'changed identity\n' >"$WORK/tor/p2pool/hs_ed25519_secret_key"; fi
        : >"$WORK/started"
        rm -f "$WORK/stopped"
        ;;
    'compose restart monerod') printf 'redial\n' >>"$WORK/actions" ;;
    *'com.docker.compose.service'*) printf 'tor\n' ;;
    *'.State.Running'*) if [ -e "$WORK/stopped" ]; then printf 'false\n'; else printf 'true\n'; fi ;;
    *'.State.Health.Status'*) printf 'healthy\n' ;;
    esac
}

ACTIVE=1
if tor_recover apply; then exit 1; fi
[ ! -e "$WORK/actions" ]
ACTIVE=0
tor_recover check
[ ! -e "$WORK/actions" ] && [ ! -e "$WORK/control/tor-recovery-at" ]
before=$(sha256sum "$WORK/tor/p2pool/hs_ed25519_secret_key")
chain_before=$(sha256sum "$WORK/chain")
tor_recover apply
[ "$(cat "$WORK/actions")" = "$(printf 'stop\nstart\nredial')" ]
[ -f "$WORK/tor/state.backup.$(cat "$WORK/control/tor-recovery-at")" ]
[ "$before" = "$(sha256sum "$WORK/tor/p2pool/hs_ed25519_secret_key")" ]
[ "$chain_before" = "$(sha256sum "$WORK/chain")" ]
[ ! -e "$WORK/tor/state" ]
[ "$(tail -1 "$WORK/audit")" = applied ]
if tor_recover apply; then exit 1; fi
[ "$(wc -l <"$WORK/actions" | tr -d ' ')" = 3 ]
rm "$WORK/control/tor-recovery-at" "$WORK/started" "$WORK/actions"
rm "$WORK"/tor/state.backup.*
printf 'CircuitBuildAbandonedCount 1000\nTotalBuildTimes 1000\n' >"$WORK/tor/state"
sudo() { if [ "$1" = mv ]; then return 1; else "$@"; fi; }
if tor_recover apply; then exit 1; fi
[ "$(cat "$WORK/actions")" = "$(printf 'stop\nstart\nredial')" ]
[ -f "$WORK/tor/state" ]
[ "$before" = "$(sha256sum "$WORK/tor/p2pool/hs_ed25519_secret_key")" ]
[ -f "$WORK/control/tor-recovery-at" ]
if tor_recover apply; then exit 1; fi
[ "$(cat "$WORK/actions")" = "$(printf 'stop\nstart\nredial')" ]
rm "$WORK/control/tor-recovery-at" "$WORK/started" "$WORK/actions"
sudo() { "$@"; }
STOP_FAIL=1
if tor_recover apply; then exit 1; fi
[ "$(cat "$WORK/actions")" = stop ]
rm "$WORK/control/tor-recovery-at" "$WORK/actions"
STOP_FAIL=2
if tor_recover apply; then exit 1; fi
[ "$(cat "$WORK/actions")" = "$(printf 'stop\nstart\nredial')" ]
rm "$WORK/control/tor-recovery-at" "$WORK/started" "$WORK/actions"
STOP_FAIL=0
ALTER_IDENTITY=1
if tor_recover apply; then exit 1; fi
[ "$(cat "$WORK/actions")" = "$(printf 'stop\nstart\nstop')" ]
[ "$(docker inspect tor --format '{{.State.Running}}')" = false ]
[ "$(tail -1 "$WORK/audit")" = failed ]
ALTER_IDENTITY=0
mkdir -p "$WORK/bin"
printf 'cookie-for-test\n' >"$WORK/cookie"
cat >"$WORK/bin/nc" <<'SH'
#!/bin/sh
cat >"$TOR_CAPTURE"
printf '250 OK\r\n250 OK\r\n'
SH
chmod +x "$WORK/bin/nc"
TOR_CAPTURE="$WORK/signal" TOR_COOKIE_FILE="$WORK/cookie" PATH="$WORK/bin:$PATH" \
    sh "$ROOT/build/tor/control-signal.sh" NEWNYM >"$WORK/signal-result"
grep -q '^SIGNAL NEWNYM' "$WORK/signal"
! grep -q 'DROPGUARDS' "$WORK/signal"
[ "$(cat "$WORK/signal-result")" = 'NEWNYM accepted' ]

# The dashboard can request only the fixed circuit signal; the host validates the shape.
# shellcheck source=lib/pithead/49-control-request-loop.sh
source "$ROOT/lib/pithead/49-control-request-loop.sh"
control_write_result() { printf '%s\n' "$3" >"$WORK/result"; }
id=12345678-1234-4123-8123-123456789abc
jq -n --arg id "$id" '{id:$id,action:"tor-newnym",actor:"tor-heal"}' >"$WORK/request.json"
AUTO_HEAL=false
control_process_request "$WORK/request.json" "$WORK/control"
[ "$(jq -r .status "$WORK/result")" = rejected ]
AUTO_HEAL=true
ACTIVE=1
control_process_request "$WORK/request.json" "$WORK/control"
[ "$(jq -r .status "$WORK/result")" = rejected ]
[ ! -e "$WORK/control/tor-newnym-budget" ]
ACTIVE=0
control_process_request "$WORK/request.json" "$WORK/control"
[ "$(jq -r .status "$WORK/result")" = applied ]
[ "$(tail -1 "$WORK/actions")" = newnym ]
control_process_request "$WORK/request.json" "$WORK/control"
[ "$(jq -r .status "$WORK/result")" = rejected ]
[ "$(tail -1 "$WORK/actions")" = newnym ]
read -r first count <"$WORK/control/tor-newnym-budget"
[ "$count" = 1 ]
printf '%s 1\n' "$((first - 1801))" >"$WORK/control/tor-newnym-budget"
control_process_request "$WORK/request.json" "$WORK/control"
[ "$(jq -r .status "$WORK/result")" = applied ]
control_process_request "$WORK/request.json" "$WORK/control"
[ "$(jq -r .status "$WORK/result")" = rejected ]
[ "$(grep -c '^newnym$' "$WORK/actions")" = 2 ]
jq '.extra="DROPGUARDS"' "$WORK/request.json" >"$WORK/rejected.json"
control_process_request "$WORK/rejected.json" "$WORK/control"
[ "$(jq -r .status "$WORK/result")" = rejected ]
[ "$(grep -c '^newnym$' "$WORK/actions")" = 2 ]
echo 'tor recovery unit PASS'
