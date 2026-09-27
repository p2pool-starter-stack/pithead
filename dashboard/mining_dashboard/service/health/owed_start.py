"""A start owed to a container this dashboard stopped (#2464), kept on disk across its restarts.

A health restart is stop, then start. When the start fails, or the dashboard itself restarts between
the two, the container stays stopped by this code, and an in-memory retry would die with the
process. So the record is written, atomically, *before* the stop, and removed once a start lands or
turns out to be moot; a restarted dashboard picks the retry up where it left off.

It holds the stop time on the host clock, the one Docker's ``State.StartedAt`` uses. A container
running, or started by anyone since that stop, owes nothing, so a start from here never overrides
an operator's start-then-stop, and it never stops anything. Only a container still stopped since
this code stopped it is started, and at most ``retries`` times (None: until it runs).

A record that cannot be written is reported to the caller, which must then not stop anything: a stop
with no durable record is exactly the stranding this exists to prevent. A spent retry that cannot be
recorded is still counted in memory, so the limit holds within the process.

A stop whose result was an error is not proof it did not land (a lost acknowledgement), so the
record stays and the container's own state decides. A container still running within ``grace``
seconds of the stop may still be stopping, so it stays owed; after that, running means the stop did
not land and nothing is owed.
"""

import json
import logging
import os
import time

from mining_dashboard.collector.containers import container_started

logger = logging.getLogger("OwedStart")


def write_atomic(path, text):
    """Readers see the old file or the whole new one, never an empty or partial one."""
    tmp = f"{path}.tmp"
    with open(tmp, "w") as fh:
        fh.write(text)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


class OwedStart:
    def __init__(self, state_dir, container, retries=None, inspect=container_started, grace=0):
        self._path = os.path.join(state_dir, f"{container}-start-owed")
        self.container = container
        self._retries = retries
        self._inspect = inspect
        self._grace = grace
        self._left = None  # the lowest count this process has spent to, whatever the file says
        self._failing = False  # a write failure already reported: log once per streak

    def pending(self) -> bool:
        return os.path.exists(self._path)

    def stopping(self) -> bool:
        """Within ``grace`` of the recorded stop: a container that answers may still be stopping."""
        try:
            return time.time() - self._read()[0] < self._grace
        except OSError:
            return False

    def owe(self) -> bool:
        """Record the stop about to be issued. False when the record did not reach the disk: the
        caller must not stop the container."""
        self._left = None
        return self._write({"stopped_at": time.time(), "retries": self._retries})

    def settle(self):
        try:
            os.remove(self._path)
        except FileNotFoundError:
            pass
        except OSError as exc:
            logger.warning("Could not remove %s: %s", self._path, exc)

    def _write(self, record) -> bool:
        try:
            write_atomic(self._path, json.dumps(record))
        except OSError as exc:
            if not self._failing:
                logger.warning("Could not record the start owed to %s: %s", self.container, exc)
            self._failing = True
            return False
        if self._failing:
            logger.info("The start owed to %s is recorded again.", self.container)
        self._failing = False
        return True

    def _read(self):
        try:
            with open(self._path) as fh:
                record = json.load(fh)
            return float(record["stopped_at"]), record["retries"]
        except (OSError, ValueError, TypeError, KeyError):
            # Unreadable: the file's own age stands in for the stop time, and one start is owed.
            return os.path.getmtime(self._path), 1

    async def retry(self, docker) -> str:
        """``"started"``; ``"stop_missed"`` (running throughout: the stop never landed, nothing
        owed); ``"start_settled"`` (started by someone since the stop: nothing owed); ``"start_pending"`` (still owed, or the container's state was unreadable); or
        ``"start_gave_up"`` (no retries left: the record stays, so the advice does)."""
        try:
            stopped_at, left = self._read()
        except OSError:
            return "start_settled"  # settled between pending() and here
        state = await self._inspect(self.container)
        if state is None:
            return "start_pending"
        running, started_at = state
        if running and started_at <= stopped_at:
            if time.time() - stopped_at < self._grace:
                return "start_pending"  # the stop may still be landing
            self.settle()
            return "stop_missed"  # running since before the stop, past its grace: it never landed
        if running or started_at > stopped_at:
            self.settle()
            return "start_settled"
        if left is not None and self._left is not None:
            left = min(left, self._left)
        if left is not None and left <= 0:
            return "start_gave_up"
        if left is not None:
            left = self._left = left - 1
            self._write({"stopped_at": stopped_at, "retries": left})
        if await docker.start(self.container, request_timeout=60):
            self.settle()
            return "started"
        return "start_gave_up" if left == 0 else "start_pending"
