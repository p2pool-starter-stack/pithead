"""Opt-in Tor clearnet recovery without changing guards by default.

Each failed probe is corroborated on a fresh SOCKS-auth circuit and a second target. After a
sustained outage, two bounded NEWNYM requests go through the audited host control runner. A
final container restart is disruptive and re-dials local Monero; neither NEWNYM nor a clearnet
failure authorizes DROPGUARDS or deletion of Tor state. Saturated circuit-history recovery is
an explicit operator command (`./pithead tor-recover`). When NEWNYM is unconfirmed or ineffective
the healer only reads the saturated signature through a read-only host request and alerts the
operator; it never moves state aside itself (#3052).
"""

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
from mining_dashboard.helper.http import bounded_get
from mining_dashboard.service import control_service

logger = logging.getLogger("TorHeal")

# Independent targets: any response on either fresh circuit proves clearnet egress works.
PROBE_URL = "https://www.google.com/generate_204"
SECOND_PROBE_URL = "https://www.cloudflare.com/cdn-cgi/trace"
PROBE_TIMEOUT_SEC = 15

# Fixed, bounded cadence and attempt budget for this opt-in recovery.
PROBE_INTERVAL_SEC = 5 * 60  # active probe cadence (only while the heal is enabled)
BROKEN_AFTER_SEC = 15 * 60  # sustained failure before the first action
COOLDOWN_SEC = 30 * 60  # minimum gap between actions
MAX_ATTEMPTS = 3  # two circuit refreshes, then one container restart
# Consecutive OK probes required to declare an outage OVER once we've spent an action. A single
# lucky 204 must NOT close the outage: under the issue's own scenario (overloaded Tor, egress
# flapping) that would refill the budget and clear the cooldown every blip.
RECOVERY_CONFIRM_PROBES = 2  # ~10 min sustained egress before the budget resets


