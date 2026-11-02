import json
import os
import selectors
import subprocess
import time
from collections import Counter

from dashboard_wizard_io import _callback, _line, _send

from mining_dashboard import go_channel

# ruff: noqa: S603

CALLBACKS = Counter()


def run(payload):
    env = os.environ.copy()
    env["PITHEAD_DASHBOARD_HELPER"] = "wizard-values"
    process = subprocess.Popen(
        [go_channel.binary()],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    deadline = time.monotonic() + 30
    reader = selectors.DefaultSelector()
    writer = selectors.DefaultSelector()
    try:
        os.set_blocking(process.stdout.fileno(), False)
        os.set_blocking(process.stdin.fileno(), False)
        reader.register(process.stdout, selectors.EVENT_READ)
        writer.register(process.stdin, selectors.EVENT_WRITE)
        _send(process, writer, json.dumps(payload).encode() + b"\n", deadline)
        buffer = bytearray()
        while True:
            raw = _line(process, reader, buffer, deadline)
            response = json.loads(raw)
            if "event" not in response:
                process.stdin.close()
                process.wait(timeout=max(0.01, deadline - time.monotonic()))
                if process.returncode != 0:
                    raise RuntimeError("native wizard values callback helper failed")
                return go_channel.response("wizard-values", raw)
            CALLBACKS[response["event"]] += 1
            _send(process, writer, json.dumps(_callback(response)).encode() + b"\n", deadline)
    finally:
        reader.close()
        writer.close()
        if process.poll() is None:
            process.kill()
        process.wait()
        for stream in (process.stdin, process.stdout, process.stderr):
            stream.close()
