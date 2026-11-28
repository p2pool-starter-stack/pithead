from mining_dashboard.service.network.egress_status import (
    MISSING,
    UNVERIFIED,
    WATCHDOG_CLEAN,
    WATCHDOG_LEAKING,
)


class EgressFirewallEdgesMixin:
    _prev_egress_missing = None
    _prev_watchdog_leaking = False

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

    def _egress_watchdog_edges(self, verdict):
        if verdict is None:
            self._prev_watchdog_leaking = False
            return []
        if verdict not in (WATCHDOG_CLEAN, WATCHDOG_LEAKING):
            return []
        leaking = verdict == WATCHDOG_LEAKING
        if leaking == self._prev_watchdog_leaking:
            return []
        self._prev_watchdog_leaking = leaking
        if leaking:
            self._record_incident(self.EVT_CLEARNET_EXPOSED)
            text = (
                "\U0001f6a8 \U0001f9f1 Non-Tor egress seen — the host audit counter rose since the "
                "last check: this machine sent traffic outside Tor and the allowlist. "
                "Run 'pithead doctor' for the count."
            )
        else:
            text = (
                "\U0001f7e2 \U0001f9f1 Non-Tor egress stopped — the host audit counter has not "
                "risen for a full check interval."
            )
        return [(self.EVT_CLEARNET_EXPOSED, self._fmt(text))]
