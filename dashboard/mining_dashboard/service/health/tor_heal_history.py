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
            self._warned_saturated = bool(
                await self._notify(
                    "\U0001f9c5 Tor clearnet egress is down and its circuit-build-time history is "
                    "saturated; NEWNYM cannot clear it. Run './pithead tor-recover check', then "
                    "'./pithead tor-recover apply'."
                )
            )

