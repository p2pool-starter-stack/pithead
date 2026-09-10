import asyncio
import logging
import time

from mining_dashboard.client.xvb_client import (
    REG_INVALID,
    REG_NOT_ELIGIBLE,
    REG_OK,
)
from mining_dashboard.config.config import (
    XVB_REGISTER_INTERVAL_S,
)
from mining_dashboard.helper.utils import (
    DEFAULT_PPLNS_WINDOW,
    format_hashrate,
    pplns_block_time,
    shares_in_pplns_window,
)
from mining_dashboard.service.data_helpers import (
    _XVB_WIN_FRESH_S,
    _xvb_winners_gate_sec,
)

logger = logging.getLogger("DataService")


# Consecutive XvB-registration failures (while never yet registered) before we raise the dashboard
# "registration failing" warning (#263). A couple of transient blips during the normal first-share
# window shouldn't alarm; a configured-but-refusing endpoint should. At one attempt per 10th poll
# (~5 min) this is ~15 min of sustained failure.
_XVB_REGISTER_FAIL_ALERT = 3

# XvB telemetry is captured at most once per five minutes.
_XVB_HISTORY_CAPTURE_SEC = 300


class DataXvbSyncMixin:
    async def _sync_xvb_stats(self):
        """
        Fetch XvB's reported averages (avg_1h/avg_24h/fail_count) over Tor and persist them.

        A failed fetch (Tor timeout, 5xx) returns None — we write NOTHING in that case, leaving the
        last-good values AND ``last_update`` frozen. That frozen ``last_update`` is exactly what the
        controller and dashboard read to detect a stale feed and stop steering off a dead number
        (#311). So "no write on failure" is a correctness precondition, not just an optimisation —
        if this ever started stamping on failure, the staleness guard would silently never trigger.

        The caller already gated on ENABLE_XVB + the 10th-iteration throttle.
        """
        real_xvb_stats = await asyncio.to_thread(self.xvb_client.get_stats)
        if not real_xvb_stats:
            return  # fetch failed — keep the last reading + last_update frozen so #311 can detect it
        await asyncio.to_thread(self.state_manager.update_xvb_stats, **real_xvb_stats)
        logger.info(f"External Sync: XvB Stats Updated (1h={real_xvb_stats['avg_1h']:.0f} H/s)")

        # v1.7 telemetry backbone (#196 Wave-0): persist the XvB scalars as a time series, wall-
        # clock gated to ~5 min so a change to UPDATE_INTERVAL (which also throttles how often
        # this method is even called) can't silently change the capture cadence.
        now = time.time()
        if now - self._last_xvb_history_write >= _XVB_HISTORY_CAPTURE_SEC:
            xvb = await asyncio.to_thread(self.state_manager.get_xvb_stats)
            await asyncio.to_thread(
                self.state_manager.add_xvb_history,
                now,
                avg_1h=xvb.get("avg_1h", 0.0),
                avg_24h=xvb.get("avg_24h", 0.0),
                fail_count=xvb.get("fail_count", 0),
                donation_fraction=xvb.get("donation_fraction", 0.0),
                mode=xvb.get("current_mode", ""),
            )
            self._last_xvb_history_write = now

    async def _sync_xvb_reward_estimates(self):
        """
        Fetch XvB's published per-tier expected rewards over Tor and cache them (#118).

        Same "no write on failure" contract as ``_sync_xvb_stats``: a failed/unparseable fetch
        returns None, we write NOTHING, and the cached ``last_update`` stays frozen so the dashboard
        detects a stale feed (``xvb_stats_are_stale``) and shows "estimate unavailable" rather than a
        stale-implied-fresh number. Runs off the main data loop (to_thread), on the same 10th-poll
        throttle as the stats sync, so a slow xmrvsbeast.com never blocks live metrics.
        """
        estimates = await asyncio.to_thread(self.xvb_client.get_reward_estimates)
        if not estimates:
            return  # fetch failed / unparseable — keep the last-good estimates + last_update frozen
        await asyncio.to_thread(self.state_manager.set_xvb_reward_estimates, estimates)
        logger.info(f"External Sync: XvB Reward Estimates Updated ({len(estimates)} tiers)")

    async def _sync_xvb_winners(self):
        """
        Mirror XvB's public raffle-winners file into the ``raffle_wins`` table.

        This is the only place raffle WINS are visible — the stats endpoint reports only
        fail_count — so the dashboard reads XvB's published winners log, keeps our wallet's rows
        (matched by XvB's masked form), and persists them idempotently. Each genuinely NEW win
        (add_raffle_wins' insert contract) is announced once in the dashboard log; the chart and
        the XvB card read the table.

        Same "no write on failure" contract as the other XvB syncs: a failed fetch returns None,
        nothing is written, and the gate is NOT stamped so the next 10th poll retries.

        The gate is adaptive (#892): ``_xvb_winners_gate_sec`` picks the fast cadence while a
        won round is plausibly live or at stake, the 30-min baseline otherwise.
        """
        now = time.time()
        xvb = self.state_manager.get_xvb_stats()
        recent_wins = await asyncio.to_thread(
            self.state_manager.get_raffle_wins, now - _XVB_WIN_FRESH_S
        )
        gate = _xvb_winners_gate_sec(
            xvb.get("avg_1h", 0) or 0,
            xvb.get("avg_24h", 0) or 0,
            self.state_manager.get_tiers(),
            max((w.get("ts", 0) or 0 for w in recent_wins), default=0.0),
            now,
        )
        if now - self._last_xvb_winners_sync < gate:
            return
        result = await asyncio.to_thread(self.xvb_client.get_recent_wins)
        if result is None:
            return  # fetch failed — retry next eligible poll; don't stamp the gate
        self._last_xvb_winners_sync = now
        # Same fetched body, second parse (#866/#872): the all-rounds aggregate that makes win
        # odds and realized-reward figures computable. Written only when it parsed to something,
        # so a format change degrades to stale (detectable) rather than an empty-implied-fresh.
        if (result.get("round_stats") or {}).get("types"):
            await asyncio.to_thread(self.state_manager.set_xvb_round_stats, result["round_stats"])
        new_wins = await asyncio.to_thread(self.state_manager.add_raffle_wins, result["wins"])
        for win in new_wins:
            logger.info(
                f"XvB raffle WIN: {win['tier']} round won at "
                f"{format_hashrate(win['hashrate'])} credited (height {win['height']}) 🎉"
            )
            # One Telegram/webhook alert per genuinely new win — add_raffle_wins' idempotent
            # insert contract is what makes this fire-once, same as payout_confirmed.
            await self.alert_service.raffle_win_alert(win["tier"], win["hashrate"])

    async def _maybe_register_xvb(self, shares, p2pool_stats):
        """
        Auto-enter the wallet into the XvB raffle once it's eligible (#263).

        Mining to the XvB pool doesn't enter a wallet — it must be registered against the operator's
        endpoint, which only takes effect once the wallet has a share in the P2Pool PPLNS window. So
        we gate on a PPLNS share existing (same window math as the dashboard/algo) and skip silently
        until then, retrying on the next poll. After the first success we re-register on a daily
        cadence (XVB_REGISTER_INTERVAL_S): registration is idempotent, and re-running picks up the
        operator's newer security-token behaviour and re-enters a long-offline miner cleanly.

        The caller already gated on ENABLE_XVB + the 10th-iteration throttle. Edge cases are handled
        from the endpoint's real contract (see XvbClient.register): "already registered" is the
        idempotent steady state (success); an invalid wallet is permanent (latch + warn, stop
        retrying); transient errors escalate to a "failing" badge only after a few attempts.
        register() routes over Tor.
        """
        # Nothing to do if registration is disabled (XVB_SUBMIT_URL off) or the wallet was already
        # rejected as permanently invalid — both are terminal for this process, skip quietly.
        if not self.xvb_client.submit_url or self._xvb_invalid_wallet:
            return

        # PPLNS-share check — mirrors metrics/algo: a share counts if it's within pplns_window
        # blocks (30s/block on Nano, else 10s) of now.
        pool_type = p2pool_stats.get("p2p", {}).get("type", "Main")
        pplns_window = p2pool_stats.get("pool", {}).get("pplns_window", DEFAULT_PPLNS_WINDOW)
        block_time = pplns_block_time(pool_type)
        if shares_in_pplns_window(shares, pplns_window, block_time) == 0:
            return  # no eligible share yet — the endpoint would no-op, so don't call it

        now = time.time()
        if self._xvb_last_registered is not None and (
            now - self._xvb_last_registered < XVB_REGISTER_INTERVAL_S
        ):
            return  # already registered recently; next re-register isn't due yet

        status = await asyncio.to_thread(self.xvb_client.register)

        if status == REG_OK:
            # Fresh registration OR the idempotent "already registered" steady state — either way the
            # wallet is in the raffle. Stamp it and clear the transient-failure counter.
            self._xvb_last_registered = now
            self._xvb_register_failures = 0
            await asyncio.to_thread(
                self.state_manager.update_xvb_stats,
                registered_at=now,
                registration_state="registered",
            )
            logger.info("External Sync: Registered wallet with XvB raffle ✓")
        elif status == REG_INVALID:
            # Permanent: the endpoint won't accept this wallet, and it won't change on retry. Latch
            # off, warn once, and surface it — don't hammer the endpoint every poll.
            self._xvb_invalid_wallet = True
            logger.warning(
                "XvB registration rejected MONERO_WALLET_ADDRESS as invalid — auto-registration "
                "disabled. The XvB raffle needs a standard primary Monero address (4…). (#263)"
            )
            await asyncio.to_thread(
                self.state_manager.update_xvb_stats, registration_state="invalid"
            )
        elif status == REG_NOT_ELIGIBLE:
            # The share we see locally hasn't propagated to XvB yet — not a failure, just retry next
            # poll. Don't count it toward the "failing" escalation.
            return
        else:
            # Transient (network / 5xx / unrecognised). register() already logged specifics. Only
            # escalate to a dashboard warning once it's *persistently* failing AND we've never
            # succeeded — a blip while the first share propagates shouldn't alarm. (A failed daily
            # re-register after a prior success keeps the "registered ✓"; we're still entered.)
            self._xvb_register_failures += 1
            if (
                self._xvb_last_registered is None
                and self._xvb_register_failures >= _XVB_REGISTER_FAIL_ALERT
            ):
                await asyncio.to_thread(
                    self.state_manager.update_xvb_stats, registration_state="failing"
                )
