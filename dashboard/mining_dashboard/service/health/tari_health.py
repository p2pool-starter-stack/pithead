"""Tari chain health (#2464): a live ``minotari_node`` that has stopped following the chain.

The container healthcheck is process liveness on purpose (a sync-aware one would read a multi-day
Tor initial sync as a crash), and ``initial_sync_achieved`` is historical: production sat nine days
on a ten-day-old tip, every peer banned for serving the next block (a ``bad_blocks`` verdict that
only a restart clears), while the process, the gRPC and P2Pool's merge-mining channel all answered.
Every signal the node offers is its own opinion of itself, so this monitor weighs three:

- **tip stale**   best height unchanged for :data:`TIP_STALE_SEC` (Tari targets 2-minute blocks);
- **offline**     zero peer connections for :data:`OFFLINE_SEC` (``GetNetworkStatus``);
- **explorer lag** a public explorer's tip, fetched through the stack's Tor once an hour, more than
  :data:`LAG_BLOCKS` ahead of ours. The only reference that is not the node's opinion: it is what
  catches a node following a dead fork, which keeps a few dead-branch peers and a creeping tip.

Verdict: no signal is ``green``; one is ``amber`` with the reason; two corroborating signals, or
explorer lag alone, is ``red``. Explorer lag is not counted while the node is on its initial sync
(the sync view shows that progress; the node's own sync target exists only then, so it is no signal
for a synced node). A missing or failed explorer fetch contributes nothing — never a false red.

This monitor detects and alerts; it changes nothing. The verdict feeds the Tari panel, /api/state,
``pithead doctor`` and ``status``, and an alert on each entry into red whose next step is the
operator's restart. Automatic remediation (restarting the node, pausing P2Pool's merge-mining) is
#2827's, after 2.0.0.
"""

import asyncio
import logging
import os
import time

from mining_dashboard.config.config import TOR_SOCKS_PROXY
from mining_dashboard.helper.http import bounded_get

logger = logging.getLogger("TariHealth")

# Read here, not in config.py, which sits at its file budget. tari.explorer_url (blank disables the
# reference) renders to this via pithead's .env.
TARI_EXPLORER_URL = os.environ.get(
    "TARI_EXPLORER_URL", "https://textexplore.tari.com/?json"
).strip()

# Fixed, like tor_heal's: nobody should have to tune a health verdict. The bounded detection
# window is TIP_STALE_SEC (+ one poll) for the stall, EXPLORER_INTERVAL_SEC (+ one poll) for a fork.
TIP_STALE_SEC = 30 * 60
OFFLINE_SEC = 10 * 60
LAG_BLOCKS = 50  # ~100 minutes of 2-minute blocks
EXPLORER_INTERVAL_SEC = 60 * 60
EXPLORER_TIMEOUT_SEC = 60
EXPLORER_MAX_BYTES = 4 * 1024 * 1024  # the JSON page carries recent blocks (~0.5 MB measured)

RESTART_ADVICE = (
    "restart the Tari node ('./pithead restart tari'); startup clears its bad-block list. If it "
    "stays red, see docs/operations.md, Troubleshooting, 'Tari node stuck or forked'"
)


def _explorer_tip(url: str) -> int | None:
    """One GET through the stack's Tor; the explorer's best height, or None on any failure."""
    try:
        body = bounded_get(
            url,
            max_bytes=EXPLORER_MAX_BYTES,
            timeout=EXPLORER_TIMEOUT_SEC,
            proxies={"http": TOR_SOCKS_PROXY, "https": TOR_SOCKS_PROXY},
        ).json()
        return int(body["tipInfo"]["metadata"]["best_block_height"])
    except Exception as exc:
        # The type only: a request error's text carries the URL, which may hold a token.
        logger.info(
            "Tari explorer reference unavailable (%s); verdict uses local signals only.",
            type(exc).__name__,
        )
        return None


