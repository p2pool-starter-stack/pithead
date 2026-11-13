import logging
import time

from mining_dashboard.collector.containers import get_container_health

logger = logging.getLogger("MonerodRedial")

CHECK_INTERVAL_SEC = 60
REDIAL_SETTLE_SEC = 120
WATCHDOG_GRACE_SEC = 300
COOLDOWN_SEC = 30 * 60
DAILY_CAP = 3
DAY_SEC = 24 * 60 * 60
MONEROD_STOP_GRACE_SEC = 60
MONEROD_STOP_REQUEST_TIMEOUT_SEC = 90
MONEROD_START_REQUEST_TIMEOUT_SEC = 60


class MonerodRedial:
    def __init__(self, docker_control, audit=None, enabled=True, clock=time.monotonic):
        self.enabled = enabled
        self._docker = docker_control
        self._audit = audit
        self._clock = clock
        self._last_check = None
        self._tor_started = None
        self._pending_tor_start = None
        self._settle_since = None
        self._peerless_since = None
        self._restarts = []
        self._warned_cap = False

    async def check(self, verdict) -> None:
        if not self.enabled:
            return
        now = self._clock()
        if self._last_check is not None and now - self._last_check < CHECK_INTERVAL_SEC:
            return
        self._last_check = now
        try:
            await self._cycle(now, verdict or {})
        except Exception as exc:
            logger.debug("monerod re-dial cycle failed (%s)", type(exc).__name__)

    async def _cycle(self, now, verdict) -> None:
        states = await get_container_health()
        tor = states.get("tor", {})
        monerod = states.get("monerod", {})
        tor_started = tor.get("started_at")
        if tor_started is not None:
            if self._tor_started is not None and tor_started > self._tor_started:
                self._pending_tor_start = tor_started
            self._tor_started = tor_started
        if not monerod.get("running"):
            self._reset_clocks()
            self._pending_tor_start = None
            return
        peers = verdict.get("peers_out") if verdict.get("peers_visible") else None
        if peers:
            self._pending_tor_start = None
        if (monerod.get("started_at") or 0) >= (self._pending_tor_start or float("inf")):
            self._pending_tor_start = None
        tor_ready = bool(tor.get("running")) and tor.get("health") == "healthy"
        if not tor_ready:
            self._reset_clocks()
            return
        if self._pending_tor_start is not None and peers == 0:
            self._settle_since = self._settle_since if self._settle_since is not None else now
        else:
            self._settle_since = None
        if verdict.get("peerless"):
            self._peerless_since = self._peerless_since if self._peerless_since is not None else now
        else:
            self._peerless_since = None
        if self._settle_since is not None and now - self._settle_since >= REDIAL_SETTLE_SEC:
            await self._restart(now, "tor-start")
        elif self._peerless_since is not None and now - self._peerless_since >= WATCHDOG_GRACE_SEC:
            await self._restart(now, "peerless")

    def _reset_clocks(self):
        self._settle_since = None
        self._peerless_since = None

    async def _restart(self, now, reason) -> None:
        self._restarts = [t for t in self._restarts if now - t < DAY_SEC]
        if len(self._restarts) >= DAILY_CAP:
            if not self._warned_cap:
                self._warned_cap = True
                logger.warning(
                    "monerod is still peerless after %d automatic restarts in 24 hours; no more "
                    "automatic action. Check Tor with './pithead tor-recover check' and restart "
                    "monerod by hand: './pithead restart monerod'.",
                    DAILY_CAP,
                )
            return
        if self._restarts and now - self._restarts[-1] < COOLDOWN_SEC:
            return
        self._restarts.append(now)
        self._warned_cap = False
        self._pending_tor_start = None
        self._reset_clocks()
        logger.warning(
            "Restarting monerod to re-dial its peers through Tor (%s, %d/%d in 24 hours).",
            "Tor restarted and monerod has no peers"
            if reason == "tor-start"
            else "no outgoing peers beyond the health bound",
            len(self._restarts),
            DAILY_CAP,
        )
        stopped = await self._docker.stop(
            "monerod",
            stop_timeout=MONEROD_STOP_GRACE_SEC,
            request_timeout=MONEROD_STOP_REQUEST_TIMEOUT_SEC,
        )
        started = await self._docker.start(
            "monerod", request_timeout=MONEROD_START_REQUEST_TIMEOUT_SEC
        )
        if not (stopped and started):
            logger.warning(
                "monerod restart could not be fully issued; if the node stays peerless, run "
                "'./pithead restart monerod'."
            )
        if self._audit is not None:
            await self._audit(reason, "applied" if stopped and started else "failed")
