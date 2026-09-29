#!/bin/sh
# An empty GetVersion request is a five-byte gRPC frame. Check the gRPC status, not just HTTP 200.
set -u
WALLET_DIR="${WALLET_DIR:-/var/tari/wallet}"
marker="$WALLET_DIR/.payout-scanning"
grace="${PAYOUT_SCAN_GRACE_SEC:-86400}"

if headers=$(printf '\000\000\000\000\000' | curl -fsS --http2-prior-knowledge --max-time 3 \
    -D - -o /dev/null \
    -H 'content-type: application/grpc' -H 'te: trailers' --data-binary @- \
    http://127.0.0.1:18143/tari.rpc.Wallet/GetVersion 2>/dev/null) &&
    printf '%s\n' "$headers" | tr -d '\r' | grep -qi '^grpc-status: *0$'; then
    rm -f "$marker"
    exit 0
fi

mtime=$(stat -c %Y "$marker" 2>/dev/null) || exit 1
now=$(date +%s) || exit 1
case "$grace:$mtime:$now" in *[!0-9:]* | *::* | :* | *:) exit 1 ;; esac
[ "$now" -ge "$mtime" ] && [ "$((now - mtime))" -lt "$grace" ]
