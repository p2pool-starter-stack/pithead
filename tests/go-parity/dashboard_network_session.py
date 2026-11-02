import atexit
import json
import os
import selectors
import subprocess
import threading
import time

from mining_dashboard import go_channel

# ruff: noqa: S603


class NetworkSession:
    def __init__(self, binary, root, timeout=10, reply_limit=4 << 20):
        self._binary = binary
        self._root = root
        self._lock = threading.Lock()
        self._closed = False
        self._process = None
        self._selector = None
        self._buffer = bytearray()
        self._timeout = timeout
        self._reply_limit = reply_limit
        try:
            self._start_locked()
        except Exception:
            self._stop_child_locked()
            raise
        atexit.register(self.close)

    def call(self, payload):
        with self._lock:
            if self._closed:
                raise RuntimeError("native network helper is closed")
            if self._process is None:
                self._start_locked()
            try:
                output = self._exchange(payload)
            except Exception:
                self._stop_child_locked()
                raise
            try:
                return go_channel.response("network", output)
            except Exception:
                try:
                    reply = json.loads(output)
                except (TypeError, ValueError):
                    reply = None
                if type(reply) is not dict or type(reply.get("ok")) is not bool or reply["ok"]:
                    self._stop_child_locked()
                raise

    def close(self):
        with self._lock:
            self._closed = True
            self._stop_child_locked()

    def _start_locked(self):
        env = os.environ.copy()
        env["PITHEAD_DASHBOARD_HELPER"] = "network-stream"
        self._process = subprocess.Popen(
            [self._binary],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=self._root,
            env=env,
            start_new_session=True,
            bufsize=0,
        )
        self._selector = selectors.DefaultSelector()
        if self._process.stdout is None:
            raise RuntimeError("native network helper has no output pipe")
        self._selector.register(self._process.stdout, selectors.EVENT_READ)

    def _exchange(self, payload):
        process = self._process
        selector = self._selector
        if process is None or selector is None or process.stdin is None or process.stdout is None:
            raise RuntimeError("native network helper is not running")
        encoded = json.dumps(payload, allow_nan=False).encode()
        try:
            process.stdin.write(encoded + b"\n")
            process.stdin.flush()
        except (BrokenPipeError, OSError) as error:
            raise RuntimeError("native network helper stopped") from error
        deadline = time.monotonic() + self._timeout
        while True:
            if len(self._buffer) > self._reply_limit:
                raise RuntimeError("native network helper reply exceeds size limit")
            if newline := self._buffer.find(b"\n") + 1:
                line = bytes(self._buffer[:newline])
                del self._buffer[:newline]
                return line.decode()
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not selector.select(timeout=remaining):
                raise RuntimeError("native network helper timed out")
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError("native network helper stopped")
            self._buffer.extend(chunk)

    def _stop_child_locked(self):
        process, selector = self._process, self._selector
        self._process = None
        self._selector = None
        self._buffer.clear()
        if process is None:
            return
        if selector is not None:
            selector.close()
        if process.stdin is not None:
            try:
                process.stdin.close()
            except OSError:
                pass
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=1)
        for stream in (process.stdout, process.stderr):
            if stream is not None:
                stream.close()
