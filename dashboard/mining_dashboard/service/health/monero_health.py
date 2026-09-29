"""Monero chain health (#2499): a live ``monerod`` that is isolated or has stopped following the
chain, the same 'at tip, with peers' contract the Tari card has (#2464).

The container healthcheck only proves the RPC answers, and ``synchronized`` is the node's own
opinion: monerod drops it when a peer reports a higher tip, so a node with no peers, or peers all
on the same stale tip, keeps ``true`` while the height stops moving. Two signals, each read from the
``get_info`` payload the dashboard already fetches:

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
    "the node's peer connections in its logs"
)


def _minutes(seconds):
    return int(seconds // 60)


class MoneroChainHealth:
    """Folds each poll's ``get_info`` readings into a verdict.

    Pure state + an injectable clock, so every threshold is unit-testable. An unreachable cycle
    feeds no height or peer count (node-down is NodeHealthMonitor's verdict) and restarts the
    peerless clock; the stall clock runs across it.
    """

    def __init__(self, clock=time.monotonic):
        self._clock = clock
        self._best = None  # highest height seen: only a rise past it is progress
        self._advanced_at = None
        self._zero_since = None
        self.verdict = {"level": "unknown", "reasons": [], "advice": ""}

    def observe(self, sync, local=True):
        now = self._clock()
        peers_out = sync.get("peers_out") if local else None
        if not local or (peers_out is None and sync.get("reachable", True) is not False):
            # Remote node, log-scrape fallback or a payload without the counts: no verdict, and
            # nothing measured on it is carried over to a later, different source.
            self._best = self._advanced_at = self._zero_since = None
            self.verdict = {
                "level": "unknown",
                "reasons": [],
                "advice": "",
                "peers_visible": False,
            }
            return self.verdict
        reachable = sync.get("reachable", True) is not False and peers_out is not None
        height = sync.get("height")
        if reachable and height:
            if self._best is None or height > self._best:
                self._best, self._advanced_at = height, now
        if not reachable or peers_out:
            self._zero_since = None
        elif self._zero_since is None:
            self._zero_since = now

        reasons = []
        peerless = self._zero_since is not None and now - self._zero_since >= PEERLESS_SEC
        age = None if self._advanced_at is None else now - self._advanced_at
        stalled = age is not None and age >= STALLED_SEC
        if peerless:
            reasons.append(f"0 outgoing peers for {_minutes(now - self._zero_since)} min")
        if stalled:
            reasons.append(f"height {self._best} has not moved for {_minutes(age)} min")
        self.verdict = {
            "level": "red" if reasons else "green",
            "reasons": reasons,
            "advice": RESTART_ADVICE if reasons else "",
            "peers_visible": True,
            "peerless": peerless,
            "stalled": stalled,
            "height": self._best,
            "peers_in": sync.get("peers_in") if reachable else None,
            "peers_out": peers_out if reachable else None,
            "advance_age_sec": None if age is None else int(age),
        }
        return self.verdict
