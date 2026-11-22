#!/bin/sh
set -eu

# Optional stratum-miner auth (#152). Compose's command LIST can't omit an element: a
# `${PROXY_STRATUM_PASSWORD:+--access-password=...}` item renders a stray '' positional arg when the
# password is unset (xmrig-proxy logs `unsupported non-option argument ''`). So the flag is passed as
# an env var and appended HERE instead — an empty/unset value appends nothing, no stray arg. Mirrors
# p2pool's entrypoint word-splitting of $P2POOL_FLAGS.
if [ -n "${PROXY_STRATUM_PASSWORD:-}" ]; then
    set -- "$@" "--access-password=$PROXY_STRATUM_PASSWORD"
fi

# Stratum-over-TLS (#261): with the cert flags present, xmrig-proxy autodetects TLS vs cleartext
# per-connection on the same bind — no second port. Same append-here pattern as the password.
# TLS_MOUNT is fixed by the compose mount; the override exists so the shell suite can exercise
# this branch against a temp dir instead of a root-owned /tls.
TLS_MOUNT="${PROXY_TLS_MOUNT:-/tls}"
if [ "${PROXY_STRATUM_TLS:-false}" = "true" ] && [ -f "$TLS_MOUNT/cert.pem" ] && [ -f "$TLS_MOUNT/key.pem" ]; then
    set -- "$@" "--tls-cert=$TLS_MOUNT/cert.pem" "--tls-cert-key=$TLS_MOUNT/key.pem"
fi

_quiet_repeats() {
    _qr_last=0 _qr_hidden=0
    while IFS= read -r _qr_line || [ -n "$_qr_line" ]; do
        case $_qr_line in
        *"$1"*) ;;
        *)
            printf '%s\n' "$_qr_line"
            continue
            ;;
        esac
        _qr_now=$(date +%s 2>/dev/null) || _qr_now=$((_qr_last + 60))
        [ "$_qr_now" -ge "$_qr_last" ] || _qr_last=$((_qr_now - 60))
        if [ $((_qr_now - _qr_last)) -ge 60 ]; then
            [ "$_qr_hidden" -eq 0 ] || printf '[%s] %s similar lines hidden in the last minute\n' "$2" "$_qr_hidden"
            printf '%s\n' "$_qr_line"
            _qr_last=$_qr_now _qr_hidden=0
        else
            _qr_hidden=$((_qr_hidden + 1))
        fi
    done
    [ "$_qr_hidden" -eq 0 ] || printf '[%s] %s similar lines hidden in the last minute\n' "$2" "$_qr_hidden"
}

_exec_quiet() {
    _qr_pat=$1 _qr_name=$2
    shift 2
    _qr_fifo="/tmp/$_qr_name-log.fifo"
    rm -f "$_qr_fifo"
    mkfifo "$_qr_fifo" 2>/dev/null || {
        echo "[$_qr_name-entrypoint] cannot create the log fifo: retry lines are not rate-limited" >&2
        exec "$@"
    }
    _quiet_repeats "$_qr_pat" "$_qr_name" <"$_qr_fifo" &
    exec "$@" >"$_qr_fifo" 2>&1
}

_exec_quiet 'connect error: "connection refused"' xmrig-proxy xmrig-proxy "$@"
