# ruff: noqa: S603

import atexit
import json
import math
import os
import selectors
import subprocess
import threading
from pathlib import Path


class AverageSession:
    def __init__(self, binary: Path, repo_root: Path):
        self._lock = threading.Lock()
        self._closed = False
        self._binary = binary
        self._repo_root = repo_root
        self._process = None
        self._selector = None
        try:
            self._start_locked()
        except Exception:
            self._stop_child_locked()
            raise
        atexit.register(self.close)

    def run_average(self, history, window, now, xvb):
        payload = {"history": history, "window": window, "now": now, "xvb": xvb}
        with self._lock:
            if self._closed:
                raise RuntimeError("Go average helper is closed")
            try:
                if self._process is None:
                    self._start_locked()
                return self._validate(self._exchange(payload))
            except Exception:
                self._stop_child_locked()
                raise

    def close(self):
        with self._lock:
            self._closed = True
            self._stop_child_locked()

    def _start_locked(self):
        env = os.environ.copy()
        env["PITHEAD_DASHBOARD_HELPER"] = "average-stream"
        self._process = subprocess.Popen(
            [self._binary],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=self._repo_root,
            env=env,
            start_new_session=True,
        )
        self._selector = selectors.DefaultSelector()
        if self._process.stdout is None:
            raise RuntimeError("Go average helper has no output pipe")
        self._selector.register(self._process.stdout, selectors.EVENT_READ)
        value = self._exchange({"history": [], "window": 1, "now": 0, "xvb": False})
        self._validate(value)

    def _exchange(self, payload):
        process = self._process
        selector = self._selector
        if process is None or selector is None:
            raise RuntimeError("Go average helper is not running")
        if process.stdin is None or process.stdout is None:
            raise RuntimeError("Go average helper pipes are closed")
        encoded = json.dumps(payload, allow_nan=False, separators=(",", ":")).encode()
        try:
            process.stdin.write(encoded + b"\n")
            process.stdin.flush()
        except (BrokenPipeError, OSError) as exc:
            raise RuntimeError("Go average helper stopped") from exc
        if not selector.select(timeout=10):
            raise RuntimeError("Go average helper timed out")
        line = process.stdout.readline()
        if not line:
            raise RuntimeError("Go average helper stopped")
        try:
            return json.loads(line)
        except json.JSONDecodeError as exc:
            raise RuntimeError("Go average helper returned invalid JSON") from exc

    def _validate(self, value):
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(value)
        ):
            raise RuntimeError("Go average helper returned a non-number")
        return value

    def _stop_child_locked(self):
        process = self._process
        selector = self._selector
        self._process = None
        self._selector = None
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