class TariChainHealth:
    """Folds each poll's Tari readings into a verdict and alerts on it.

    :meth:`observe` is pure state + clock, so every threshold is unit-testable; :meth:`check` is
    the per-cycle entry point that does the I/O (the hourly explorer fetch and the alert).
    """

    def __init__(
        self, explorer_url=None, explorer=_explorer_tip, notify=None, clock=time.monotonic
    ):
        self.explorer_url = TARI_EXPLORER_URL if explorer_url is None else explorer_url
        self._explorer = explorer
        self._notify = notify  # optional async callable(text) -> text, or None when undelivered
        self._progress_alerted = None
        self._alerted = None  # set once a red alert went out, so recovery is noted once
        self._clock = clock
        self._height = None
        self._height_since = None
        self._zero_since = None
        self._explorer_tip = None
        self._explorer_at = None
        self._best = None  # highest height seen: only a rise past it is progress
        self._was_red = False  # a red alert was delivered during the current stretch of red
        self.verdict = {"level": "green", "reasons": [], "advice": ""}

    def observe(self, sync, connections, now):
        """Fold one cycle's readings (``TariClient.get_sync_status()`` and the peer count, or None
        when the node did not say) into ``self.verdict``. An unreachable cycle feeds no height:
        node-down is NodeHealthMonitor's verdict, and a stall is measured across it. Zero peers must
        be sustained, so a cycle without a peer count restarts that clock."""
        if sync.get("reachable") and sync.get("current"):
            height = sync["current"]
            # Forward progress only: a height that falls (a reorg, a rewound or reset node) or
            # returns below the best one seen must not reset the stall clock or count as recovery.
            if self._best is None or height > self._best:
                self._best, self._height_since = height, now
            self._height = height
        if not sync.get("reachable") or connections is None or connections:
            self._zero_since = None  # a missing reading is no evidence of zero peers
        elif self._zero_since is None:
            self._zero_since = now

        syncing = sync.get("is_syncing", False)
        reasons, red = [], False
        if self._height_since is not None and now - self._height_since >= TIP_STALE_SEC:
            reasons.append(
                f"tip {self._height} unchanged for {int((now - self._height_since) // 60)} min"
                if self._height == self._best
                else f"tip {self._height} has not passed {self._best} for "
                f"{int((now - self._height_since) // 60)} min"
            )
        if self._zero_since is not None and now - self._zero_since >= OFFLINE_SEC:
            reasons.append(f"0 peer connections for {int((now - self._zero_since) // 60)} min")
        lag = (self._explorer_tip or 0) - (self._height or 0)
        if not syncing and self._height and self._explorer_tip and lag > LAG_BLOCKS:
            reasons.append(f"{lag} blocks behind the public explorer ({self._explorer_tip})")
            red = True
        red = red or len(reasons) >= 2
        level = "red" if red else ("amber" if reasons else "green")
        if level != self.verdict["level"]:
            logger.warning(
                "Tari node %s -> %s: %s (local %s, explorer %s).",
                self.verdict["level"].upper(),
                level.upper(),
                "; ".join(reasons) or "all signals clear",
                self._height,
                self._explorer_tip,
            )
        self.verdict = {
            "level": level,
            "reasons": reasons,
            "advice": "" if level == "green" else RESTART_ADVICE,
            "height": self._height,
            "explorer_tip": self._explorer_tip,
            "connections": connections if sync.get("reachable") else None,  # this cycle's reading
        }
        return self.verdict

    async def check(self, sync, connections):
        """Per-cycle entry point: refresh the explorer reference (hourly), observe, alert. Returns
        the verdict for the panel, the alerts and doctor."""
        now = self._clock()
        if self.explorer_url and (
            self._explorer_at is None or now - self._explorer_at >= EXPLORER_INTERVAL_SEC
        ):
            self._explorer_at = now
            tip = await asyncio.to_thread(self._explorer, self.explorer_url)
            # A failed fetch drops the reference rather than keeping an old one alive past its hour.
            self._explorer_tip = tip
        verdict = self.observe(sync, connections, now)
        await self._alert_progress(sync)
        await self._alert(verdict)
        return verdict

    async def _alert_progress(self, sync):
        """Notify once per live initialization/sync phase, retrying failed delivery.
        These are progress states, not RPC outages and never worker-rejection signals.
        """
        if self._notify is None:
            return
        if not sync.get("reachable"):
            return  # an unknown cycle is no evidence the last live phase ended
        phase = sync.get("initializing") or ("syncing" if sync.get("is_syncing") else None)
        if phase is None:
            self._progress_alerted = None
        elif phase != self._progress_alerted:
            if await self._send(
                f"Tari node is {phase} — this is not a node-down outage. "
                "Workers are not rejected for this state."
            ):
                self._progress_alerted = phase

    async def _alert(self, verdict):
        """One red alert per entry into red, retried every cycle while red until a send succeeds;
        one recovery note on green, and only after a red alert was delivered."""
        if self._notify is None:
            return
        level = verdict["level"]
        if level != "red":
            self._was_red = False  # the next red is a new entry
        if level == "red" and not self._was_red:
            text = (
                "\U0001f534 ⛓️ Tari node is not following the chain — "
                f"{'; '.join(verdict['reasons'])}. Merge-mined Tari work is wasted until it "
                f"recovers; Monero mining is unaffected. Next step: {verdict['advice']}."
            )
            if await self._send(text):
                self._was_red = True
                self._alerted = verdict["advice"]
        elif level == "green" and self._alerted is not None:
            if await self._send("\U0001f7e2 ⛓️ Tari node is following the chain again."):
                self._alerted = None

    async def _send(self, text) -> bool:
        try:
            if await self._notify(text) is not None:  # the sender returns None when undelivered
                return True
            logger.warning("Tari health alert not delivered by any sink; retrying next cycle")
            return False
        except Exception as exc:  # an alert sink must never break the data loop
            logger.warning(
                "Tari health alert not sent (%s); retrying next cycle", type(exc).__name__
            )
            return False
