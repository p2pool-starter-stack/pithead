class MoneroHealthEdgesMixin:
    """monerod reachable and 'synchronized' but isolated or not advancing (#2499).

    ``monero_peerless`` and ``monero_stalled`` are edge-triggered off the verdict's own debounce
    (0 outgoing peers for NODE_STALE_AFTER_SEC, no new height for 30 min), one message into the
    condition and one out. They ride the ``node_down`` / ``node_recovered`` toggles, like the
    out-of-sync edge (#972): the same conversation, a different failure mode. Each edge needs
    its own observation: peer counts for peerlessness, measured height and advance age for a
    stall. Remote or unreachable verdicts keep both states without faking recovery."""

    _prev_monero_peerless = None
    _prev_monero_stalled = None

    def _monero_health_edges(self, health):
        if not health or health.get("reachable") is False:
            return []
        alerts = []
        if health.get("peers_visible"):
            alerts += self._health_edge(
                "_prev_monero_peerless",
                bool(health.get("peerless")),
                f"Monero node has no outgoing peers ({health.get('peers_out')} out, "
                f"{health.get('peers_in')} in) — it cannot see new blocks and mining sits on a "
                "stale tip. Run './pithead restart monerod' to re-dial, then './pithead tor-recover check' if it stays peerless.",
                "Monero node has outgoing peers again.",
            )
        if health.get("height") is not None and health.get("advance_age_sec") is not None:
            alerts += self._health_edge(
                "_prev_monero_stalled",
                bool(health.get("stalled")),
                f"Monero node height {health.get('height')} has not moved for "
                f"{health['advance_age_sec'] // 60} min (blocks arrive every ~2) — "
                "it may be on a stale tip or a fork. Run './pithead restart monerod', then './pithead tor-recover check' if height stays stalled.",
                "Monero node is advancing again.",
            )
        return alerts

    def _health_edge(self, attr, now, down_text, up_text):
        prev = getattr(self, attr)
        setattr(self, attr, now)
        if prev is None or now == prev:  # the first verdict is the baseline, never an alert
            return []
        if now:
            self._record_incident(self.EVT_NODE_DOWN)
            return [(self.EVT_NODE_DOWN, self._fmt(f"\U0001f534 ⛓️ {down_text}"))]
        return [(self.EVT_NODE_RECOVERED, self._fmt(f"\U0001f7e2 ⛓️ {up_text}"))]
