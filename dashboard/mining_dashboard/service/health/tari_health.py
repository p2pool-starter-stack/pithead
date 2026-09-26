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

Red, sustained, restarts the local node (``tari.auto_restart``, on by default): startup clears
``bad_blocks``, which is what recovered production, and a restart is the only lever that stops P2Pool
building Tari blocks on a stale tip without restarting P2Pool (and so its Monero mining). Guards, as
tor_heal's (#424): :data:`RED_SUSTAIN_SEC` of red first, :data:`COOLDOWN_SEC` between restarts,
:data:`MAX_RESTARTS` per outage, the budget refilled only by :data:`GREEN_CONFIRM_SEC` of green. A
restart is refused while the node's gRPC is not answering: minotari_node opens gRPC only once its
database migrations finish, and interrupting the 6.0.0 migration is unsafe (#2593). The verdict,
and every alert and doctor row built on it, follows the signals, never the restart's outcome.
"""

import asyncio
import logging
import os
import time

from mining_dashboard.config.config import TARI_MODE, TOR_SOCKS_PROXY
from mining_dashboard.helper.http import bounded_get

logger = logging.getLogger("TariHealth")

# Read here, not in config.py, which sits at its file budget. tari.auto_restart (default on) and
# tari.explorer_url (blank disables the reference) render to these via pithead's .env.
TARI_AUTO_RESTART = os.environ.get("TARI_AUTO_RESTART", "true").strip().lower() == "true"
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
RED_SUSTAIN_SEC = 5 * 60
COOLDOWN_SEC = 60 * 60
MAX_RESTARTS = 3
GREEN_CONFIRM_SEC = 15 * 60

RESTART_ADVICE = (
    "restart the Tari node ('./pithead restart tari'); startup clears its bad-block list"
)
ESCALATED_ADVICE = (
    f"{MAX_RESTARTS} restarts did not bring it back: likely a chain fork or an upgrade required "
    "— a restart cannot fix this. See docs/operations.md, Troubleshooting, 'Tari node stuck or forked'."
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
        logger.info(
            "Tari explorer reference unavailable (%s); verdict uses local signals only.", exc
        )
        return None


class TariChainHealth:
    """Folds each poll's Tari readings into a verdict and, when red, a guarded restart.

    :meth:`observe` and :meth:`decide` are pure state + clock, so every threshold and guard is
    unit-testable; :meth:`check` is the per-cycle entry point that does the I/O.
    """

    CONTAINER = "tari"

    def __init__(
        self,
        docker_control=None,
        auto_restart=None,
        explorer_url=None,
        explorer=_explorer_tip,
        notify=None,
        clock=time.monotonic,
    ):
        if auto_restart is None:
            auto_restart = TARI_AUTO_RESTART and TARI_MODE == "local"
        self.auto_restart = auto_restart
        self.explorer_url = TARI_EXPLORER_URL if explorer_url is None else explorer_url
        self._explorer = explorer
        self._docker = docker_control
        self._notify = notify  # optional async callable(text): the operator alert sink
        self._alerted = None  # the red advice last alerted, so each change is sent exactly once
        self._clock = clock
        self._height = None
        self._height_since = None
        self._zero_since = None
        self._explorer_tip = None
        self._explorer_at = None
        self._red_since = None
        self._green_since = None
        self._restarts = 0
        self._last_restart = None
        self.verdict = {"level": "green", "reasons": [], "advice": ""}

    def observe(self, sync, connections, now):
        """Fold one cycle's readings (``TariClient.get_sync_status()`` and the peer count, or None
        when the node did not say) into ``self.verdict``. An unreachable cycle feeds nothing:
        node-down is NodeHealthMonitor's verdict, and a stall is measured across it."""
        if sync.get("reachable") and sync.get("current"):
            height = sync["current"]
            if height != self._height:
                self._height, self._height_since = height, now
        if sync.get("reachable") and connections is not None:
            if connections:
                self._zero_since = None
            elif self._zero_since is None:
                self._zero_since = now

        syncing = sync.get("is_syncing", False)
        reasons, red = [], False
        if self._height_since is not None and now - self._height_since >= TIP_STALE_SEC:
            reasons.append(
                f"tip {self._height} unchanged for {int((now - self._height_since) // 60)} min"
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
            "restarts": self._restarts,
        }
        return self.verdict

    def decide(self, reachable, now):
        """The restart decision for the current verdict: ``None``, ``"restart"`` (a budget slot is
        spent — the caller must restart), ``"withheld"`` (red, but the node's gRPC is not answering:
        possibly migrating), ``"exhausted"`` or ``"recovered"`` (sustained green after a restart)."""
        level = self.verdict["level"]
        if level == "green":
            self._red_since = None
            if self._green_since is None:
                self._green_since = now
            if self._restarts and now - self._green_since >= GREEN_CONFIRM_SEC:
                self._restarts, self._last_restart = 0, None
                return "recovered"
            return None
        self._green_since = None
        if level != "red":
            self._red_since = None
            return None
        if self._red_since is None:
            self._red_since = now
        if not self.auto_restart or now - self._red_since < RED_SUSTAIN_SEC:
            return None
        if self._restarts >= MAX_RESTARTS:
            return "exhausted"
        if not reachable:
            return "withheld"
        if self._last_restart is not None and now - self._last_restart < COOLDOWN_SEC:
            return None
        self._restarts += 1
        self._last_restart = now
        return "restart"

    async def check(self, sync, connections):
        """Per-cycle entry point: refresh the explorer reference (hourly), observe, act. Returns
        the verdict with the action taken this cycle, for the panel, the alerts and doctor."""
        now = self._clock()
        if self.explorer_url and (
            self._explorer_at is None or now - self._explorer_at >= EXPLORER_INTERVAL_SEC
        ):
            self._explorer_at = now
            tip = await asyncio.to_thread(self._explorer, self.explorer_url)
            # A failed fetch drops the reference rather than keeping an old one alive past its hour.
            self._explorer_tip = tip
        verdict = self.observe(sync, connections, now)
        action = self.decide(bool(sync.get("reachable")), now)
        if action == "restart":
            logger.warning(
                "Tari node red for %d min — restarting it (attempt %d/%d).",
                (now - self._red_since) // 60,
                self._restarts,
                MAX_RESTARTS,
            )
            stopped = await self._docker.stop(self.CONTAINER, stop_timeout=60, request_timeout=90)
            started = await self._docker.start(self.CONTAINER, request_timeout=60)
            if not (stopped and started):
                # Never issued: give the slot back so a flaky control proxy can't spend the budget.
                self._restarts -= 1
                self._last_restart = None
                action = "restart_failed"
        elif action == "withheld":
            verdict["advice"] = (
                "the node's gRPC is not answering (a database migration may be running); "
                "the automatic restart is withheld until it answers"
            )
        if self._restarts >= MAX_RESTARTS and verdict["level"] != "green":
            verdict["advice"] = ESCALATED_ADVICE
        verdict["restarts"] = self._restarts
        verdict["action"] = action
        await self._alert(verdict)
        return verdict

    async def _alert(self, verdict):
        """Red on the verdict, not the restart: one alert on entering red and one each time the
        advice changes (withheld, escalated); one recovery note on green after a red alert."""
        if self._notify is None:
            return
        level = verdict["level"]
        if level == "red" and verdict["advice"] != self._alerted:
            self._alerted = verdict["advice"]
            text = (
                "\U0001f534 ⛓️ Tari node is not following the chain — "
                f"{'; '.join(verdict['reasons'])}. Merge-mined Tari work is wasted until it "
                f"recovers; Monero mining is unaffected. Next step: {verdict['advice']}."
            )
        elif level == "green" and self._alerted is not None:
            self._alerted = None
            text = "\U0001f7e2 ⛓️ Tari node is following the chain again."
        else:
            return
        try:
            await self._notify(text)
        except Exception as exc:  # an alert sink must never break the data loop
            logger.debug("Tari health alert failed (%s)", type(exc).__name__)
