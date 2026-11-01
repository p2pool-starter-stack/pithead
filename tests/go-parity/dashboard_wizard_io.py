import json
import os
import selectors
import subprocess
import time
from collections import Counter

from mining_dashboard import go_channel

# ruff: noqa: S603

CALLBACKS = Counter()


def run(payload, data=None):
    env = os.environ.copy()
    env["PITHEAD_DASHBOARD_HELPER"] = "wizard" if data is None else "wizard-write"
    if data is not None:
        payload = {**payload, "length": len(data)}
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
        if data is not None:
            _send(process, writer, data, deadline)
        buffer = bytearray()
        while True:
            raw = _line(process, reader, buffer, deadline)
            response = json.loads(raw)
            if "event" not in response:
                process.stdin.close()
                process.wait(timeout=max(0.01, deadline - time.monotonic()))
                if process.returncode != 0:
                    raise RuntimeError("native wizard callback helper failed")
                return go_channel.response("wizard", raw)
            _send(process, writer, json.dumps(_callback(response)).encode() + b"\n", deadline)
    finally:
        reader.close()
        writer.close()
        if process.poll() is None:
            process.kill()
        process.wait()
        for stream in (process.stdin, process.stdout, process.stderr):
            stream.close()


def _send(process, selector, data, deadline):
    pending = memoryview(data)
    while pending:
        if not selector.select(max(0, deadline - time.monotonic())):
            raise RuntimeError("native wizard callback helper timed out")
        try:
            written = os.write(process.stdin.fileno(), pending[:65536])
        except BlockingIOError:
            continue
        pending = pending[written:]


def _line(process, selector, buffer, deadline):
    while b"\n" not in buffer:
        if not selector.select(max(0, deadline - time.monotonic())):
            raise RuntimeError("native wizard callback helper timed out")
        try:
            chunk = os.read(process.stdout.fileno(), 65536)
        except BlockingIOError:
            continue
        if not chunk:
            raise RuntimeError("native wizard callback helper exited")
        buffer.extend(chunk)
        if len(buffer) > 1 << 20:
            raise RuntimeError("native wizard callback helper returned oversized data")
    index = buffer.index(b"\n")
    line = bytes(buffer[:index])
    del buffer[: index + 1]
    return line


def _callback(event):
    CALLBACKS[event["event"]] += 1
    try:
        if event["event"] == "replace":
            os.replace(event["source"], event["destination"])
        elif event["event"] == "unlink":
            os.unlink(event["path"])
        else:
            raise RuntimeError("unsupported wizard I/O callback")
    except OSError as error:
        return {"ok": False, "error": {"message": str(error), "errno": error.errno or 0}}
    return {"ok": True}
