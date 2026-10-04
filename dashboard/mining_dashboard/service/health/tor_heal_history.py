"""Host observations of saturated Tor circuit history for the egress healer."""

import logging
import time
import uuid

from mining_dashboard.service import control_service, request_spool

logger = logging.getLogger("TorHeal")


class TorHistoryMixin:
    """Keep the read-only history request and outage alert lifecycle together."""

    def _request_history(self):
        """Ask the host for the saturated-history reading; one request in flight, never raises."""
        if self._pending_history is not None:
            return
        try:
            if not self._clear_history and self._history_outage is None:
                self._history_outage = str(uuid.uuid4())
            self._pending_history = request_spool.write(
                {
                    "id": str(uuid.uuid4()),
                    "action": "tor-history",
                    "actor": "tor-heal",
                    "outage": "" if self._clear_history else self._history_outage,
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
        if self._clear_history:
            if result.get("status") == "applied":
                self._clear_history = False
            return
        if result.get("status") != "applied":
            logger.warning("Tor circuit-history reading was refused or unavailable")
            return
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
                    "Tor heal reset saturated circuit history and guards through tor-recover; "
                    "the host verified its evidence, onion identities and six-hour cooldown."
                )
            else:
                detail = (result or {}).get("error", "host result unconfirmed")
                self._recovery_step = "Tor state recovery unconfirmed"
                self._recovery_notice = f"Tor state recovery refused or failed: {detail}. No fallback restart was attempted."
        if self._recovery_notice is not None:
            logger.warning("%s", self._recovery_notice)
            if self._notify is not None and await self._notify(self._recovery_notice):
                self._recovery_notice = None
        return pending
