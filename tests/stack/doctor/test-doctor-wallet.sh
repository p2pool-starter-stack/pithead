# shellcheck shell=bash
: "${STACK_SUITE:?run through tests/stack/run.sh}"
echo "== unit: doctor Tari payout wallet address (#2498) =="
printf 'TARI_WALLET_ADDRESS=expected\n' >>"$SANDBOX/.env"
rm -f "$DRBIN/python3"
cp "$DRBIN/curl" "$DRBIN/curl.before-wallet"
cat >"$DRBIN/curl" <<'EOF'
#!/bin/sh
[ "${TARI_FAKE_SILENT:-0}" = 1 ] && exit 7
printf 'HTTP/2 200\r\ngrpc-status: 0\r\n' >&2
python3 - <<'PY'
import os
import sys

address = os.environ.get("TARI_FAKE_ADDRESS", "expected").encode()
payload = b"\x1a" + bytes([len(address)]) + address
sys.stdout.buffer.write(b"\x00" + len(payload).to_bytes(4, "big") + payload)
PY
EOF
chmod +x "$DRBIN/curl"
out="$(RUNNING_CONTAINERS="tari-wallet" TARI_FAKE_ADDRESS=expected PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tari_wallet_address 2>&1)"
assert_contains "Tari wallet: gRPC and address match -> OK" "$out" "address matches"
out="$(RUNNING_CONTAINERS="tari-wallet" TARI_FAKE_ADDRESS=wrong PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tari_wallet_address 2>&1)"
assert_contains "Tari wallet: wrong-key address -> warning" "$out" "address differs"
out="$(RUNNING_CONTAINERS="tari-wallet" TARI_FAKE_SILENT=1 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tari_wallet_address 2>&1)"
assert_contains "Tari wallet: silent gRPC -> warning" "$out" "gRPC did not answer"
out="$(RUNNING_CONTAINERS="" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tari_wallet_address 2>&1)"
assert_eq "Tari wallet: feature off -> no line" "$out" ""
mv "$DRBIN/curl.before-wallet" "$DRBIN/curl"
