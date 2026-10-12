class TariNodeEdgesMixin:
    def _tari_node_edges(self, down, required, workers_rejected):
        """Describe Tari's outage without promising a worker transition that did not happen."""
        prev = self._prev_tari_down
        self._prev_tari_down = down
        if down and workers_rejected:
            self._tari_outage_rejected = True
        if prev is None or down == prev:
            return []
        if down:
            self._record_incident(self.EVT_NODE_DOWN)
            if workers_rejected:
                detail = "workers rejected — failing over to backup pools."
            elif not required:
                detail = "Monero mining continues; Tari merge mining resumes when the node returns."
            else:
                detail = "workers will be rejected if RPC stays unreachable past the outage window."
            return [(self.EVT_NODE_DOWN, self._fmt(f"🔴 ⛓️ Tari node is DOWN — {detail}"))]

        rejected = self._tari_outage_rejected
        self._tari_outage_rejected = False
        if workers_rejected:
            detail = (
                "workers remain rejected until all required nodes recover and the proxy starts."
            )
        elif rejected:
            detail = "workers readmitted; Tari merge mining resumes."
        elif not required:
            detail = "Monero mining continues; Tari merge mining resumes."
        else:
            detail = "Tari merge mining resumes."
        return [(self.EVT_NODE_RECOVERED, self._fmt(f"🟢 ⛓️ Tari node recovered — {detail}"))]
