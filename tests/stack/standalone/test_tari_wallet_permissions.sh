#!/usr/bin/env bash
# The wallet wrapper must repair a root-owned named volume before launching as uid 1000 (#2454).
set -euo pipefail
echo "== tari-wallet volume ownership and uid drop =="
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/wallet/mainnet/config/wallet"
printf 'MINOTARI_WALLET_PASSWORD=fixture\n' >"$WORK/secret"
cat >"$WORK/bin/stat" <<'EOF'
#!/usr/bin/env bash
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
grep -qxF "chown -R 1000:1000 $WORK/wallet" "$WORK/actions"
grep -qF 'setpriv --reuid=1000 --regid=1000 --clear-groups minotari_console_wallet' "$WORK/actions"
grep -qF "wallet --base-path $WORK/wallet" "$WORK/actions"
run_case 1000
! grep -q '^chown ' "$WORK/actions"
grep -qF 'setpriv --reuid=1000 --regid=1000 --clear-groups minotari_console_wallet' "$WORK/actions"
echo 'PASS: Tari wallet repairs root-owned volume and starts as uid 1000'
