"""Monero chain health (#2499): a live ``monerod`` that is isolated or has stopped following the
chain, the same 'at tip, with peers' contract the Tari card has (#2464).

The container healthcheck verifies RPC liveness and real peer visibility, and ``synchronized`` is
the node's own opinion: monerod drops it when a peer reports a higher tip, so a node with no peers,
or peers all on the same stale tip, keeps ``true`` while the height stops moving. Height comes from
restricted ``get_info``; peer counts come from the current container's health observation:

- **peerless**  zero outgoing connections for :data:`PEERLESS_SEC` (the same bound as #972's
  out-of-sync debounce, ``NODE_STALE_AFTER_SEC``);
- **stalled**   best height unchanged for :data:`STALLED_SEC`. Monero targets 2-minute blocks, so
  30 minutes without one is a stuck node, not a slow interval.

Either is ``red`` with the numbers in the reason. This monitor detects and alerts; it restarts
nothing. A remote node (``monero.mode: remote``) has no peer or sync verdict we can trust, so its
verdict says peers are not visible rather than guessing.
"""

import time

from mining_dashboard.config.config import NODE_STALE_AFTER_SEC

PEERLESS_SEC = NODE_STALE_AFTER_SEC
STALLED_SEC = 30 * 60

RESTART_ADVICE = (
    "restart monerod ('./pithead restart monerod') to re-dial peers; if it stays red, check "
    "Tor with './pithead tor-recover check' (read-only; requires saturated history)"
)


def _minutes(seconds):
    return int(seconds // 60)


class MoneroChainHealth:
    """Folds each poll's ``get_info`` readings into a verdict.

    Pure state + an injectable clock, so every threshold is unit-testable. An unreachable cycle
    (node-down is NodeHealthMonitor's verdict) gives no verdict and clears both clocks.
    """

    def __init__(self, clock=time.monotonic):
        self._clock = clock
        self._best = None  # highest height seen: only a rise past it is progress
        self._advanced_at = None
        self._zero_since = None
        self._run_started = None
        self.verdict = {"level": "unknown", "reasons": [], "advice": ""}

    def observe(self, sync, local=True):
        now = self._clock()
        peers_out = sync.get("peers_out") if local else None
        reachable = sync.get("reachable", True) is not False
        run_started = sync.get("monero_run_started") if local else None
        if run_started is not None and run_started != self._run_started:
            # A restart can fall entirely between polls; the new run must earn both clocks again.
            self._best = self._advanced_at = self._zero_since = None
            self._run_started = run_started
        if not local or not reachable:
            # No verdict: a remote node, a log-scrape fallback, or a node that did not answer
            # (node-down is another monitor's call). Nothing measured is carried across the gap,
            # so a restart never reads as a stall and a returning node earns its clocks afresh.
            self._best = self._advanced_at = self._zero_since = None
            self.verdict = {
                "level": "unknown",
                "reasons": [],
                "advice": "",
                "peers_visible": False,
                "reachable": reachable,
            }
            return self.verdict
        height = sync.get("height")
        if height and (self._best is None or height > self._best or self._advanced_at is None):
            self._best, self._advanced_at = max(height, self._best or 0), now
        # Peers are read from the healthcheck's observation (#2921). Missing, stale or malformed
        # is None: never a zero and never a green. The peerless clock is dropped (a reading gap
        # must not be counted as time without peers); the height clock keeps running, because
        # the stalled rule needs no peer counts.
        if peers_out is None or peers_out:
            self._zero_since = None
        elif self._zero_since is None:
            self._zero_since = now

        syncing = bool(sync.get("is_syncing"))
        stale = bool(sync.get("stale"))
        reasons = []
        peerless = self._zero_since is not None and now - self._zero_since >= PEERLESS_SEC
        age = None if self._advanced_at is None else now - self._advanced_at
        stalled = age is not None and age >= STALLED_SEC
        if peerless:
            reasons.append(f"0 outgoing peers for {_minutes(now - self._zero_since)} min")
        if stalled:
            reasons.append(f"height {self._best} has not moved for {_minutes(age)} min")
        if stale:
            reasons.append("node is out of sync")
        self.verdict = {
            "level": "red"
            if reasons
            else ("green" if peers_out is not None and not syncing else "unknown"),
            "syncing": syncing,
            "reasons": reasons,
            "advice": RESTART_ADVICE if reasons else "",
            "peers_visible": peers_out is not None,
            "peerless": peerless,
            "stalled": stalled,
            "height": self._best,
            "peers_in": sync.get("peers_in"),
            "peers_out": peers_out,
            "advance_age_sec": None if age is None else int(age),
        }
        return self.verdict
