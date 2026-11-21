"""Host observations of saturated Tor circuit history for the egress healer."""

import logging
import random
import time
import uuid

from mining_dashboard.service import control_service, request_spool

logger = logging.getLogger("TorHeal")

PENDING_CIRCUIT_LIMIT = 64
MAX_DISRUPTIVE_PER_DAY = 4
DISRUPTIVE_WINDOW_SEC = 24 * 3600
STALE_JITTER_SEC = 30 * 60
STALE_RETRY_SEC = 6 * 3600
PEERLESS_LOG_SEC = 10 * 60
OBSERVE_INTERVAL_SEC = 30 * 60


class TorHistoryMixin:
    """Keep the read-only history request and outage alert lifecycle together."""

    consensus_stale = False
    consensus_age_sec = None
    _stale_due = None
    _stale_retry_at = None
    _pending_observe = False
    _peerless_since = None
    _peerless_logged = False
    _observe_next = None
    _jitter = staticmethod(random.uniform)

    def _request_history(self, observe=False):
        """Ask the host for the saturated-history reading; one request in flight, never raises."""
        if self._pending_history is not None:
            return
        try:
            if not (self._clear_history or observe) and self._history_outage is None:
                self._history_outage = str(uuid.uuid4())
            self._pending_observe = observe
            self._pending_history = request_spool.write(
                {
                    "id": str(uuid.uuid4()),
                    "action": "tor-history",
                    "actor": "tor-heal",
                    "outage": "" if self._clear_history or observe else self._history_outage,
                    "observed_at": int(time.time()),
                }
            )
            self._history_since = self._clock()
        except OSError:
            logger.warning("Tor circuit-history check could not be submitted to the host runner")

    async def _read_history(self) -> None:
        """Log (once per heal round) and alert (once per outage) a saturated circuit history."""
        if self._pending_history is None:
            return
        result = control_service.result(self._pending_history)
        if result is None:
            # A lost request must not block every later reading: drop it after one probe interval.
            if self._clock() - self._history_since >= self.HISTORY_TIMEOUT_SEC:
                self._pending_history = None
            return
        self._pending_history = None
        applied = result.get("status") == "applied"
        self.consensus_stale = applied and result.get("consensus_stale") is True
        self.consensus_age_sec = result.get("consensus_age_sec") if applied else None
        if self._pending_observe:
            return
        if self._clear_history:
            if applied:
                self._clear_history = False
            return
        if result.get("status") != "applied":
            self.circuits_wedged = False
            logger.warning("Tor circuit-history reading was refused or unavailable")
            return
        pending = result.get("pending_circuits")
        self.circuits_wedged = result.get("circuit_established") is False or (
            isinstance(pending, int)
            and not isinstance(pending, bool)
            and pending >= PENDING_CIRCUIT_LIMIT
        )
        saturated = result.get("saturated") is True
        self.saturated_history = saturated
        if not saturated:
            return
        logger.warning(
            "Tor circuit-build-time history is saturated (CircuitBuildAbandonedCount and "
            "TotalBuildTimes at the cap, no CircuitBuildTimeBin) and NEWNYM does not clear it. "
            "Run './pithead tor-recover check' then './pithead tor-recover apply'."
        )
        if not self._warned_saturated and self._notify is not None:
            self._warned_saturated = bool(
                await self._notify(
                    "\U0001f9c5 Tor clearnet egress is down and its circuit-build-time history is "
                    "saturated; NEWNYM cannot clear it. Run './pithead tor-recover check', then "
                    "'./pithead tor-recover apply'."
                )
            )

    async def _read_recovery(self, now):
        """Report the host result without retrying a mutation or falling back to a restart."""
        pending = self._pending_recovery is not None
        if pending:
            result = control_service.result(self._pending_recovery)
            if result is None and now - self._recovery_requested_at < 15 * 60:
                return True
            self._pending_recovery = None
            if result is not None and result.get("status") == "applied":
                self._recovery_step = "host-gated Tor state recovery"
                self._recovery_notice = (
                    "Tor heal reset circuit state and guards through tor-recover; "
                    "the host verified its evidence, onion identities and six-hour cooldown."
                )
            else:
                self._own_restart = False  # nothing restarted Tor; a later restart is not ours
                detail = (result or {}).get("error", "host result unconfirmed")
                self._recovery_step = "Tor state recovery unconfirmed"
                self._recovery_notice = f"Tor state recovery refused or failed: {detail}. The next heal round restarts Tor."
        if self._recovery_notice is not None:
            logger.warning("%s", self._recovery_notice)
            if self._notify is not None and await self._notify(self._recovery_notice):
                self._recovery_notice = None
        return pending

    async def _observe_consensus(self, now, ok) -> bool:
        if not ok or self._attempts or self._history_outage is not None or self._clear_history:
            return False
        if self._observe_next is None or now >= self._observe_next:
            self._observe_next = now + OBSERVE_INTERVAL_SEC
            self._request_history(observe=True)
        peerless = self._peerless_since() if self._peerless_since else None
        if peerless is None:
            self._peerless_logged = False
        elif (
            now - peerless >= PEERLESS_LOG_SEC
            and not self._peerless_logged
            and self.consensus_age_sec is not None
        ):
            self._peerless_logged = True
            logger.warning(
                "Tari has had no peers for %.0f minutes while Tor clearnet probes pass; "
                "directory cache age: %s s.",
                (now - peerless) / 60,
                self.consensus_age_sec,
            )
        if not self.consensus_stale:
            self._stale_due = None
            return False
        if self._stale_retry_at is not None and now < self._stale_retry_at:
            return False
        if self._stale_due is None:
            self._stale_due = now + self._jitter(0, STALE_JITTER_SEC)
        self._disruptive = [t for t in self._disruptive if now - t < DISRUPTIVE_WINDOW_SEC]
        if now < self._stale_due or len(self._disruptive) >= MAX_DISRUPTIVE_PER_DAY:
            return False
        evidence = f"cached consensus {self.consensus_age_sec} s old while clearnet probes pass"
        logger.warning("Tor directory cache is stale (%s); requesting tor-recover.", evidence)
        try:
            self._pending_recovery = control_service.submit("tor-recover", actor="tor-heal")
        except OSError:
            self._stale_retry_at = now + STALE_RETRY_SEC
            logger.warning("Tor state recovery could not be submitted; no restart was attempted.")
            return False
        self._recovery_requested_at = now
        self._own_restart = True
        self._disruptive.append(now)
        self._stale_due = None
        self._stale_retry_at = now + STALE_RETRY_SEC
        return True
