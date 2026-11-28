import asyncio
import logging
import time
import uuid

import requests

from mining_dashboard.collector.containers import get_container_health
from mining_dashboard.config.config import (
    LOCAL_MONERO_HOST,
    MONERO_NODE_HOST,
    TOR_AUTO_HEAL,
    TOR_SOCKS_PROXY,
)
from mining_dashboard.helper.http import bounded_get, proxy_map, purpose_proxy
from mining_dashboard.service import control_service
from mining_dashboard.service.health.monerod_redial import MonerodRestartBudget
from mining_dashboard.service.health.tor_heal_exhausted import (
    COOLDOWN_SEC,
    EXHAUSTED_PROBE_SEC,
    MAX_DISRUPTIVE_PER_DAY,
    TorExhaustedMixin,
)
from mining_dashboard.service.health.tor_heal_history import TorHistoryMixin

logger = logging.getLogger("TorHeal")

PROBE_URL = "https://www.google.com/generate_204"
SECOND_PROBE_URL = "https://www.cloudflare.com/cdn-cgi/trace"
PROBE_TIMEOUT_SEC = 15

PROBE_INTERVAL_SEC = 5 * 60  # active probe cadence (only while the heal is enabled)
FIRST_ACTION_AFTER_SEC = 5 * 60
BROKEN_AFTER_SEC = 15 * 60
FAST_PROBE_SEC = 60
DISRUPTIVE_SPACING_SEC = 60 * 60
NEWNYM_ATTEMPTS = 2
MAX_ATTEMPTS = 4
DISRUPTIVE_WINDOW_SEC = 24 * 3600
RECOVERY_CONFIRM_PROBES = 2
# Tor's stop: SIGTERM, `t` seconds of grace, then SIGKILL. Docker holds the request open until the
# container is down, and a wedged Tor took over 60 s (#3032). The HTTP timeout outlasts grace + kill.
TOR_STOP_GRACE_SEC = 15
TOR_STOP_REQUEST_TIMEOUT_SEC = 120
# An API stop is not undone by `restart: unless-stopped`, so the heal must end with Tor running:
# an unconfirmed start is retried a bounded number of times (start is idempotent: 304 if running).
TOR_START_ATTEMPTS = 3
TOR_START_RETRY_DELAY_SEC = 5
# After an unconfirmed stop Docker may still be stopping Tor, and a start then answers 304 "already
# running" while Tor goes down behind it. Wait (bounded: grace + kill + slack) for it to read down.
TOR_SETTLE_SEC = 30
TOR_SETTLE_POLL_SEC = 5


