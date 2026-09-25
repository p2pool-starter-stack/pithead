from mining_dashboard.service.network.egress_status import MISSING, UNVERIFIED


class EgressFirewallEdgesMixin:
    """The Tor-only egress firewall going missing on the host while the stack runs (#2599).

    Rides the ``clearnet_exposed`` event and its toggle: both mean the host IP can reach clearnet.
    Edge-triggered: one message on the way into ``missing``, one on the way back to ``enforced``.
    ``unverified`` (stale or unreadable check) sends nothing and keeps the last verdict, so a gap in
    the checks cannot fake a recovery or repeat the alarm. The baseline is ``enforced``: a dashboard
    that starts on a missing firewall (a reboot without the boot unit, #2460) alerts at once. The
    dashboard runs only as part of the stack, so "while the stack runs" is its own liveness."""

    _prev_egress_missing = None

    def _egress_firewall_edges(self, state):
        if state is None:  # the operator opted out of the firewall; nothing to watch
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
