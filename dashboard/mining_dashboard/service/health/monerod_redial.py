import asyncio
import logging
import time

from mining_dashboard.collector.containers import get_container_health

logger = logging.getLogger("MonerodRedial")

CHECK_INTERVAL_SEC = 60
REDIAL_SETTLE_SEC = 300
WATCHDOG_GRACE_SEC = 300
PEERS_BACK_SEC = 600
COOLDOWN_SEC = 30 * 60
DAILY_CAP = 3
DAY_SEC = 24 * 60 * 60
MONEROD_STOP_GRACE_SEC = 60
MONEROD_STOP_REQUEST_TIMEOUT_SEC = 90
MONEROD_START_REQUEST_TIMEOUT_SEC = 60
MONEROD_START_ATTEMPTS = 3
MONEROD_START_RETRY_DELAY_SEC = 5
TOR_PROVEN_SEC = 5 * 60
STALL_RESTART_SEC = 10 * 60
STALL_SYNC_SEC = 30 * 60
SYNC_GAP_BLOCKS = 72
PEER_GAP_SEC = 90

_REASON_TEXT = {
    "tor-start": "Tor restarted and monerod has no peers",
    "peerless": "no outgoing peers beyond the health bound",
}


class MonerodRestartBudget:
    def __init__(self):
        self._restarts = []
        self._warned_cap = False

    def allow(self, now):
        self._restarts = [t for t in self._restarts if now - t < DAY_SEC]
        if len(self._restarts) >= DAILY_CAP:
            return False
        return not self._restarts or now - self._restarts[-1] >= COOLDOWN_SEC

    def spend(self, now):
        self._restarts.append(now)
        self._warned_cap = False

    def count(self):
        return len(self._restarts)

    def warn_cap(self):
        if len(self._restarts) >= DAILY_CAP and not self._warned_cap:
            self._warned_cap = True
            logger.warning(
                "monerod restarts are held: all %d automatic restarts in 24 hours are spent; "
                "no more automatic action. Check Tor with './pithead tor-recover check' and "
                "restart monerod by hand: './pithead restart monerod'.",
                DAILY_CAP,
            )

    async def cycle_after_tor_restart(self, docker, now):
        if not self.allow(now):
            self.warn_cap()
            logger.info(
                "Tor restarted; the monerod re-dial is held by the shared monerod restart "
                "budget (#4076)."
            )
            return
        self.spend(now)
        logger.warning(
            "Restarting monerod alongside tor so it re-dials its peers through the fresh Tor (#972)."
        )
        m_stopped = await docker.stop(
            "monerod",
            stop_timeout=MONEROD_STOP_GRACE_SEC,
            request_timeout=MONEROD_STOP_REQUEST_TIMEOUT_SEC,
        )
        m_started = await docker.start("monerod", request_timeout=MONEROD_START_REQUEST_TIMEOUT_SEC)
        if not (m_stopped and m_started):
            logger.warning(
                "monerod restart alongside tor could not be issued; if the node stays out of "
                "sync, restart it manually: './pithead restart monerod' (#972)."
            )


