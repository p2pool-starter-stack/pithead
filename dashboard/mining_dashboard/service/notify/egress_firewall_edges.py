from mining_dashboard.service.network.egress_status import (
    MISSING, UNVERIFIED,
    WATCHDOG_CLEAN, WATCHDOG_LEAKING, WATCHDOG_NOT_OBSERVED,
)


class EgressFirewallEdgesMixin:

    _prev_egress_missing = None
    _prev_watchdog = WATCHDOG_CLEAN

    def _egress_firewall_edges(self, state):
        if state is None:
            self._prev_egress_missing = None
            return []
        if state == UNVERIFIED:
            return []
        missing = state == MISSING
        prev = bool(self._prev_egress_missing)
        self._prev_egress_missing = missing
        if missing == prev:
            return []
        if missing:
            self._record_incident(self.EVT_CLEARNET_EXPOSED)
            text = (
                "\U0001f6a8 \U0001f9f1 Tor-only egress firewall MISSING on the host — clearnet "
                "egress is NOT fail-closed. Run 'pithead up' to reinstall it."
            )
        else:
            text = "\U0001f7e2 \U0001f9f1 Tor-only egress firewall restored — egress is fail-closed again."
        return [(self.EVT_CLEARNET_EXPOSED, self._fmt(text))]

    def _egress_watchdog_edges(self, watchdog):
        if watchdog is None:
            self._prev_watchdog = None
            return []
        if watchdog == WATCHDOG_NOT_OBSERVED:
            self._prev_watchdog = None
            return []
        prev = self._prev_watchdog
        self._prev_watchdog = watchdog
        if watchdog == prev:
            return []
        if watchdog == WATCHDOG_LEAKING:
            self._record_incident(self.EVT_EGRESS_WATCHDOG_LEAK)
            return [(self.EVT_EGRESS_WATCHDOG_LEAK,
                     self._fmt("\U0001f6a8 \U0001f9f1 Egress watchdog: non-Tor egress detected — "
                               "the host audit table's counter is rising, which means new "
                               "outbound flows hit the non-LAN catch-all."))]
        return [(self.EVT_EGRESS_WATCHDOG_LEAK,
                 self._fmt("\U0001f7e2 \U0001f9f1 Egress watchdog clean — the host audit "
                           "counter is stable; no new non-LAN outbound flows since the last check."))]
