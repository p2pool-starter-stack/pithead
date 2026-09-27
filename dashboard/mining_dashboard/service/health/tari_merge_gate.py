"""Stop P2Pool's Tari merge-mining while the Tari verdict is red (#2464).

A red verdict means the node's tip is stale or on a dead branch, so every Tari block P2Pool builds
against it is wasted. Restarting the node (``tari_health``) is the fix when it works; when automatic
restart is off, withheld (a migration) or exhausted (a fork), the node can stay red for days. This
gate covers every one of those cases the same way: after :data:`SUPPRESS_AFTER_SEC` of red it writes
a marker the p2pool entrypoint reads, and restarts p2pool. The entrypoint then launches without
``--merge-mine``, so Monero mining carries on and only the Tari work stops.

It never touches the Tari node, so the node's own recovery (a restart, an operator's fix, peers
coming back) proceeds. Merge-mining resumes once the verdict has been green for
:data:`RESUME_AFTER_SEC` *and* the tip has risen past its height when suppression began. That
height is written into the marker, so a dashboard restart keeps it: a fresh verdict starts green
only because it has no history yet, and a node that recovers below the stale tip (a rewind, a reset)
has not caught up. A marker whose height cannot be read fails closed: no height stands in for it,
and only a green verdict measured against the public explorer resumes.

The marker proves only what the *next* launch will do. After every change, and after a dashboard
restart, the gate compares p2pool's ``StartedAt`` with the change: a p2pool running since before it
is still on the old flags and is restarted. A restart that could not be issued is retried the same
way, and a p2pool this gate stopped but could not start is owed a start on disk (``owed_start``).
p2pool is touched only while it is meant to be running: while the sync gate or fail-closed holds it,
only the marker changes, and the next start picks it up.
"""

import logging
import os
import time

from mining_dashboard.collector.containers import container_started
from mining_dashboard.service.health.owed_start import OwedStart, write_atomic
from mining_dashboard.service.health.tari_health import RED_SUSTAIN_SEC

logger = logging.getLogger("TariMergeGate")

MARKER = "tari-merge-mine-suppressed"  # read by build/p2pool/entrypoint.sh
RESUMED = "tari-merge-mine-resumed"  # when the marker went: a launch older than it still suppresses
SUPPRESS_AFTER_SEC = RED_SUSTAIN_SEC
RESUME_AFTER_SEC = 5 * 60
P2POOL = "p2pool"
STOP_REQUEST_SEC = 60


class TariMergeMineGate:
    def __init__(self, state_dir, docker_control, clock=time.monotonic, inspect=container_started):
        self._path = os.path.join(state_dir, MARKER)
        self._resumed = os.path.join(state_dir, RESUMED)
        self._docker = docker_control
        self._clock = clock
        self._inspect = inspect
        self._owed = OwedStart(state_dir, P2POOL, inspect=inspect, grace=STOP_REQUEST_SEC)
        self.suppressed = os.path.exists(self._path)
        self._at_height = self._read_height() if self.suppressed else None
        self._red_since = None
        self._green_since = None
        # Until p2pool is seen launched after the marker's last change. A restart starts unsure.
        self._launch_unconfirmed = self.suppressed or os.path.exists(self._resumed)

    def _read_height(self) -> int | None:
        try:
            with open(self._path) as fh:
                first = fh.readline().strip()
            height = int(first.split("=", 1)[1]) if first.startswith("height=") else None
        except (OSError, ValueError):
            return None
        return height if height is not None and height >= 0 else None  # a negative one is invalid

    def decide(self, level, now, height=None, explorer_tip=None):
        """``"suppress"``, ``"resume"`` or None for this cycle's verdict. Pure state + clock."""
        if level == "red":
            self._green_since = None
            if self._red_since is None:
                self._red_since = now
            if not self.suppressed and now - self._red_since >= SUPPRESS_AFTER_SEC:
                return "suppress"
            return None
        self._red_since = None
        if self._at_height is not None:
            advanced = height is not None and height > self._at_height
        else:  # no readable height: only the explorer, not the node's own view, says it caught up
            advanced = explorer_tip is not None
        # The resume window counts green only while it is evidence of catching up.
        if level != "green" or not (self.suppressed and advanced):
            self._green_since = None
            return None
        if self._green_since is None:
            self._green_since = now
        return "resume" if now - self._green_since >= RESUME_AFTER_SEC else None

    def _set_marker(self, on: bool, height=None) -> bool:
        try:
            if on:
                write_atomic(
                    self._path,
                    f"height={'' if height is None else height}\n"
                    "Tari verdict red: p2pool launches without --merge-mine (#2464)\n",
                )
                if os.path.exists(self._resumed):
                    os.remove(self._resumed)
            else:
                write_atomic(self._resumed, "merge-mining resumed (#2464)\n")
                os.remove(self._path)
            return True
        except OSError as exc:
            logger.warning("Could not %s %s: %s", "write" if on else "remove", self._path, exc)
            return False

    def _changed_at(self) -> float | None:
        try:
            return os.path.getmtime(self._path if self.suppressed else self._resumed)
        except OSError:
            return None

    async def _reconcile(self):
        """Bring p2pool's actual launch in line with the marker: start it if this gate stopped it,
        restart it if it has run since before the marker's last change. A start this gate issued
        after the change is proof enough; ``StartedAt`` is consulted only when nothing in this
        process launched it, so a host clock stepped back past the marker costs one restart."""
        if self._owed.pending():
            started = await self._owed.retry(self._docker)
            if started == "start_pending":
                return
            if started == "started":
                return self._confirmed()
        if not self._launch_unconfirmed:
            return
        changed, state = self._changed_at(), await self._inspect(P2POOL)
        if changed is None:
            return self._confirmed()
        if state is None:
            return  # unreadable: next cycle
        running, started_at = state
        if not running or started_at > changed:
            # Launched since the change, or stopped by someone else: its next start reads it.
            return self._confirmed()
        if not self._owed.owe():
            return  # no durable record, no stop: still unconfirmed, tried again next cycle
        if not await self._docker.stop(P2POOL, stop_timeout=30, request_timeout=STOP_REQUEST_SEC):
            # The acknowledgement may be what was lost: the record stays, and the owed-start retry
            # reads p2pool before anything is called reconciled. Running: restarted again.
            return
        if await self._docker.start(P2POOL, request_timeout=60):
            self._owed.settle()
            self._confirmed()

    def _confirmed(self):
        self._launch_unconfirmed = False
        if not self.suppressed and os.path.exists(self._resumed):
            try:
                os.remove(self._resumed)
            except OSError as exc:
                logger.warning("Could not remove %s: %s", self._resumed, exc)

    async def apply(self, verdict, p2pool_running):
        """Fold this cycle's verdict in, move the marker, and reconcile p2pool when it is meant to
        run. Returns ``"suppressed"`` or ``"on"`` for the panel and the stranded leg."""
        now = self._clock()
        height = verdict.get("height")
        action = self.decide(verdict.get("level"), now, height, verdict.get("explorer_tip"))
        if action and self._set_marker(action == "suppress", height):
            self.suppressed = action == "suppress"
            self._at_height = height if self.suppressed else None
            self._launch_unconfirmed = True
            logger.warning(
                "Tari merge-mining %s: %s.",
                "SUSPENDED" if self.suppressed else "resumed",
                "; ".join(verdict.get("reasons") or []) or "the node follows the chain again",
            )
        if p2pool_running:
            await self._reconcile()
        return "suppressed" if self.suppressed else "on"