class TorEgressHealer:
    """Probe and recover Tor egress under a fixed cadence, cooldown and attempt cap."""

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
    ):
        self.enabled = TOR_AUTO_HEAL if enabled is None else enabled
        # Cycle monerod after a successful tor restart (#972) — only when the node is local
        # (a remote monerod has no container here and keeps its own tor).
        if restart_monerod is None:
            restart_monerod = MONERO_NODE_HOST == LOCAL_MONERO_HOST
        self._restart_monerod = restart_monerod
        self._docker = docker_control
        self._probe = probe or self._probe_egress
        self._notify = notify  # optional async callable(text) — the Telegram one-off
        self._clock = clock
        self._last_probe = None  # probe-cadence throttle
        self._failing_since = None  # start of the current unbroken failure streak
        self._attempts = 0  # recovery actions spent on the current outage
        self._last_attempt = None  # cooldown anchor
        self._ok_streak = 0  # consecutive OK probes (sustained-recovery counter, post-restart)
        self._warned_exhausted = False  # give-up warning is logged once per outage, not every probe
        self._pending_refresh = None
        self._pending_since = None
        self._failure_evidence = ""
        self._recovery_step = None
        self._newnym_unconfirmed = False  # last NEWNYM round got no applied result
        self._pending_history = None  # read-only tor-history request awaiting its result
        self._warned_saturated = False  # saturated-history alert is sent once per outage
        self.saturated_history = False  # latest host reading, for status surfaces
        if self.enabled:
            logger.info(
                "Tor egress self-heal enabled: probing every %ds; recovery after %dm "
                "broken, max %d attempts %dm apart.",
                PROBE_INTERVAL_SEC,
                BROKEN_AFTER_SEC // 60,
                MAX_ATTEMPTS,
                COOLDOWN_SEC // 60,
            )

    @staticmethod
    def _probe_egress() -> tuple[bool, str]:
        """Corroborate failures on separate SOCKS circuits and independent targets."""
        evidence = []
        for url in (PROBE_URL, SECOND_PROBE_URL):
            circuit = uuid.uuid4().hex
            # Tor's SOCKS-auth isolation keeps each request off the previous circuit.
            # PySocks offers SOCKS5 username/password only when BOTH fields are nonempty.
            proxy = TOR_SOCKS_PROXY.replace("://", f"://{circuit}:isolate@", 1)
            try:
                bounded_get(url, timeout=PROBE_TIMEOUT_SEC, proxies={"http": proxy, "https": proxy})
                evidence.append(f"{url}: circuit {circuit[:8]} answered")
                return True, "; ".join(evidence)
            except requests.RequestException as exc:
                evidence.append(f"{url}: circuit {circuit[:8]} {type(exc).__name__}")
        return False, "; ".join(evidence)

    def decide(self, ok, now):
        """Fold one probe result into the outage state; return the action to take.

        Returns ``None``, ``"heal"`` (one recovery attempt), ``"exhausted"``, or
        ``"recovered"`` after two corroborated successes.
        """
        if ok:
            if self._attempts == 0:
                # No restart spent yet — a single healthy probe just clears a sub-threshold
                # blip. Nothing to protect, so reset immediately (unchanged blip semantics).
                self._failing_since = None
                self._ok_streak = 0
                return None
            # We have already restarted this outage. Require SUSTAINED recovery before
            # refilling the budget and clearing the cooldown: a lone 204 during a flapping,
            # overloaded-Tor outage must not reset the cap (#424 review). Budget and cooldown
            # anchor are preserved until the streak confirms, so a relapse resumes where it
            # left off instead of getting a fresh set of restarts.
            self._ok_streak += 1
            if self._ok_streak < RECOVERY_CONFIRM_PROBES:
                return None
            self._failing_since = None
            self._attempts = 0
            self._last_attempt = None
            self._ok_streak = 0
            self._warned_exhausted = False
            return "recovered"
        # ok is False — any failure breaks a would-be recovery streak.
        self._ok_streak = 0
        if self._failing_since is None:
            self._failing_since = now
        # Transient blip guard: not broken until the failure streak spans the threshold.
        if (now - self._failing_since) < BROKEN_AFTER_SEC:
            return None
        # Retry cap: past the budget we never restart again this outage — warn instead.
        if self._attempts >= MAX_ATTEMPTS:
            return "exhausted"
        # Cooldown: give the previous action time to prove itself.
        if self._last_attempt is not None and (now - self._last_attempt) < COOLDOWN_SEC:
            return None
        self._attempts += 1
        self._last_attempt = now
        return "heal"

    def refund_attempt(self):
        """Refund an unconfirmed NEWNYM; keep the ongoing outage clock."""
        if self._attempts > 0:
            self._attempts -= 1
        self._last_attempt = None

    def _request_history(self):
        """Ask the host for the saturated-history reading; one request in flight, never raises."""
        if self._pending_history is not None:
            return
        try:
            self._pending_history = control_service.submit("tor-history", actor="tor-heal")
        except OSError:
            logger.warning("Tor circuit-history check could not be submitted to the host runner")

    async def _read_history(self) -> None:
        """Log (once per heal round) and alert (once per outage) a saturated circuit history."""
        if self._pending_history is None:
            return
        result = control_service.result(self._pending_history)
        if result is None:
            return
        self._pending_history = None
        saturated = result.get("status") == "applied" and result.get("saturated") is True
        self.saturated_history = saturated
        if not saturated:
            return
        logger.warning(
            "Tor circuit-build-time history is saturated (CircuitBuildAbandonedCount and "
            "TotalBuildTimes at the cap, no CircuitBuildTimeBin) and NEWNYM does not clear it. "
            "Run './pithead tor-recover check' then './pithead tor-recover apply'."
        )
        if not self._warned_saturated and self._notify is not None:
            self._warned_saturated = True
            await self._notify(
                "\U0001f9c5 Tor clearnet egress is down and its circuit-build-time history is "
                "saturated; NEWNYM cannot clear it. Run './pithead tor-recover check', then "
                "'./pithead tor-recover apply'."
            )

    async def _monerod_running(self) -> bool:
        """Only a running monerod is cycled (#2749). A stopped one stays stopped: with LAN access on
        a DIY Docker host it may be held because its LAN-only source rule is missing, and a start
        would publish its ports on 0.0.0.0 without it."""
        return bool((await get_container_health()).get(self.MONEROD, {}).get("running"))

    async def check(self) -> None:
        """Probe (throttled) and act. Called every data-loop cycle; never raises."""
        if not self.enabled:
            return
        now = self._clock()
        if self._last_probe is not None and (now - self._last_probe) < PROBE_INTERVAL_SEC:
            return
        self._last_probe = now
        try:
            await self._read_history()
            if self._pending_refresh is not None:
                result = control_service.result(self._pending_refresh)
                if result is None:
                    if now - self._pending_since < PROBE_INTERVAL_SEC:
                        return
                    result = {"status": "failed"}
                self._pending_refresh = None
                self._pending_since = None
                if result.get("status") != "applied":
                    status = result.get("status")
                    error = result.get("error")
                    # An unconfirmed NEWNYM never escalates to the disruptive restart; the
                    # saturated-history reading below tells the operator what will help.
                    self.refund_attempt()
                    self._last_attempt = now
                    self._newnym_unconfirmed = True
                    logger.warning(
                        "Tor NEWNYM was not confirmed by the host control runner (%s: %s)",
                        status,
                        error,
                    )
                    self._request_history()
                    return
                self._newnym_unconfirmed = False
                self._recovery_step = "NEWNYM"
            probe = await asyncio.to_thread(self._probe)
            ok, evidence = probe
            if not ok:
                self._failure_evidence = evidence
            outage_minutes = (now - self._failing_since) / 60 if self._failing_since else 0
            action = self.decide(ok, now)
            if action == "heal":
                if self._recovery_step == "NEWNYM" or self._newnym_unconfirmed:
                    self._request_history()  # NEWNYM did not help: is the history saturated?
                if self._attempts < MAX_ATTEMPTS:
                    logger.warning(
                        "Tor clearnet egress failed for %.0f minutes: %s. "
                        "Requesting NEWNYM (%d/%d).",
                        outage_minutes,
                        evidence,
                        self._attempts,
                        MAX_ATTEMPTS - 1,
                    )
                    try:
                        self._pending_refresh = control_service.submit(
                            "tor-newnym", actor="tor-heal"
                        )
                    except OSError:
                        self.refund_attempt()
                        self._last_attempt = now
                        logger.warning(
                            "Tor NEWNYM could not be submitted to the host control runner"
                        )
                        return
                    self._pending_since = now
                    return
                logger.warning(
                    "Tor clearnet egress failed for %.0f minutes after circuit "
                    "refresh: %s. Restarting Tor; mining connections will drop.",
                    outage_minutes,
                    evidence,
                )
                stopped = await self._docker.stop(
                    self.CONTAINER, stop_timeout=15, request_timeout=60
                )
                started = await self._docker.start(self.CONTAINER, request_timeout=60)
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
                    # The tor restart just killed every SOCKS connection; monerod holds its
                    # dead peer sockets and can sit at 0 in / 0 out peers for hours while
                    # looking healthy (#972). Cycle it so it re-dials through the fresh tor.
                    # monerod's stop_grace_period is 1m, so the stop timeout matches it and the
                    # HTTP timeout outlasts the stop (#234's lesson).
                    logger.warning(
                        "Restarting monerod alongside tor so it re-dials its peers through "
                        "the fresh Tor (#972)."
                    )
                    m_stopped = await self._docker.stop(
                        self.MONEROD, stop_timeout=60, request_timeout=90
                    )
                    m_started = await self._docker.start(self.MONEROD, request_timeout=60)
                    if not (m_stopped and m_started):
                        logger.warning(
                            "monerod restart alongside tor could not be issued — if the node "
                            "stays out of sync, restart it manually: './pithead restart "
                            "monerod' (#972)."
                        )
            elif action == "exhausted":
                if not self._warned_exhausted:
                    self._warned_exhausted = True
                    logger.warning(
                        "Tor clearnet egress is STILL broken after %d recovery attempts: %s. "
                        "No more automatic action; run './pithead doctor' for current evidence.",
                        MAX_ATTEMPTS,
                        evidence,
                    )
            elif action == "recovered":
                logger.info(
                    "Tor clearnet egress recovered following %s: failed probes %s; recovery probe %s",
                    self._recovery_step or "probe",
                    self._failure_evidence,
                    evidence,
                )
                if self._notify is not None:
                    await self._notify(
                        f"\U0001f9c5 Tor clearnet egress recovered following "
                        f"{self._recovery_step or 'probe'}; outage {outage_minutes:.0f} "
                        f"minutes; failed probes {self._failure_evidence}; "
                        f"recovery probe {evidence}."
                    )
                self._failure_evidence = ""
                self._recovery_step = None
                self._newnym_unconfirmed = False
                self._warned_saturated = False
                self.saturated_history = False
        except Exception as exc:  # never let the healer break the data loop
            logger.debug("Tor heal cycle failed (%s)", type(exc).__name__)
