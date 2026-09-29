# shellcheck shell=bash
# The wallet's own gRPC address must match the payout target; process liveness cannot prove it.
check_tari_wallet_address() {
    container_is_running tari-wallet || return 0
    if ! command -v curl >/dev/null || ! command -v python3 >/dev/null; then
        dr_info "Tari wallet address check skipped — needs curl and python3."
        return 0
    fi
    local expected expected_key verdict
    expected=$(env_get TARI_WALLET_ADDRESS 2>/dev/null)
    [ -n "$expected" ] || {
        dr_info "Tari wallet address check skipped — no payout address configured."
        return 0
    }
    expected_key=$(TARI_ADDRESS_KEY_ONLY=1 tari_address_type "$expected")
    verdict=$(
        TARI_EXPECTED_ADDRESS="$expected" TARI_EXPECTED_KEY="$expected_key" python3 - <<'PY'
import os
import re
import subprocess


def varint(data, pos):
    value = shift = 0
    while pos < len(data):
        byte = data[pos]
        pos += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, pos
        shift += 7
    raise ValueError("truncated protobuf")


try:
    response = subprocess.run(
        ["curl", "-fsS", "--http2-prior-knowledge", "--max-time", "5", "--max-filesize", "8192", "-D", "/dev/stderr",
         "-H", "content-type: application/grpc", "-H", "te: trailers", "--data-binary", "@-",
         "http://127.0.0.1:18143/tari.rpc.Wallet/GetCompleteAddress"],
        input=b"\x00" * 5, capture_output=True, timeout=7, check=True,
    )
    if not re.search(rb"grpc-status:\s*0\b", response.stderr, re.I):
        raise ValueError("gRPC did not succeed")
    frame = response.stdout
    if len(frame) < 5 or frame[0] or int.from_bytes(frame[1:5], "big") != len(frame) - 5:
        raise ValueError("invalid gRPC frame")
    data, pos, addresses, keys = frame[5:], 0, [], []
    while pos < len(data):
        tag, pos = varint(data, pos)
        if tag & 7 != 2:
            raise ValueError("unexpected address field")
        length, pos = varint(data, pos)
        value = data[pos:pos + length]
        if len(value) != length:
            raise ValueError("truncated address")
        pos += length
        if tag >> 3 in (3, 4, 5, 6):
            addresses.append(value.decode("utf-8"))
        elif tag >> 3 in (1, 2):
            if len(value) == 35:
                keys.append((value[:1] + value[2:34]).hex())
            elif 67 <= len(value) <= 323:
                keys.append((value[:1] + value[2:66]).hex())
    if not addresses:
        raise ValueError("no wallet address")
    print("match" if os.environ["TARI_EXPECTED_ADDRESS"] in addresses or
          os.environ["TARI_EXPECTED_KEY"] in keys else "mismatch")
except (OSError, subprocess.SubprocessError, ValueError):
    print("unreachable")
PY
    )
    case "$verdict" in
    match) dr_ok "Tari payout wallet gRPC answers and its address matches tari.wallet_address." ;;
    mismatch) dr_warn_surface "Tari payout wallet gRPC answers, but its address differs from tari.wallet_address — check the view and public spend keys." "Tari payout wallet scans an address other than the configured payout target." ;;
    *) dr_warn_surface "Tari payout wallet gRPC did not answer — payout tracking is unavailable." "Tari payout wallet is not answering gRPC." ;;
    esac
    return 0
}
