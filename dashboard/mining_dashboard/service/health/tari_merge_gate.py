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
has not caught up.

p2pool is restarted only while it is meant to be running. While the sync gate or fail-closed holds
it, only the marker changes, and the next start picks it up. A restart that could not be issued is
retried on the next cycle.
"""

import logging
import os
import time

from mining_dashboard.service.health.tari_health import RED_SUSTAIN_SEC

logger = logging.getLogger("TariMergeGate")

MARKER = "tari-merge-mine-suppressed"  # read by build/p2pool/entrypoint.sh
SUPPRESS_AFTER_SEC = RED_SUSTAIN_SEC
RESUME_AFTER_SEC = 5 * 60
P2POOL = "p2pool"


class TariMergeMineGate:
    def __init__(self, state_dir, docker_control, clock=time.monotonic):
        self._path = os.path.join(state_dir, MARKER)
        self._docker = docker_control
        self._clock = clock
        self.suppressed = os.path.exists(self._path)
        self._since = self._clock() if self.suppressed else None  # suppression start
        self._at_height = self._read_height() if self.suppressed else None
        self._red_since = None
        self._green_since = None
        self._restart_owed = False  # p2pool must restart to read the marker's current state

    def _read_height(self) -> int | None:
        try:
            with open(self._path) as fh:
                first = fh.readline().strip()
            return int(first.split("=", 1)[1]) if first.startswith("height=") else None
        except (OSError, ValueError):
            return None

    def decide(self, level, advanced_at, now, height=None):
        """``"suppress"``, ``"resume"`` or None for this cycle's verdict. Pure state + clock."""
        if level == "red":
            self._green_since = None
            if self._red_since is None:
                self._red_since = now
            if not self.suppressed and now - self._red_since >= SUPPRESS_AFTER_SEC:
                return "suppress"
            return None
        self._red_since = None
        if level != "green":
            self._green_since = None
            return None
        if self._green_since is None:
            self._green_since = now
        if self._at_height is not None:
            advanced = height is not None and height > self._at_height
        else:  # a marker without a height: fall back to any forward progress since suppression
            advanced = (
                advanced_at is not None and self._since is not None and advanced_at >= self._since
            )
        if self.suppressed and advanced and now - self._green_since >= RESUME_AFTER_SEC:
            return "resume"
        return None

    def _set_marker(self, on: bool, height=None) -> bool:
        try:
            if on:
                with open(self._path, "w") as fh:
                    fh.write(f"height={'' if height is None else height}\n")
                    fh.write("Tari verdict red: p2pool launches without --merge-mine (#2464)\n")
            elif os.path.exists(self._path):
                os.remove(self._path)
            return True
        except OSError as exc:
            logger.warning("Could not %s %s: %s", "write" if on else "remove", self._path, exc)
            return False

    async def apply(self, verdict, advanced_at, p2pool_running):
        """Fold this cycle's verdict in, move the marker, and restart p2pool when it is running.
        Returns ``"suppressed"`` or ``"on"`` for the panel and the stranded leg."""
        now = self._clock()
        height = verdict.get("height")
        action = self.decide(verdict.get("level"), advanced_at, now, height)
        if action and self._set_marker(action == "suppress", height):
            self.suppressed = action == "suppress"
            self._since = now if self.suppressed else None
            self._at_height = height if self.suppressed else None
            self._restart_owed = True
            logger.warning(
                "Tari merge-mining %s: %s.",
                "SUSPENDED" if self.suppressed else "resumed",
                "; ".join(verdict.get("reasons") or []) or "the node follows the chain again",
            )
        if self._restart_owed and p2pool_running:
            stopped = await self._docker.stop(P2POOL, stop_timeout=30, request_timeout=60)
            started = await self._docker.start(P2POOL, request_timeout=60)
            self._restart_owed = not (stopped and started)
        elif self._restart_owed:
            self._restart_owed = False  # held: the gate's own next start reads the marker
        return "suppressed" if self.suppressed else "on"
