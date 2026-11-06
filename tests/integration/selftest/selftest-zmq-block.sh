#!/usr/bin/env bash
set -euo pipefail
echo "== real ZMQ block notification observation =="
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$HERE/.." <<'PY'
import json
from pathlib import Path
import socket
import subprocess
import sys
import threading
import time

root = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(root / "fakes"))
from fake_zmq_publisher import GREETING, READY, SUB_READY, read_exact

payload = {"first_height": 42, "first_prev_id": "a" * 64, "ids": ["b" * 64]}
topic = b"json-minimal-chain_main:"
valid = topic + json.dumps(payload).encode()


def frame(body, long=False, flags=0):
    if long or len(body) > 255:
        return bytes([flags | 2]) + len(body).to_bytes(8, "big") + body
    return bytes([flags, len(body)]) + body


def observe(label, wire, expected, hold=False, greeting=GREETING, ready=READY):
    errors = []
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(2)
        listener.settimeout(5)
        port = listener.getsockname()[1]

        def serve():
            stage = "accept"
            try:
                with listener.accept()[0]:
                    pass
                with listener.accept()[0] as client:
                    client.settimeout(5)
                    stage = "greeting"
                    assert read_exact(client, 64) == GREETING
                    client.sendall(greeting)
                    stage = "READY"
                    assert read_exact(client, 27) == SUB_READY
                    client.sendall(ready)
                    stage = "SUBSCRIBE"
                    assert read_exact(client, 26) == b"\x00\x18\x01json-minimal-chain_main"
                    client.sendall(wire)
                    if hold:
                        time.sleep(2.3)
            except Exception as exc:
                errors.append((stage, repr(exc)))

        worker = threading.Thread(target=serve)
        worker.start()
        script = '''
set -uo pipefail
source "$1/lib.sh"
source "$1/lib/zmq-probe.sh"
source "$1/lib/zmq-block.sh"
IT_MODE=local IT_REMOTE_DIR="$1"
zmq_block_probe 127.0.0.1 "$2" 2
'''
        start = time.monotonic()
        result = subprocess.run(
            ["bash", "-c", script, "probe", str(root), str(port)],
            text=True, capture_output=True, timeout=8,
        )
        worker.join(6)
        assert not worker.is_alive(), label + ": fixture still running"
        assert not errors, (label, errors, result)
        assert (result.returncode == 0) == expected, (label, result)
        assert time.monotonic() - start < 7, label + ": exceeded observation bound"
        print("PASS:", label)


observe("short block", frame(valid), True)
observe("long block", frame(valid, long=True), True)
other = frame(b'json-minimal-txpool_add:[]')
observe("unrelated then block", other + frame(valid), True)
observe("only unrelated traffic", other * 10, False)
observe("silent publisher", b"", False, hold=True)
observe("partial header", b"\x00", False, hold=True)
observe("partial long header", b"\x02\x00\x00", False)
observe("partial body", b"\x00\xff" + valid[:10], False, hold=True)
observe("multipart block", frame(valid, flags=1), False)
observe("command is not block data", frame(valid, flags=4), False)
observe("invalid flags", frame(valid, flags=8), False)
observe("oversized frame", b"\x02" + (65537).to_bytes(8, "big"), False)
observe("overflow length", b"\x02" + b"\xff" * 8, False)
observe("empty frame", b"\x00\x00", False)
observe("invalid JSON", frame(topic + b"{"), False)
observe("multiple JSON values", frame(valid + b" {}"), False)
observe("NUL in payload", frame(valid[:24] + b"\0" + valid[24:]), False)
observe("topic prefix decoy", frame(b"json-minimal-chain_main_extra:" + valid), False)
observe("nonpublisher", frame(valid), False, ready=SUB_READY)
observe("invalid greeting", frame(valid), False, greeting=b"\0" * 64)
for key, bad in [
    ("first_height", -1), ("first_height", 1.5), ("first_height", "42"),
    ("first_prev_id", "bad"), ("first_prev_id", "a" * 64 + "\n"),
    ("ids", []), ("ids", ["bad"]), ("ids", None),
]:
    changed = dict(payload, **{key: bad})
    observe(f"reject {key}={bad!r}", frame(topic + json.dumps(changed).encode()), False)

script = '''
set -uo pipefail
source "$1/lib.sh"
source "$1/lib/zmq-probe.sh"
source "$1/lib/zmq-block.sh"
rx() { printf '%s\n' 'BLOCK valid'; return 255; }
zmq_block_probe 127.0.0.1 1 1
'''
result = subprocess.run(["bash", "-c", script, "probe", str(root)], capture_output=True)
assert result.returncode != 0, "failed transport accepted output"
print("PASS: failed transport rejects valid-looking output")
script = r'''
set -uo pipefail
source "$1/lib/zmq-block.sh"
zmq_block_probe() { return "$probe_rc"; }
it_pass() { echo "PASS: $1"; }
it_fail() { echo "FAIL: $1"; }
it_skip_leg() { exit 99; }
probe_rc=0
assert_zmq_block fixture 1
probe_rc=1
assert_zmq_block fixture 1
'''
result = subprocess.run(["bash", "-c", script, "assertion", str(root)],
                        text=True, capture_output=True, check=True)
assert result.stdout.splitlines() == [
    "PASS: monero ZMQ published frame is a BLOCK notification",
    "FAIL: monero ZMQ published frame is a BLOCK notification",
], result
print("PASS: block assertion records positive coverage or failure, never a skip")
PY
