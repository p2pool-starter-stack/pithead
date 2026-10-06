#!/usr/bin/env bash
# The wallet wrapper must repair a root-owned named volume before launching as uid 1000 (#2454).
set -euo pipefail
echo "== tari-wallet volume ownership and uid drop =="
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=tests/stack/lib.sh
source "$ROOT/tests/stack/lib.sh"
WORK="$SANDBOX"
mkdir -p "$WORK/bin" "$WORK/wallet/mainnet/config/wallet"
printf 'MINOTARI_WALLET_PASSWORD=fixture\nMINOTARI_WALLET_VIEW_PRIVATE_KEY=synthetic\nMINOTARI_WALLET_SPEND_KEY=public\n' >"$WORK/secret"
cat >"$WORK/bin/stat" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -c ] && [ "${2:-}" = %Y ]; then
    /usr/bin/stat -c %Y "$3" 2>/dev/null || /usr/bin/stat -f %m "$3"
    exit
fi
printf '%s\n' "$FIXTURE_OWNER"
EOF
cat >"$WORK/bin/chown" <<'EOF'
#!/usr/bin/env bash
printf 'chown %s\n' "$*" >>"$FIXTURE_LOG"
EOF
cat >"$WORK/bin/setpriv" <<'EOF'
#!/usr/bin/env bash
printf 'setpriv %s\n' "$*" >>"$FIXTURE_LOG"
shift 3
exec "$@"
EOF
cat >"$WORK/bin/minotari_console_wallet" <<'EOF'
#!/usr/bin/env bash
printf 'wallet %s\n' "$*" >>"$FIXTURE_LOG"
EOF
chmod +x "$WORK/bin/"*
run_case() {
    : >"$WORK/actions"
    PATH="$WORK/bin:$PATH" FIXTURE_OWNER="$1" FIXTURE_LOG="$WORK/actions" \
        WALLET_DIR="$WORK/wallet" TARI_WALLET_SECRET_FILE_IN="$WORK/secret" \
        bash "$ROOT/build/tari-wallet/entrypoint.sh" >/dev/null
}
run_case 0
marker="$WORK/wallet/.payout-scanning"
[ -f "$marker" ]
touch -t 200001010000.00 "$marker"
grep -qxF "chown -R 1000:1000 $WORK/wallet" "$WORK/actions"
grep -qF 'setpriv --reuid=1000 --regid=1000 --clear-groups minotari_console_wallet' "$WORK/actions"
grep -qF "wallet --base-path $WORK/wallet" "$WORK/actions"
run_case 1000
[ "$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker")" -lt "$(date +%s)" ]
! grep -q '^chown ' "$WORK/actions"
grep -qF 'setpriv --reuid=1000 --regid=1000 --clear-groups minotari_console_wallet' "$WORK/actions"
cat >"$WORK/bin/curl" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = -D ]; then shift; [ "$1" = - ] || exit 8; fi
    shift
done
if [ "${FAKE_GRPC_OK:-0}" = 1 ]; then
    printf 'HTTP/2 200\r\ngrpc-status: 0\r\n'
    exit 0
fi
if [ "${FAKE_GRPC_OK:-0}" = 2 ]; then
    printf 'HTTP/2 200\r\n'
    exit 0
fi
exit 7
EOF
chmod +x "$WORK/bin/curl"
health_rc() { (
    rc=0
    PATH="$WORK/bin:$PATH" WALLET_DIR="$WORK/wallet" FAKE_GRPC_OK="$1" PAYOUT_SCAN_GRACE_SEC="${2:-86400}" sh "$ROOT/build/tari-wallet/wallet-healthcheck.sh" >/dev/null 2>&1 || rc=$?
    echo "$rc"
); }
touch "$marker"
[ "$(health_rc 0)" = 0 ]   # a first scan gets bounded grace
[ "$(health_rc 2)" = 0 ]   # HTTP success without gRPC status still gets bounded grace
[ "$(health_rc 0 0)" = 1 ] # zero grace is strict
touch -t 200001010000.00 "$marker"
[ "$(health_rc 0)" = 1 ] # expired grace fails
[ "$(health_rc 2)" = 1 ] # silent gRPC must fail after expiry
[ "$(health_rc 1)" = 0 ] # successful gRPC retires grace
[ ! -e "$marker" ]
[ "$(health_rc 0)" = 1 ] # later failure is strict
echo 'PASS: Tari wallet repairs root-owned volume and starts as uid 1000'