class TorEgressHealer(TorExhaustedMixin, TorHistoryMixin):
    """Probe and recover Tor egress under a fixed cadence, cooldown and attempt cap."""

    HISTORY_TIMEOUT_SEC = PROBE_INTERVAL_SEC
    CONTAINER = "tor"
    MONEROD = "monerod"

    def __init__(
        self,
        docker_control,
        enabled=None,
        probe=None,
        notify=None,
        clock=time.monotonic,
        restart_monerod=None,
        ping_failing_since=None,
        monerod_budget=None,
    ):
        self.enabled = TOR_AUTO_HEAL if enabled is None else enabled
        if restart_monerod is None:
            restart_monerod = MONERO_NODE_HOST == LOCAL_MONERO_HOST
        self._restart_monerod = restart_monerod
        self._monerod_budget = monerod_budget or MonerodRestartBudget()
        self._docker = docker_control
        self._probe = probe or self._probe_egress
        self._notify = notify  # optional async callable(text) — the Telegram one-off
        self._clock = clock
        self._ping_failing_since = ping_failing_since
        self._last_probe = None  # probe-cadence throttle
        self._was_pinging_badly = False
        self._failing_since = None  # start of the current unbroken failure streak
        self._attempts = 0  # recovery actions spent on the current outage
        self._last_attempt = None  # cooldown anchor
        self._ok_streak = 0  # consecutive OK probes (sustained-recovery counter, post-restart)
        self._warned_exhausted = False
        self._exhausted_alerted_at = None
        self._past_cap = False
        self._disruptive = []
        self._pending_recovery = None
        self._tor_started = None  # last seen Tor container start (epoch); None until observed
        self._own_restart = False  # the healer restarted Tor since that reading
        self._recovery_notice = None
        self._pending_refresh = None
        self._pending_since = None
        self._failure_evidence = ""
        self._recovery_step = None
        self._newnym_unconfirmed = False
        self._guard_rotated = False
        self._newnym_retried = False
        self._history_since = None
        self._history_outage = None
        self._clear_history = False
        self._pending_history = None  # read-only tor-history request awaiting its result
        self._warned_saturated = False  # saturated-history alert is sent once per outage
        self.saturated_history = False
        self.circuits_wedged = False
        self.circuits_completing = False
        self._built_seen = None
        self._disruptive_round = False
        if self.enabled:
            logger.info(
                "Tor egress self-heal enabled: probing every %ds; first recovery after %dm "
                "broken, max %d attempts %dm apart.",
                PROBE_INTERVAL_SEC,
                FIRST_ACTION_AFTER_SEC // 60,
                MAX_ATTEMPTS,
                COOLDOWN_SEC // 60,
            )

    @staticmethod
    def _probe_egress() -> tuple[bool, str]:
        """Corroborate failures on separate SOCKS circuits and independent targets."""
        evidence = []
        for url in (PROBE_URL, SECOND_PROBE_URL):
            circuit = uuid.uuid4().hex
            try:
                proxy = purpose_proxy(TOR_SOCKS_PROXY, circuit)
                bounded_get(url, timeout=PROBE_TIMEOUT_SEC, proxies=proxy_map(proxy))
                evidence.append(f"{url}: circuit {circuit[:8]} answered")
                return True, "; ".join(evidence)
            except (requests.RequestException, ValueError) as exc:
                evidence.append(f"{url}: circuit {circuit[:8]} {type(exc).__name__}")
        return False, "; ".join(evidence)

    def decide(self, ok, now):
        if ok:
            if self._attempts == 0 and not self._newnym_unconfirmed and not self.saturated_history:
                self._failing_since = None
                self._ok_streak = 0
                return None
            self._ok_streak += 1
            if self._ok_streak < RECOVERY_CONFIRM_PROBES:
                return None
            self._failing_since = None
            self._attempts = 0
            self._last_attempt = None
            self._ok_streak = 0
            self._warned_exhausted = False
            self._guard_rotated = False
            self._exhausted_alerted_at = None
            self._past_cap = False
            return "recovered"
        self._ok_streak = 0
        if self._failing_since is None:
            hint = self._ping_failing_since() if self._ping_failing_since else None
            self._failing_since = hint if hint is not None and hint < now else now
        threshold = FIRST_ACTION_AFTER_SEC if self._attempts == 0 else BROKEN_AFTER_SEC
        if (now - self._failing_since) < threshold:
            return None
        if self._last_attempt is not None and (now - self._last_attempt) < COOLDOWN_SEC:
            return None
        if self._attempts >= MAX_ATTEMPTS:
            self._past_cap = True
            return "exhausted"
        if self._attempts >= NEWNYM_ATTEMPTS:
            self._disruptive = [t for t in self._disruptive if now - t < DISRUPTIVE_WINDOW_SEC]
            if len(self._disruptive) >= MAX_DISRUPTIVE_PER_DAY:
                self._past_cap = True
                return "exhausted"
            if self.circuits_completing:
                logger.warning("Tor circuits are completing; holding the next disruptive rung.")
                return None
            if self._disruptive and now - self._disruptive[-1] < DISRUPTIVE_SPACING_SEC:
                return None
            self._disruptive.append(now)
        self._attempts += 1
        self._last_attempt = now
        self._warned_exhausted = False
        self._exhausted_alerted_at = None
        self._past_cap = False
        return "heal"

    async def _observe_tor_start(self) -> None:
        started = (await get_container_health()).get(self.CONTAINER, {}).get("started_at")
        if started is None:
            return
        if self._tor_started is not None and started > self._tor_started and not self._own_restart:
            logger.info("Tor restarted outside the self-heal; starting a fresh outage window.")
            self._failing_since = None
            self._attempts = 0
            self._last_attempt = None
            self._ok_streak = 0
            self._warned_exhausted = False
            self._exhausted_alerted_at = None
            self._past_cap = False
            self._newnym_unconfirmed = False
            self._guard_rotated = False
            self._newnym_retried = False
            self.circuits_wedged = False
            self.circuits_completing = False
            self._built_seen = None
        self._tor_started = started
        self._own_restart = False

    def refund_attempt(self):
        if self._attempts > 0:
            self._attempts -= 1
        self._last_attempt = None

    async def _monerod_running(self) -> bool:
        """Only a running monerod is cycled (#2749). A stopped one stays stopped: with LAN access on
        a DIY Docker host it may be held because its LAN-only source rule is missing, and a start
        would publish its ports on 0.0.0.0 without it."""
        return bool((await get_container_health()).get(self.MONEROD, {}).get("running"))

    async def _wait_tor_down(self) -> None:
        """Poll until Tor reads not running, at most TOR_SETTLE_SEC (an in-flight stop settles)."""
        for _ in range(TOR_SETTLE_SEC // TOR_SETTLE_POLL_SEC):
            if not (await get_container_health()).get(self.CONTAINER, {}).get("running"):
                return
            await asyncio.sleep(TOR_SETTLE_POLL_SEC)

    async def _ensure_tor_running(self, stopped: bool) -> bool:
        """Start Tor after the stop, whatever the stop reported (#3032).

        A stop whose response is lost may still have stopped the container, and Docker leaves a
        stopped container down. Start it and retry an unconfirmed start, bounded. A "running"
        inspect is not trusted: after a timed-out stop it may predate the in-flight stop, and a 304
        to an early start would be answered by a container about to go down, so an unconfirmed
        stop is given time to settle before the start.
        """
        if not stopped:
            await self._wait_tor_down()
        for attempt in range(TOR_START_ATTEMPTS):
            if attempt:
                await asyncio.sleep(TOR_START_RETRY_DELAY_SEC)
            if await self._docker.start(self.CONTAINER, request_timeout=60):
                return True
        return False

    async def check(self) -> None:
        """Probe (throttled) and act. Called every data-loop cycle; never raises."""
        if not self.enabled:
            return
        now = self._clock()
        hint = self._ping_failing_since() if self._ping_failing_since else None
        pinging_badly = self._attempts == 0 and hint is not None
        interval = FAST_PROBE_SEC if pinging_badly else PROBE_INTERVAL_SEC
        if self._past_cap:
            interval = EXHAUSTED_PROBE_SEC
        onset = pinging_badly and not self._was_pinging_badly
        self._was_pinging_badly = pinging_badly
        if not onset and self._last_probe is not None and (now - self._last_probe) < interval:
            return
        self._last_probe = now
        self._disruptive_round = False
        try:
            if await self._read_recovery(now):
                return
            await self._observe_tor_start()
            await self._read_history()
            if self._clear_history:
                self._request_history()
            if self._pending_refresh is not None:
                result = control_service.result(self._pending_refresh)
                if result is None:
                    if now - self._pending_since < PROBE_INTERVAL_SEC:
                        return
                    result = {"status": "failed"}
                self._pending_refresh = None
                self._pending_since = None
                if result.get("status") != "applied":
                    if result.get("status") == "rejected":
                        self._attempts = max(self._attempts, NEWNYM_ATTEMPTS)
                    elif not self._newnym_retried:
                        self._newnym_retried = True
                        self.refund_attempt()
                    self._last_attempt = now
                    self._newnym_unconfirmed = True
                    logger.warning(
                        "Tor NEWNYM was not confirmed by the host control runner (%s: %s)",
                        result.get("status"),
                        result.get("error"),
                    )
                    self._request_history()
                    return
                self._newnym_unconfirmed = False
                rotated = result.get("action") == "tor-dropguards"
                self._guard_rotated = self._guard_rotated or rotated
                self._recovery_step = "guard rotation" if rotated else "NEWNYM"
            probe = await asyncio.to_thread(self._probe)
            ok, evidence = probe
            if not ok and self.circuits_wedged:
                evidence = f"{evidence}; control port reports wedged circuits"
            if not ok:
                self._failure_evidence = evidence
            outage_minutes = (now - self._failing_since) / 60 if self._failing_since else 0
            action = self.decide(ok, now)
            self._disruptive_round = action == "heal" and self._attempts > NEWNYM_ATTEMPTS
            if self._attempts:
                self._request_history()
            if action == "heal":
                if self._attempts <= NEWNYM_ATTEMPTS:
                    logger.warning(
                        "Tor clearnet egress failed for %.0f minutes: %s. "
                        "Requesting NEWNYM (%d/%d).",
                        outage_minutes,
                        evidence,
                        self._attempts,
                        NEWNYM_ATTEMPTS,
                    )
                    try:
                        self._pending_refresh = control_service.submit(
                            "tor-newnym", actor="tor-heal"
                        )
                    except OSError:
                        if not self._newnym_retried:
                            self._newnym_retried = True
                            self.refund_attempt()
                        self._last_attempt = now
                        logger.warning(
                            "Tor NEWNYM could not be submitted to the host control runner"
                        )
                        return
                    self._pending_since = now
                    return
                if self._guard_rotated:
                    self._disruptive.pop()
                    logger.warning(
                        "Tor egress still failed after guard rotation (%s). Not restarting Tor.",
                        evidence,
                    )
                    return
                if self._attempts == NEWNYM_ATTEMPTS + 1:
                    try:
                        self._pending_recovery = control_service.submit(
                            "tor-recover", actor="tor-heal"
                        )
                        self._recovery_requested_at = now
                        self._own_restart = True
                    except OSError:
                        self._recovery_notice = (
                            "Tor state recovery could not be submitted; no restart was attempted."
                        )
                        await self._read_recovery(now)
                    return
                logger.warning(
                    "Tor clearnet egress failed for %.0f minutes after circuit "
                    "refresh: %s. Restarting Tor; mining connections will drop.",
                    outage_minutes,
                    evidence,
                )
                self._own_restart = True
                stopped = await self._docker.stop(
                    self.CONTAINER,
                    stop_timeout=TOR_STOP_GRACE_SEC,
                    request_timeout=TOR_STOP_REQUEST_TIMEOUT_SEC,
                )
                started = await self._ensure_tor_running(stopped)
                # False means unconfirmed, not unissued: a timed-out POST may have mutated
                # the daemon. Keep the attempt and cooldown even when both responses are lost.
                self._recovery_step = (
                    "Tor restart"
                    if stopped and started
                    else "Tor start (stop unconfirmed)"
                    if started
                    else "Tor restart unconfirmed"
                )
                logger.warning(
                    "Tor recovery control results: stop=%s, start=%s; attempt retained (%d/%d).",
                    "confirmed" if stopped else "unconfirmed",
                    "confirmed" if started else "unconfirmed",
                    self._attempts,
                    MAX_ATTEMPTS,
                )
                if started and self._restart_monerod and await self._monerod_running():
                    await self._monerod_budget.cycle_after_tor_restart(self._docker, now)
            elif action == "exhausted":
                await self._report_exhausted(now, evidence, outage_minutes)
            elif action == "recovered":
                logger.info(
                    "Tor clearnet egress recovered following %s: failed probes %s; recovery probe %s",
                    self._recovery_step or "probe",
                    self._failure_evidence,
                    evidence,
                )
                self._newnym_unconfirmed = False
                self._newnym_retried = False
                self._warned_saturated = False
                self._pending_history = None
                self.saturated_history = False
                self.circuits_wedged = False
                self.circuits_completing = False
                self._built_seen = None
                if self._history_outage is not None:
                    self._history_outage = None
                    self._clear_history = True
                    self._request_history()
                if self._notify is not None:
                    await self._notify(
                        f"\U0001f9c5 Tor clearnet egress recovered following "
                        f"{self._recovery_step or 'probe'}; outage {outage_minutes:.0f} "
                        f"minutes; failed probes {self._failure_evidence}; "
                        f"recovery probe {evidence}."
                    )
                self._failure_evidence = ""
                self._recovery_step = None
        except Exception as exc:  # never let the healer break the data loop
            logger.debug("Tor heal cycle failed (%s)", type(exc).__name__)
