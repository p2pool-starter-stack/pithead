#!/usr/bin/env bash
# Bootstrap-stall recovery contract without an engine or a running chain node.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:?}/pithead-tor-bootstrap.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=lib/pithead/02e-tor-recovery.sh
source "$ROOT/lib/pithead/02e-tor-recovery.sh"
mkdir -p "$WORK/bin" "$WORK/tor/p2pool" "$WORK/control/audit"
printf 'onion-identity\n' >"$WORK/tor/p2pool/hs_ed25519_secret_key"
printf 'chain\n' >"$WORK/chain"
printf 'CircuitBuildAbandonedCount 1000\nTotalBuildTimes 1000\n' >"$WORK/tor/state"
printf '%032d' 0 >"$WORK/cookie"
cat >"$WORK/bin/nc" <<'SH'
#!/bin/sh
cat >"$TOR_CAPTURE"
cat "$TOR_REPLY"
SH
chmod +x "$WORK/bin/nc"
export TOR_CAPTURE="$WORK/request" TOR_REPLY="$WORK/reply" TOR_COOKIE_FILE="$WORK/cookie"
export PATH="$WORK/bin:$PATH"
reply='250 OK
250-status/bootstrap-phase=NOTICE BOOTSTRAP PROGRESS=95 TAG=circuit_create SUMMARY="Establishing a Tor circuit"
250-status/circuit-established=0
250 OK
250 closing connection'
printf '%s\n' "$reply" >"$TOR_REPLY"
[ "$(sh "$ROOT/build/tor/recovery-diagnose.sh")" = bootstrap95-no-circuit ]
grep -q '^AUTHENTICATE ' "$TOR_CAPTURE"
grep -q '^GETINFO status/bootstrap-phase status/circuit-established' "$TOR_CAPTURE"
for bad in \
    "${reply/250 OK/515 Authentication failed}" \
    "${reply/PROGRESS=95/PROGRESS=100}" \
    "${reply/TAG=circuit_create/TAG=done}" \
    "${reply/circuit-established=0/circuit-established=1}" \
    "${reply/circuit-established=0/circuit-established=}" \
    "$(printf '%s\n' "$reply" | sed '/circuit-established/d')" \
    "$(printf '%s\n' "$reply" | sed '/circuit-established/p')" \
    "$(printf '%s\n' "$reply" | head -n 3)" \
    "$reply
552 Unrecognized key"; do
    printf '%s\n' "$bad" >"$TOR_REPLY"
    if sh "$ROOT/build/tor/recovery-diagnose.sh" >"$WORK/output"; then exit 1; fi
    [ ! -s "$WORK/output" ]
done
printf short >"$WORK/cookie"
printf '%s\n' "$reply" >"$TOR_REPLY"
if sh "$ROOT/build/tor/recovery-diagnose.sh" >"$WORK/output"; then exit 1; fi
[ ! -s "$WORK/output" ]

sudo() { "$@"; }
require_deployed() { :; }
mutation_lock_acquire() { [ "${ACTIVE:-0}" = 0 ] && _PITHEAD_LOCK_OWNED=1; }
mutation_lock_release() { :; }
env_get() { printf '%s\n' "$WORK/control"; }
tor_recovery_mount() { printf '%s\n' "$WORK/tor"; }
log() { :; }
warn() { :; }
control_audit() { printf '%s\n' "$5" >>"$WORK/audit"; }
sleep() { : >"$WORK/observed"; }
timeout() {
    shift
    "$@"
}
tor_recovery_info() {
    if [ -e "$WORK/node-started" ]; then
        printf '{"status":"OK","synchronized":true,"height":43,"outgoing_connections_count":2}\n'
    elif [ "${RPC:-unavailable}" = advancing ]; then
        printf '{"status":"OK","synchronized":true,"height":42,"outgoing_connections_count":2}\n'
    else
        return 1
    fi
}
docker() {
    case "$*" in
        *'.Id}}'*)
            if [ "${RECREATED:-0}" = 1 ] && [ -e "$WORK/observed" ]; then printf 'different startup true\n'; else printf 'same startup true\n'; fi
            ;;
        *'.State.Running'*) if [ "${RPC:-unavailable}" = advancing ] || [ -e "$WORK/node-started" ]; then echo true; else echo false; fi ;;
        *'.State.StartedAt'*) echo startup ;;
        *'.State.Status'*) echo created ;;
        *'.State.Health.Status'*) echo healthy ;;
        'exec tor /usr/local/bin/tor-recovery-diagnose.sh')
            [ "${AUTH_FAIL:-0}" = 0 ] || return 1
            [ "${CIRCUIT:-0}" = 0 ] || return 1
            [ "${BOOTSTRAP:-95}" = 95 ] || return 1
            if [ "${RECOVERED:-0}" = 1 ] && [ -e "$WORK/observed" ]; then return 1; fi
            echo bootstrap95-no-circuit
            ;;
        'logs --since '*' --tail 200 tor')
            [ "${LOG_FAIL:-0}" = 0 ] || return 1
            for ((n = 0; n < ${WARNINGS:-2}; n++)); do echo 'No valid circuit build time data out of 1000 times'; done
            ;;
        'compose stop tor') echo stop >>"$WORK/actions" ;;
        'compose start tor') echo start >>"$WORK/actions" ;;
        'compose start monerod')
            echo node-start >>"$WORK/actions"
            : >"$WORK/node-started"
            ;;
        'compose restart monerod') echo redial >>"$WORK/actions" ;;
        *)
            echo "unexpected Docker command: $*" >&2
            return 1
            ;;
    esac
}
refused() {
    rm -f "$WORK/observed"
    if tor_recover apply; then
        echo 'unsafe recovery accepted' >&2
        exit 1
    fi
    [ ! -e "$WORK/actions" ] && [ ! -e "$WORK/control/tor-recovery-at" ]
}
ACTIVE=1 refused
AUTH_FAIL=1 refused
BOOTSTRAP=100 refused
CIRCUIT=1 refused
WARNINGS=0 refused
WARNINGS=1 refused
LOG_FAIL=1 refused
RECREATED=1 refused
RECOVERED=1 refused
RPC=advancing refused
printf 'CircuitBuildTimeBin 1 2\n' >>"$WORK/tor/state"
refused
sed -i '/CircuitBuildTimeBin/d' "$WORK/tor/state"
before=$(sha256sum "$WORK/tor/p2pool/hs_ed25519_secret_key" "$WORK/chain")
rm -f "$WORK/observed"
tor_recover check
[ ! -e "$WORK/actions" ] && [ ! -e "$WORK/control/tor-recovery-at" ]
rm -f "$WORK/observed"
tor_recover apply
[ "$(cat "$WORK/actions")" = "$(printf 'stop\nstart\nnode-start')" ]
[ "$(sha256sum "$WORK/tor/p2pool/hs_ed25519_secret_key" "$WORK/chain")" = "$before" ]
[ -f "$WORK/tor/state.backup.$(cat "$WORK/control/tor-recovery-at")" ]
[ ! -e "$WORK/tor/state" ]
[ "$(tail -1 "$WORK/audit")" = applied ]
if tor_recover apply; then exit 1; fi
[ "$(wc -l <"$WORK/actions")" -eq 3 ]
echo 'Tor bootstrap recovery contract PASS'