class MonerodRedial:
    def __init__(self, docker_control, audit=None, enabled=True, clock=time.monotonic, budget=None):
        self.enabled = enabled
        self._docker = docker_control
        self._audit = audit
        self._clock = clock
        self._budget = budget if budget is not None else MonerodRestartBudget()
        self._last_check = None
        self._tor_started = None
        self._monerod_started = None
        self._pending_tor_start = None
        self._peers_since = None
        self._was_synced = False
        self._settle_since = None
        self._peerless_since = None
        self._circuit_since = None
        self._stall_accum = 0.0
        self._stall_open = None
        self._peer_gap_since = None
        self._stall_height = None

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
            logger.warning("monerod re-dial cycle failed (%s)", type(exc).__name__)

    async def _cycle(self, now, verdict) -> None:
        states = await get_container_health()
        tor = states.get("tor", {})
        monerod = states.get("monerod", {})
        tor_started = tor.get("started_at")
        if tor_started is not None:
            if self._tor_started is not None and tor_started > self._tor_started:
                self._pending_tor_start = tor_started
                self._circuit_since = None
            self._tor_started = tor_started
        if not monerod.get("running"):
            self._reset_clocks()
            self._pending_tor_start = None
            return
        peers = verdict.get("peers_out") if verdict.get("peers_visible") else None
        monerod_started = monerod.get("started_at")
        if monerod_started != self._monerod_started:
            self._monerod_started = monerod_started
            self._settle_since = None
            self._reset_clocks()
            self._stall_height = None
            self._was_synced = False
        if verdict.get("height") and not verdict.get("syncing"):
            self._was_synced = True
        tor_ready = bool(tor.get("running")) and tor.get("health") == "healthy"
        if not tor_ready:
            self._reset_clocks()
            return
        if verdict.get("peerless"):
            self._peerless_since = self._peerless_since if self._peerless_since is not None else now
        else:
            self._peerless_since = None
        if peers:
            self._peers_since = self._peers_since if self._peers_since is not None else now
            if now - self._peers_since >= PEERS_BACK_SEC:
                self._pending_tor_start = None
        else:
            self._peers_since = None
        if self._pending_tor_start is not None and peers == 0:
            self._settle_since = self._settle_since if self._settle_since is not None else now
        else:
            self._settle_since = None
        if self._settle_since is not None and now - self._settle_since >= REDIAL_SETTLE_SEC:
            await self._restart(now, "tor-start")
        elif self._peerless_since is not None and now - self._peerless_since >= WATCHDOG_GRACE_SEC:
            await self._restart(now, "peerless")
        else:
            await self._stall(now, verdict, peers, tor)

    async def _stall(self, now, verdict, peers, tor) -> None:
        circuit = tor.get("circuit")
        if circuit is True:
            if self._circuit_since is None:
                self._circuit_since = now
        else:
            self._circuit_since = None
        proven = self._circuit_since is not None and now - self._circuit_since >= TOR_PROVEN_SEC
        height = verdict.get("height")
        target = verdict.get("target_height")
        if height is not None:
            if self._stall_height is not None and height > self._stall_height:
                self._reset_stall_clocks()
            self._stall_height = height
        behind = bool(height) and bool(target) and target > height
        if not proven or not behind:
            self._reset_stall_clocks()
            return
        if not self._was_synced or target - height > SYNC_GAP_BLOCKS:
            threshold = STALL_SYNC_SEC
        else:
            threshold = STALL_RESTART_SEC
        if peers:
            if self._peer_gap_since is not None:
                if now - self._peer_gap_since >= PEER_GAP_SEC:
                    self._stall_accum = 0.0
                self._peer_gap_since = None
            if self._stall_open is None:
                self._stall_open = now
            if self._stall_accum + (now - self._stall_open) >= threshold:
                detail = (
                    f"height {height} unchanged while target {target}; "
                    f"peers_out {peers}, peers_in {verdict.get('peers_in')}"
                )
                await self._restart(now, "stalled", detail)
        elif self._peer_gap_since is None:
            self._peer_gap_since = now
            if self._stall_open is not None:
                self._stall_accum += now - self._stall_open
                self._stall_open = None

    def _reset_clocks(self):
        self._settle_since = None
        self._peers_since = None
        self._circuit_since = None
        self._peerless_since = None
        self._reset_stall_clocks()

    def _reset_stall_clocks(self):
        self._stall_accum = 0.0
        self._stall_open = None
        self._peer_gap_since = None

    async def _restart(self, now, reason, detail="") -> None:
        if not self._budget.allow(now):
            self._budget.warn_cap()
            return
        self._budget.spend(now)
        self._pending_tor_start = None
        self._reset_clocks()
        logger.warning(
            "Restarting monerod to re-dial its peers through Tor (%s, %d/%d in 24 hours).",
            detail or _REASON_TEXT[reason],
            self._budget.count(),
            DAILY_CAP,
        )
        stopped = await self._docker.stop(
            "monerod",
            stop_timeout=MONEROD_STOP_GRACE_SEC,
            request_timeout=MONEROD_STOP_REQUEST_TIMEOUT_SEC,
        )
        started = False
        for attempt in range(MONEROD_START_ATTEMPTS):
            if attempt:
                await asyncio.sleep(MONEROD_START_RETRY_DELAY_SEC)
            started = await self._docker.start(
                "monerod", request_timeout=MONEROD_START_REQUEST_TIMEOUT_SEC
            )
            if started:
                break
        if not (stopped and started):
            logger.warning(
                "monerod restart could not be fully issued; if the node stays peerless, run "
                "'./pithead restart monerod'."
            )
        if self._audit is not None:
            audit_reason = f"{reason}: {detail}" if detail else reason
            await self._audit(audit_reason, "applied" if stopped and started else "failed")
