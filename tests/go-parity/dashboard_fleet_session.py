# ruff: noqa: S603

import atexit
import json
import os
import selectors
import subprocess
import threading


class JSONSession:
    def __init__(self, binary, repo_root, helper, warm_payload):
        self._binary = binary
        self._repo_root = repo_root
        self._helper = helper
        self._warm_payload = warm_payload
        self._lock = threading.Lock()
        self._closed = False
        self._process = None
        self._selector = None
        try:
            self._start_locked()
        except Exception:
            self._stop_child_locked()
            raise
        atexit.register(self.close)

    @property
    def pid(self):
        return self._process.pid if self._process is not None else None

    def run(self, payload):
        with self._lock:
            if self._closed:
                raise RuntimeError(f"Go {self._helper} helper is closed")
            try:
                if self._process is None:
                    self._start_locked()
                return self._exchange(payload)
            except Exception:
                self._stop_child_locked()
                raise

    def close(self):
        with self._lock:
            self._closed = True
            self._stop_child_locked()

    def _start_locked(self):
        env = os.environ.copy()
        env["PITHEAD_DASHBOARD_HELPER"] = self._helper
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
            raise RuntimeError(f"Go {self._helper} helper has no output pipe")
        self._selector.register(self._process.stdout, selectors.EVENT_READ)
        self._exchange(self._warm_payload)

    def _exchange(self, payload):
        process = self._process
        selector = self._selector
        if process is None or selector is None:
            raise RuntimeError(f"Go {self._helper} helper is not running")
        if process.stdin is None or process.stdout is None:
            raise RuntimeError(f"Go {self._helper} helper pipes are closed")
        encoded = json.dumps(payload, allow_nan=False, separators=(",", ":")).encode()
        try:
            process.stdin.write(encoded + b"\n")
            process.stdin.flush()
        except (BrokenPipeError, OSError) as exc:
            raise RuntimeError(f"Go {self._helper} helper stopped") from exc
        if not selector.select(timeout=10):
            raise RuntimeError(f"Go {self._helper} helper timed out")
        line = process.stdout.readline()
        if not line:
            raise RuntimeError(f"Go {self._helper} helper stopped")
        try:
            return json.loads(line)
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"Go {self._helper} helper returned invalid JSON") from exc

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
