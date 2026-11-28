import logging

from mining_dashboard.service import control_service

logger = logging.getLogger("TorHeal")

COOLDOWN_SEC = 30 * 60
MAX_DISRUPTIVE_PER_DAY = 4
EXHAUSTED_PROBE_SEC = 15 * 60
RE_ALERT_SEC = 60 * 60


class TorExhaustedMixin:
    async def _report_exhausted(self, now, evidence, outage_minutes):
        if self._history_since is None or now - self._history_since >= COOLDOWN_SEC:
            self._request_history()
        if not self._warned_exhausted:
            self._warned_exhausted = True
            logger.warning(
                "Tor clearnet egress is STILL broken after %d recovery attempts "
                "(%d disruptive in the last day, cap %d): %s. "
                "No more automatic action; run './pithead doctor' for current evidence.",
                self._attempts,
                len(self._disruptive),
                MAX_DISRUPTIVE_PER_DAY,
                evidence,
            )
            try:
                control_service.submit("tor-heal-exhausted", actor="tor-heal")
            except OSError:
                logger.warning("Tor heal exhaustion could not be audited by the host")
        if self._exhausted_alerted_at is None or (now - self._exhausted_alerted_at >= RE_ALERT_SEC):
            self._exhausted_alerted_at = now
            logger.warning(
                "Tor auto-heal is past its cap (%d attempts, %d disruptive in the last "
                "day, cap %d) with egress still broken %.0f minutes into the outage; "
                "probing every %d minutes and re-alerting hourly until it recovers: %s",
                self._attempts,
                len(self._disruptive),
                MAX_DISRUPTIVE_PER_DAY,
                outage_minutes,
                EXHAUSTED_PROBE_SEC // 60,
                evidence,
            )
            if self._notify is not None:
                await self._notify(
                    f"\U0001f9c5 Tor auto-heal is past its cap: {self._attempts} attempts "
                    f"spent ({len(self._disruptive)} disruptive in the last day, "
                    f"cap {MAX_DISRUPTIVE_PER_DAY}); outage {outage_minutes:.0f} minutes; "
                    f"probing every {EXHAUSTED_PROBE_SEC // 60} minutes and re-alerting "
                    f"hourly until Tor recovers. Failed probes {evidence}."
                )
