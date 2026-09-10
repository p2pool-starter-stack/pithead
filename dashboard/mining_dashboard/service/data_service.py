# ruff: noqa: F401

import asyncio
import logging
import time

from aiohttp import ClientSession

from mining_dashboard.client.tari.tari_client import TariClient
from mining_dashboard.client.xmrig_client import (
    XMRigWorkerClient,
)
from mining_dashboard.collector.containers import get_container_health
from mining_dashboard.collector.logs import get_monero_sync_status
from mining_dashboard.collector.pools import (
    get_network_stats,
    get_p2pool_stats,
    get_stratum_stats,
    get_tari_stats,
)
from mining_dashboard.collector.system import (
    get_cpu_avx2,
    get_cpu_usage,
    get_disk_usage,
    get_hugepages_status,
    get_load_average,
    get_memory_usage,
)
from mining_dashboard.config import config
from mining_dashboard.config.config import (
    DASHBOARD_FAIL_CLOSED,
    ENABLE_XVB,
    GITHUB_RIGFORGE_RELEASES_API,
    HOST_IP,
    MONERO_CLEARNET_SYNC,
    MONERO_WALLET_ADDRESS,
    PAYOUT_CONFIRM_ENABLED,
    REJECT_WORKERS_CONTAINER,
    SYNC_GATE_CONTAINERS,
    TARI_CLEARNET_SYNC,
    TARI_PAYOUT_CONFIRM_ENABLED,
    TARI_REQUIRED,
    UPDATE_INTERVAL,
    low_ram_floor_gb,
    monero_is_local,
    tari_is_local,
)
from mining_dashboard.helper.utils import (
    DEFAULT_PPLNS_WINDOW,
    format_hashrate,
    pplns_block_time,
    shares_in_pplns_window,
)
from mining_dashboard.service import audit_service, payout_sync
from mining_dashboard.service.data_audit import (
    _RIG_EDIT_CAP_PER_HOUR,
    _RIG_EDIT_WINDOW_SEC,
    DataAuditMixin,
)
from mining_dashboard.service.data_gates import DataGateMixin
from mining_dashboard.service.data_helpers import (
    _SHARE_STAT_KEYS,
    _aggregate_hashrate,
    _aggregate_window_hashrates,
    _merge_direct_stats,
    _merge_proxy_summary,
    _normalize_proxy_workers,
    _shares_to_record,
    _summary_deltas,
)
from mining_dashboard.service.data_setup import DataSetupMixin
from mining_dashboard.service.data_xvb_sync import (
    _XVB_REGISTER_FAIL_ALERT,
    DataXvbSyncMixin,
)
from mining_dashboard.service.metrics import build_metrics, share_reject_pct
from mining_dashboard.service.notify.telegram_commands import format_daily_summary

logger = logging.getLogger("DataService")


# Wall-clock cadences stay with the core poll loop that applies them.
_HOURLY_CAPTURE_SEC = 3600
_WORKER_HISTORY_CAPTURE_SEC = 300


