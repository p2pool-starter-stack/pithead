import asyncio
import logging
import time
from collections import deque

from mining_dashboard.collector.containers import get_container_health

logger = logging.getLogger("P2PoolHeal")

ZERO_PEERS_AFTER_SEC = 15 * 60
REJOIN_WAIT_SEC = 20 * 60
MAX_REJOIN_WAIT_SEC = 80 * 60
MAX_RESTARTS_PER_DAY = 3
DAY_SEC = 24 * 60 * 60
P2POOL_STOP_GRACE_SEC = 30
P2POOL_STOP_REQUEST_TIMEOUT_SEC = 90
P2POOL_START_ATTEMPTS = 3
P2POOL_START_RETRY_DELAY_SEC = 5
P2POOL_LATE_START_CYCLES = 3
STATS_STALE_SEC = 120


class P2PoolPeerHealer:
    CONTAINER = "p2pool"

    def __init__(self, docker_control, audit=None, clock=time.monotonic):
        self._docker = docker_control
        self._audit = audit
        self._clock = clock
        self._zero_since = None
        self._restarts = deque()
        self._outage_restarts = 0
        self._next_allowed = None
        self._awaiting_tip = False
        self._tip_mark = None
        self._warned_cap = False
        self._uptime = None
        self._uptime_changed = None
        self._late_starts = 0

    async def check(self, p2pool_stats) -> None:
        try:
            await self._check(p2pool_stats)
        except Exception as exc:
            logger.warning("P2Pool heal cycle failed (%s)", type(exc).__name__)

    async def _check(self, p2pool_stats) -> None:
        now = self._clock()
        if self._late_starts:
            await self._retry_start()
        p2p = p2pool_stats.get("p2p", {})
        uptime = p2p.get("uptime")
        if not uptime:
            self._zero_since = None
            return
        if uptime != self._uptime:
            self._uptime = uptime
            self._uptime_changed = now
        elif now - self._uptime_changed >= STATS_STALE_SEC:
            self._zero_since = None
            return
        peers = (p2p.get("out_peers") or 0) + (p2p.get("in_peers") or 0)
        if peers > 0:
            self._zero_since = None
            self._observe_tip(p2pool_stats.get("pool", {}).get("sidechain_height"))
            return
        self._tip_mark = None
        if self._zero_since is None:
            self._zero_since = now
        if now - self._zero_since < ZERO_PEERS_AFTER_SEC:
            return
        if self._next_allowed is not None and now < self._next_allowed:
            return
        while self._restarts and now - self._restarts[0] >= DAY_SEC:
            self._restarts.popleft()
        if len(self._restarts) < MAX_RESTARTS_PER_DAY:
            self._warned_cap = False
        if len(self._restarts) >= MAX_RESTARTS_PER_DAY:
            if not self._warned_cap:
                self._warned_cap = True
                logger.warning(
                    "P2Pool still has no peers after %d automatic restarts in 24 hours. "
                    "No more automatic action; run './pithead doctor' and restart it with "
                    "'./pithead restart p2pool'.",
                    MAX_RESTARTS_PER_DAY,
                )
            return
        health = (await get_container_health()).get(self.CONTAINER)
        if not health or not health.get("running") or health.get("restarting"):
            self._zero_since = None
            return
        await self._restart(now, (now - self._zero_since) / 60)

    async def _retry_start(self) -> None:
        health = (await get_container_health()).get(self.CONTAINER)
        if not health or health.get("running") or health.get("restarting"):
            self._late_starts = 0
            return
        self._late_starts -= 1
        if await self._docker.start(self.CONTAINER, request_timeout=60):
            self._late_starts = 0
            logger.warning(
                "P2Pool started on a later cycle after the restart's start was unconfirmed."
            )

    def _observe_tip(self, height) -> None:
        if not self._awaiting_tip or not isinstance(height, int) or height <= 0:
            return
        if self._tip_mark is None:
            self._tip_mark = height
        elif height > self._tip_mark:
            logger.info(
                "P2Pool rejoined the sidechain after %d automatic restart(s): tip %d -> %d.",
                self._outage_restarts,
                self._tip_mark,
                height,
            )
            self._awaiting_tip = False
            self._tip_mark = None
            self._outage_restarts = 0
            self._next_allowed = None
            self._warned_cap = False

    async def _restart(self, now, outage_minutes) -> None:
        self._outage_restarts += 1
        self._restarts.append(now)
        wait = min(REJOIN_WAIT_SEC * 2 ** (self._outage_restarts - 1), MAX_REJOIN_WAIT_SEC)
        self._next_allowed = now + wait
        self._awaiting_tip = True
        self._tip_mark = None
        self._zero_since = None
        logger.warning(
            "P2Pool has had no peers for %.0f minutes. Restarting it (%d/%d in 24 hours); "
            "next restart no sooner than %d minutes if the sidechain tip does not resume.",
            outage_minutes,
            len(self._restarts),
            MAX_RESTARTS_PER_DAY,
            wait // 60,
        )
        stopped = await self._docker.stop(
            self.CONTAINER,
            stop_timeout=P2POOL_STOP_GRACE_SEC,
            request_timeout=P2POOL_STOP_REQUEST_TIMEOUT_SEC,
        )
        started = False
        for attempt in range(P2POOL_START_ATTEMPTS):
            if attempt:
                await asyncio.sleep(P2POOL_START_RETRY_DELAY_SEC)
            if await self._docker.start(self.CONTAINER, request_timeout=60):
                started = True
                break
        logger.warning(
            "P2Pool restart control results: stop=%s, start=%s.",
            "confirmed" if stopped else "unconfirmed",
            "confirmed" if started else "unconfirmed",
        )
        self._late_starts = 0 if started else P2POOL_LATE_START_CYCLES
        if self._audit is not None:
            await self._audit(
                "restart", "applied" if stopped and started else "unconfirmed", "p2pool"
            )