class DataService(DataSetupMixin, DataGateMixin, DataXvbSyncMixin, DataAuditMixin):
    """
    Core service responsible for aggregating mining statistics from various sources
    (Local collectors, XMRig Proxy, Tari Node, etc.) and maintaining the application state.
    """

    _last_monero_sync = None  # last real {percent,current,target} — held across RPC blips

    # On a partial-start failure stay held so the next cycle retries.

    async def _sync_prices(self):
        """Refresh the live XMR/XTM prices (#520) into ``latest_data["prices"]`` — a no-op with the
        feed off. The PriceFeed self-throttles and keeps its last good result, so calling this every
        poll is safe; ``build_energy`` swaps the result in for the static config prices."""
        if self.price_feed.enabled:
            self.latest_data["prices"] = await asyncio.to_thread(
                self.price_feed.maybe_fetch, time.time()
            )

    async def _sync_payouts(self):
        """Monero on-chain payout confirmation (#381). The body moved to ``payout_sync`` for #1644;
        this stays as the poll body's call seam, and as the name the tests already reach for."""
        await payout_sync.sync_monero(self.state_manager, self.wallet_client, self.alert_service)

    async def _sync_tari_payouts(self):
        """Tari on-chain payout confirmation (#462) — the sibling of ``_sync_payouts``, same shape
        and same reason for staying here while its body lives in ``payout_sync``."""
        await payout_sync.sync_tari(self.state_manager, self.tari_wallet_client, self.alert_service)

    async def run(self):
        """
        Main execution loop: Aggregates statistics from local collectors and external APIs.
        Updates the `latest_data` state and persists historical metrics to the database.
        """
        logger.info("Service Started: Data Collection Loop")

        iteration_count = 0

        async with ClientSession() as session:
            worker_client = XMRigWorkerClient(session)
            tari_client = TariClient()

            # P2Pool shares are recorded from the cumulative shares_found counter (#129); None until
            # the first poll baselines it, so we never backfill the whole historical count on startup
            # or re-record what the DB already loaded.
            last_known_shares_total = None

            while True:
                try:
                    # 1. Collect Local Statistics (High Frequency Polling)
                    stratum_raw = get_stratum_stats()

                    # 2. Fetch Worker Statistics from XMRig Proxy + normalize the payload.
                    proxy_workers = []
                    try:
                        proxy_data = await asyncio.to_thread(self.proxy_client.get_workers)
                        proxy_workers = _normalize_proxy_workers(proxy_data)
                    except Exception as e:
                        logger.error(f"Proxy Data Fetch Error: {e}")

                    # 2b. Fetch the proxy /summary for pool-wide share totals (Issue #82). Kept
                    # separate from the workers fetch so one failing doesn't blank the other; a bad
                    # poll leaves the last good summary in latest_data — including a malformed body
                    # that returns (not raises), which _merge_proxy_summary guards against (#141).
                    proxy_summary = self.latest_data.get("proxy_summary", {})
                    try:
                        summary_data = await asyncio.to_thread(self.proxy_client.get_summary)
                        proxy_summary = _merge_proxy_summary(proxy_summary, summary_data)
                    except Exception as e:
                        logger.error(f"Proxy Summary Fetch Error: {e}")

                    # 2c. Persist this poll's share-health deltas (#116): what the cumulative
                    # counters gained since the last poll, reset-safe and skipping all-zero rows
                    # (see _summary_deltas). Feeds the reject-rate trend + high_reject_rate alert.
                    if proxy_summary:
                        deltas, self._last_share_totals = _summary_deltas(
                            self._last_share_totals,
                            {k: proxy_summary.get(k, 0) or 0 for k in _SHARE_STAT_KEYS},
                        )
                        if deltas:
                            await asyncio.to_thread(
                                self.state_manager.add_share_stats, time.time(), **deltas
                            )

                    # 3. Augment with Direct Worker Stats (Uptime, Hashrate) via Local API
                    tasks = [worker_client.get_stats(w["ip"], w["name"]) for w in proxy_workers]
                    worker_results = await asyncio.gather(*tasks)

                    # 3a. Reconcile any #185 history row a slow rig rollback left stuck 'accepted'
                    # (#579), and flag a rig-side out-of-band edit (#530) — rides this same poll's
                    # results, no new dial.
                    await self._reconcile_worker_config(proxy_workers, worker_results)

                    # 3a-2. Out-of-band audit (#530): a config.json change not made through the
                    # control channel, plus mirroring the #33 log into the durable audit_events
                    # table so the Security panel can group by hour/day/month. Both are no-ops with
                    # the control channel off.
                    await self._watch_host_config()
                    await self._mirror_control_audit()

                    current_mode = self.state_manager.get_xvb_stats().get("current_mode", "P2POOL")
                    # Determine active pool port for UI badges based on current Algo mode
                    active_pool_port = "3344" if "XVB" in current_mode else "3333"
                    final_workers = _merge_direct_stats(
                        proxy_workers, worker_results, active_pool_port
                    )
                    # 3b. Track per-worker connection lifecycle: fill true uptime for online workers
                    # (#169) and drop stale offline rows past the fall-off window (#182).
                    final_workers = self._lifecycle.update(final_workers, time.time())

                    # 4. Calculate Aggregates (Priority: 15m > 60s > 10s)
                    total_hr, total_h10 = _aggregate_hashrate(final_workers)

                    # 5. Fetch Network & Sync Status
                    network_stats = get_network_stats()
                    tari_stats = get_tari_stats()
                    p2pool_stats = get_p2pool_stats()

                    # v1.7 telemetry backbone (#196 Wave-0): persist a block-found event as a time
                    # series. The #336 alert already detects a new block via this same cumulative
                    # blocks_found counter; `_shares_to_record` re-baselines without backfilling on
                    # the first poll or a p2pool restart (counter goes backwards), so this fires
                    # exactly once per genuinely new block. `difficulty` is tagged from the network
                    # stats at detection time (p2pool exposes no per-block effort figure).
                    blocks_found_total = p2pool_stats["pool"].get("blocks_found", 0) or 0
                    new_blocks, self._last_blocks_found = _shares_to_record(
                        self._last_blocks_found, blocks_found_total
                    )
                    if new_blocks > 0:
                        await asyncio.to_thread(
                            self.state_manager.add_block,
                            time.time(),
                            p2pool_stats["pool"].get("last_block_found", 0) or 0,
                            network_stats.get("difficulty", 0) or 0,
                        )

                    # Record P2Pool shares from the CUMULATIVE shares_found counter, not just
                    # last_share_time: at 30s polls a burst of shares advances the timestamp only
                    # once, dropping the extras. Record the delta as N distinct shares (#129).
                    current_share_ts = p2pool_stats["pool"].get("last_share_time", 0)
                    current_shares_total = p2pool_stats["pool"].get("shares_found", 0)
                    new_shares, last_known_shares_total = _shares_to_record(
                        last_known_shares_total, current_shares_total
                    )
                    if new_shares > 0 and current_share_ts > 0:
                        difficulty = p2pool_stats["pool"].get("difficulty", 0)
                        await asyncio.to_thread(
                            self.state_manager.add_shares, new_shares, current_share_ts, difficulty
                        )

                    monero_sync = await get_monero_sync_status()
                    tari_sync = await tari_client.get_sync_status()

                    # Raw per-node "fully synced" signals for the sync gate (Issue #35),
                    # captured BEFORE the network-height UI override below. A node counts as
                    # synced only when it's reachable AND not syncing — an unreachable node
                    # reports is_syncing=False too, and we must not mistake that for synced
                    # (that's what #31's node-down handling is for). Reading the raw signal
                    # also avoids a deadlock: the height override is fed by p2pool's stats
                    # file, which reads 0 while p2pool is held — falsely "syncing" forever.
                    monero_synced = monero_sync.get("reachable", True) and not monero_sync.get(
                        "is_syncing", False
                    )
                    tari_synced = tari_sync.get("reachable", True) and not tari_sync.get(
                        "is_syncing", False
                    )

                    # Auto-transition a clearnet initial-sync node back to Tor once it's synced
                    # (#234). Reuses the synced signals above; the supervisor writes a persistent
                    # marker + restarts the daemon (which then comes up Tor-only). Returns whether
                    # each chain is still EXPOSED on clearnet, for the UI banner.
                    monero_clearnet_exposed = await self.clearnet_supervisor.maybe_transition(
                        "monero", "monerod", MONERO_CLEARNET_SYNC, monero_synced
                    )
                    tari_clearnet_exposed = await self.clearnet_supervisor.maybe_transition(
                        "tari", "tari", TARI_CLEARNET_SYNC, tari_synced
                    )
                    self.clearnet_sync_state = {
                        "monero": monero_clearnet_exposed,
                        "tari": tari_clearnet_exposed,
                        "active": monero_clearnet_exposed or tari_clearnet_exposed,
                    }

                    # Apply Sync Logic Overrides
                    # 1. Monero Sync Check
                    if all(k in monero_sync for k in ("percent", "current", "target")):
                        # A real reading — remember it, so a later blip has something to hold.
                        self._last_monero_sync = {
                            k: monero_sync[k] for k in ("percent", "current", "target")
                        }
                    if network_stats.get("height", 0) == 0:
                        monero_sync["is_syncing"] = True
                        if "percent" not in monero_sync:
                            # An RPC blip mid-sync must not reset the card: monerod grinding
                            # at 99% flashed "Synced 0 / 1" whenever a poll came back empty
                            # (bench-reported). Hold the last real figures; the bare
                            # placeholder is only for a machine that has never reported any.
                            monero_sync.update(
                                self._last_monero_sync or {"percent": 0, "current": 0, "target": 1}
                            )

                    # 2. Global Sync Logic. monerod always drives the full-screen Sync Mode;
                    # Tari does so only when it's required (Issue #51). A non-blocking Tari
                    # (dashboard.tari_required:false) keeps the operational view and surfaces
                    # its progress in the Tari panel instead of hijacking the whole dashboard.
                    is_monero_syncing = monero_sync.get("is_syncing", False)
                    is_tari_syncing = tari_sync.get("is_syncing", False)
                    global_sync = is_monero_syncing or (is_tari_syncing and TARI_REQUIRED)
                    # True when Tari is syncing but we're staying in the operational view — the
                    # UI shows a "Tari syncing" indicator rather than the takeover screen.
                    tari_syncing_passive = is_tari_syncing and not global_sync

                    if global_sync:
                        if not is_monero_syncing and "percent" not in monero_sync:
                            h = network_stats.get("height", 1)
                            monero_sync.update({"percent": 100, "current": h, "target": h})
                        if not is_tari_syncing and "percent" not in tari_sync:
                            h = tari_stats.get("height", 0)
                            tari_sync.update({"percent": 100, "current": h, "target": h})

                    # 3. Node-down detection + worker rejection (Issue #31). Debounce each
                    # node's live reachability into a stable DOWN flag; monerod-down always
                    # rejects, Tari-down never does — Tari stays visible in its own panel/alerts.
                    monero_down = self.monero_health.update(monero_sync.get("reachable", True))
                    tari_down = self.tari_health.update(tari_sync.get("reachable", True))
                    monero_sync["down"] = monero_down
                    tari_sync["down"] = tari_down

                    # 3b. Peer-loss staleness (#972): monerod can survive a tor restart with
                    # every SOCKS peer dead — reachable, healthcheck green, height creeping,
                    # but `synchronized: false` for hours. The RPC path is the only one that
                    # carries the flag; absence (log-scrape fallback, remote node) is no
                    # verdict, so the monitor isn't fed and its streaks stay put.
                    monero_reports_synced = monero_sync.get("synchronized")
                    if monero_reports_synced is not None:
                        self.monero_sync_stale.update(monero_reports_synced)
                    monero_stale = self.monero_sync_stale.down
                    monero_sync["stale"] = monero_stale

                    # 4. Sync gate (Issue #35): hold p2pool + xmrig-proxy until the required
                    # chain(s) first sync, then release. monerod must be synced; Tari must be
                    # synced too unless it's non-blocking. #31's runtime failover only applies
                    # once released — before that there are no workers to fail over, and it
                    # keeps the two features from both driving xmrig-proxy.
                    await self._apply_sync_gate(
                        monero_synced and (tari_synced or not TARI_REQUIRED)
                    )
                    if self.miner_released:
                        await self._apply_worker_rejection(monero_down)

                    # 5. Operator alerts (Issues #121/#45): push debounced node/worker/sync/host
                    # edges to Telegram. Consumes the flags computed above; worker presence is only
                    # tracked while the proxy is actually serving (miner released and not rejected) —
                    # its intentional absence otherwise must not read as offline. Disk usage is read
                    # once here and reused in the snapshot below. No-op unless Telegram is configured;
                    # never raises.
                    disk_usage = get_disk_usage()
                    # Host-perf snapshot (#104), read once and reused for both the alerts and the
                    # system panel below. Cheap /proc reads.
                    hugepages = get_hugepages_status()
                    memory = get_memory_usage()
                    avx2 = get_cpu_avx2()
                    db_healthy = self.state_manager.is_db_healthy()
                    # Fetch fresh shares list (also used to populate the UI below) so the PPLNS-share
                    # gate the XvB alert watches is computed from the same figure the dashboard shows.
                    shares_list = await asyncio.to_thread(self.state_manager.get_shares)
                    pool_local = p2pool_stats.get("pool", {})
                    pool_type = p2pool_stats.get("p2p", {}).get("type", "Main")
                    shares_in_window = shares_in_pplns_window(
                        shares_list,
                        pool_local.get("pplns_window", DEFAULT_PPLNS_WINDOW),
                        pplns_block_time(pool_type),
                    )
                    # Build the domain metrics once per cycle for the alerter — but only when the
                    # bot is actually on, so the default (Telegram-off) stack pays nothing. Reused
                    # for the hashrate-low edge and the daily digest.
                    alert_metrics = (
                        build_metrics(self.latest_data, self.state_manager)
                        if self.alert_service.enabled
                        else None
                    )
                    # Per-container restart/health snapshot for the crash-loop/unhealthy alert
                    # (#337) — 9 inspect calls against the read-only docker-proxy, skipped
                    # entirely while Telegram is off AND dashboard.fail_closed is off (same cost
                    # discipline as alert_metrics). fail_closed needs it even with Telegram off:
                    # it's the only source for "is the dashboard container itself crash-looping"
                    # (#490).
                    container_states = (
                        await get_container_health()
                        if (self.alert_service.enabled or DASHBOARD_FAIL_CLOSED)
                        else {}
                    )
                    await self.alert_service.process(
                        monero_down=monero_down,
                        # Debounced "reachable but out of sync" (#972) — the 0-peer strand
                        # after a tor restart that node-down can't see.
                        monero_stale=monero_stale,
                        tari_down=tari_down,
                        tari_required=TARI_REQUIRED,
                        miner_released=self.miner_released,
                        # The same worker rows the dashboard shows; the monitor reads each rig's
                        # status (DOWN = offline) so alerts line up with the on-screen state.
                        workers=final_workers,
                        workers_expected=self.miner_released and not self.workers_rejected,
                        disk_percent=(disk_usage or {}).get("percent", 0) or 0,
                        db_healthy=db_healthy,
                        # DB self-heal one-shot (#489): a monotonic counter + the last reset's detail,
                        # so the alerter fires exactly once when a corrupt DB was quarantined + reset.
                        db_reset_seq=self.state_manager.db_reset_count,
                        db_reset_detail=self.state_manager.last_db_reset,
                        xvb_enabled=ENABLE_XVB,
                        shares_in_window=shares_in_window,
                        clearnet_active=bool(self.clearnet_sync_state.get("active")),
                        xvb_registration_state=(self.state_manager.get_xvb_stats() or {}).get(
                            "registration_state", ""
                        ),
                        # From the previous cycle's snapshot (the update check writes it below); a
                        # one-cycle lag is fine for a one-shot "new release" ping.
                        update_available=bool(
                            (self.latest_data.get("update") or {}).get("available")
                        ),
                        low_hr_warning=bool(alert_metrics and alert_metrics.low_hr_warning),
                        # Persistent host-perf conditions (#104). HugePages "Disabled" = not
                        # reserved (recoverable via reboot); low_ram compares live total to the
                        # threshold. avx2 is badge-only (no alert), so it isn't passed here.
                        hugepages_reserved=(hugepages[0] != "Disabled"),
                        low_ram=(
                            0
                            < (memory.get("total_gb") or 0)
                            < low_ram_floor_gb(monero_is_local(), tari_is_local())
                        ),
                        # Trailing-1h reject rate from the delta series (#116); None while no
                        # shares were submitted in the window, which the edge treats as "no
                        # verdict" rather than healthy.
                        reject_rate_1h=share_reject_pct(self.state_manager.get_share_stats(), 3600),
                        # Payout-wallet tripwire (#375): what p2pool itself reports mining to —
                        # the same stratum field the dashboard's Stratum card shows — with the
                        # env address as fallback while p2pool is down/restarting. Empty => no-op.
                        observed_wallet=stratum_raw.get("wallet") or MONERO_WALLET_ADDRESS,
                        # Block-found / payout-found edges (#336): p2pool's cumulative pool-wide
                        # block counter and the height of the last one. 0 while the stats file is
                        # missing/unparsable, which the edge treats as a silent rebaseline.
                        blocks_found_total=pool_local.get("blocks_found", 0) or 0,
                        block_height=pool_local.get("last_block_found", 0) or 0,
                        # Container crash-loop / stuck-unhealthy edges (#337), read above from
                        # the read-only docker-proxy.
                        containers=container_states,
                    )
                    # 5b. Fail-closed miner hold (#490), opt-in via dashboard.fail_closed. Reads
                    # the DB auto-heal outcome and the dashboard's OWN crash-loop state — both
                    # narrow, non-transient "unrecoverable" signals — off the trackers `process`
                    # above just fed (see `_apply_fail_closed_gate` for what counts and why).
                    await self._apply_fail_closed_gate(
                        self.state_manager.is_db_unrecoverable()
                        or self.alert_service.containers.is_confirmed_bad("dashboard")
                    )
                    # Once-daily status digest, reusing the metrics built above (only when the bot
                    # is on, which is also the only time maybe_daily_summary would send).
                    await self.alert_service.maybe_daily_summary(
                        time.time(),
                        # bind this cycle's metrics (the provider runs within this iteration); drain
                        # the day's incident tally into the digest (#342).
                        lambda m=alert_metrics: format_daily_summary(
                            m,
                            self.latest_data,
                            HOST_IP,
                            incidents=self.alert_service.drain_incidents(),
                        ),
                    )
                    # 6. Degradation detector (#99): a sustained total-hashrate drop / recovery is
                    # persisted as a chart event marker and pushed as a hashrate_loss alert.
                    deg_edge = self.degradation.update(total_hr)
                    if deg_edge:
                        kind, drop_frac, _baseline, current = deg_edge
                        if kind == "loss":
                            ev_type = "hashrate_loss"
                            detail = (
                                f"Hashrate −{drop_frac * 100:.0f}% ({format_hashrate(current)})"
                            )
                        else:
                            ev_type = "hashrate_recovered"
                            detail = f"Hashrate recovered ({format_hashrate(current)})"
                        await asyncio.to_thread(
                            self.state_manager.add_event, time.time(), ev_type, detail
                        )
                        await self.alert_service.degradation_alert(kind, drop_frac)

                    self.latest_data.update(
                        {
                            "workers": final_workers,
                            "proxy_summary": proxy_summary,
                            "shares": shares_list,
                            "total_live_h15": total_hr,
                            "total_live_h10": total_h10,
                            "pool": p2pool_stats,
                            "network": network_stats,
                            "tari": tari_stats,
                            "monero_sync": monero_sync,
                            "tari_sync": tari_sync,
                            "global_sync": global_sync,
                            "tari_syncing_passive": tari_syncing_passive,
                            "workers_rejected": self.workers_rejected,
                            "miner_released": self.miner_released,
                            "miner_held": self.miner_held,
                            "fail_closed_held": self.fail_closed_held,
                            "clearnet_sync": self.clearnet_sync_state,
                            "system": {
                                "disk": disk_usage,
                                "hugepages": hugepages,
                                "memory": memory,
                                "avx2": avx2,
                                "load": get_load_average(),
                                "cpu_percent": get_cpu_usage(),
                            },
                            "stratum": stratum_raw,
                            "timestamp": time.time(),
                        }
                    )

                    # 6. Persist Historical Data
                    is_xvb = "XVB" in current_mode
                    p2pool_hr = 0 if is_xvb else total_hr
                    xvb_hr = total_hr if is_xvb else 0

                    # Per-window splits for the chart's averaging-window toggle (#168). At any poll the
                    # algo routes the whole total to one pool, so each window's total goes entirely to
                    # the same band as the headline (10m is persisted as the base total_hr above).
                    window_totals = _aggregate_window_hashrates(final_workers)
                    window_splits = {
                        win: ((0, total) if is_xvb else (total, 0))
                        for win, total in window_totals.items()
                    }

                    await asyncio.to_thread(
                        self.state_manager.update_history,
                        total_hr,
                        p2pool_hr,
                        xvb_hr,
                        window_splits,
                    )

                    # Create a lightweight snapshot (exclude shares entirely as they are safely in DB)
                    snapshot_data = self.latest_data.copy()
                    snapshot_data.pop("shares", None)
                    await asyncio.to_thread(self.state_manager.save_snapshot, snapshot_data)

                    # 6a2. v1.7 telemetry backbone (#196 Wave-0), hourly wall-clock gate: monerod
                    # DB size + host disk usage (disk_growth, permanent) and Monero
                    # difficulty/height/reward + pool hashrate (network_history, 90-day
                    # retention). Both DB-only — nothing reads either per-cycle.
                    now_ts = time.time()
                    if now_ts - self._last_hourly_capture >= _HOURLY_CAPTURE_SEC:
                        await asyncio.to_thread(
                            self.state_manager.add_disk_growth,
                            now_ts,
                            monero_db_bytes=monero_sync.get("db_size", 0) or 0,
                            disk_used_gb=(disk_usage or {}).get("used_gb", 0) or 0,
                            disk_total_gb=(disk_usage or {}).get("total_gb", 0) or 0,
                        )
                        await asyncio.to_thread(
                            self.state_manager.add_network_history,
                            now_ts,
                            difficulty=network_stats.get("difficulty", 0) or 0,
                            height=network_stats.get("height", 0) or 0,
                            reward=network_stats.get("reward", 0) or 0,
                            pool_hashrate=pool_local.get("hashrate", 0) or 0,
                        )
                        self._last_hourly_capture = now_ts

                    # 6a3. v1.7 telemetry backbone (#196 Wave-0), ~5 min wall-clock gate:
                    # per-worker hashrate/share history, batched into ONE executemany call rather
                    # than N inserts per cycle. 30-day retention.
                    if now_ts - self._last_worker_capture >= _WORKER_HISTORY_CAPTURE_SEC:
                        worker_rows = [
                            {
                                "ts": now_ts,
                                "name": w.get("name", ""),
                                "h15": w.get("h15", 0) or 0,
                                "accepted": w.get("accepted", 0) or 0,
                                "rejected": w.get("rejected", 0) or 0,
                            }
                            for w in final_workers
                            if w.get("status") == "online"
                        ]
                        if worker_rows:
                            await asyncio.to_thread(
                                self.state_manager.add_worker_history, worker_rows
                            )
                        self._last_worker_capture = now_ts

                    # 6b. Healthchecks.io dead-man's switch (Issue #79). Ping each cycle so the
                    # external monitor alerts on the *absence* of a ping if the host ever dies
                    # (power loss, crash, NIC death) — a pure "is the stack alive" liveness signal.
                    # Node-health alerting (a node down while the box is up) is out of scope here;
                    # that's the Telegram alerter's job (#121). The client throttles and fails
                    # silently; `enabled` is just "a ping URL is set", so an unconfigured stack
                    # never pings.
                    if self.healthchecks.enabled:
                        await asyncio.to_thread(self.healthchecks.ping)

                    # 6c. Tor guard self-heal (#424): when opted in, probe Tor clearnet egress
                    # (self-throttled) and restart tor if it's stuck on a failing guard —
                    # bounded, cooled-down, loud. Off (the default) this is a plain no-op.
                    await self.tor_healer.check()

                    # 7. External XvB stats sync over Tor (#163), throttled to every 10th iteration,
                    # and ONLY when XvB is enabled — disabling XvB must stop the egress entirely.
                    if ENABLE_XVB and iteration_count % 10 == 0:
                        await self._sync_xvb_stats()

                        # 7a. XvB published per-tier reward estimates (#118) — same throttle/egress
                        # (Tor, every 10th poll, XvB-enabled only) so the tier-payout comparison in
                        # the earnings card is current without an extra fetch cadence.
                        await self._sync_xvb_reward_estimates()

                        # 7b. XvB raffle auto-registration (#263). Rides the same throttle/egress as
                        # the stats sync (Tor, every 10th poll, XvB-enabled only). Gated on a PPLNS
                        # share existing — before then the endpoint is a no-op, so we just retry.
                        await self._maybe_register_xvb(shares_list, p2pool_stats)

                        # 7c. XvB raffle winners. Rides the same throttle/egress, with its own
                        # 30-min wall-clock gate inside (the winners file updates ~hourly).
                        await self._sync_xvb_winners()

                    # 7d. On-chain payout confirmation (#381), every 10th poll (~5 min). Independent
                    # of XvB — gated on the view-only wallet-rpc being configured (local node + view
                    # key). Polls get_transfers, persists new confirmed payouts, fires one alert each.
                    #
                    # 7d/7e are the only steps in this body wrapped per-step (#1644): both take no
                    # poll local and write no `self` attribute, so a failure in one cannot leave a
                    # later step reading half-written state. Everything above stays under the single
                    # handler below — see `payout_sync` for why widening this is its own change.
                    if self.wallet_client is not None and iteration_count % 10 == 0:
                        await payout_sync.run_isolated("Monero payout sync", self._sync_payouts)

                    # 7e. Tari on-chain payout confirmation (#462), same cadence — gated on the
                    # view-only Tari console wallet being configured (local node + tari view key).
                    if self.tari_wallet_client is not None and iteration_count % 10 == 0:
                        await payout_sync.run_isolated("Tari payout sync", self._sync_tari_payouts)

                    # 8. New-release check over Tor (#224) — ONLY when explicitly enabled (default off,
                    # so the appliance never phones GitHub unbidden). The checker self-throttles to
                    # hourly and returns the cached result; surfaced as state.update for the header badge.
                    if self.update_checker.enabled:
                        self.latest_data["update"] = await asyncio.to_thread(
                            self.update_checker.maybe_check, time.time()
                        )
                    # 8b. The RigForge counterpart (#596): cache the latest RigForge release
                    # (raw {tag, url}); build_workers derives each rig's badge from it. Written
                    # unconditionally — the accessor returns None without dialing when the check
                    # is disabled, so a snapshot-restored release can't outlive a flag flip.
                    self.latest_data["rigforge_release"] = await asyncio.to_thread(
                        self.rigforge_update_checker.latest_release_cached, time.time()
                    )

                    # 9. Live XMR/XTM prices over Tor (#520) — ONLY when dashboard.energy.price_feed
                    # is set (default off, so the appliance never dials CoinGecko unbidden). The
                    # feed self-throttles (15 min) and keeps the last good prices on failure;
                    # surfaced as state.energy price fields via build_energy.
                    await self._sync_prices()
                except Exception as e:
                    logger.error(f"Data Collection Error: {e}")
                finally:
                    # #1637 — the `% 10 == 0` gates above must advance even when the body raised.
                    # A frozen counter reruns the failing step EVERY poll instead of one in ten.
                    iteration_count += 1
                await asyncio.sleep(UPDATE_INTERVAL)
