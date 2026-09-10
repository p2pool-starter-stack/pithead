import logging
import os

from mining_dashboard.client.docker.docker_control import DockerControl
from mining_dashboard.client.monero.monero_wallet_client import MoneroWalletClient
from mining_dashboard.client.tari.tari_wallet_client import TariWalletClient
from mining_dashboard.config.config import (
    CHECK_FOR_UPDATES,
    CLEARNET_STATE_DIR,
    DASHBOARD_ENERGY,
    GITHUB_RELEASES_API,
    GITHUB_RIGFORGE_RELEASES_API,
    HASHRATE_DROP_MINUTES,
    HASHRATE_DROP_THRESHOLD_PCT,
    NODE_STALE_AFTER_SEC,
    TOR_SOCKS_PROXY,
    UPDATE_CHECK_INTERVAL,
    WORKER_FALLOFF_SEC,
)
from mining_dashboard.service.data_helpers import (
    WorkerLifecycle,
)
from mining_dashboard.service.health.degradation import DegradationMonitor
from mining_dashboard.service.health.node_health import NodeHealthMonitor
from mining_dashboard.service.health.tor_heal import TorEgressHealer
from mining_dashboard.service.health.update_checker import GitHubReleaseClient, UpdateChecker
from mining_dashboard.service.network.clearnet_sync import ClearnetSyncSupervisor
from mining_dashboard.service.notify.alert_service import AlertService
from mining_dashboard.service.notify.healthchecks import HealthchecksClient
from mining_dashboard.service.xvb.price_feed import CoinGeckoClient, PriceFeed

logger = logging.getLogger("DataService")


def _runtime():
    from mining_dashboard.service import data_service

    return data_service


class DataSetupMixin:
    def __init__(self, state_manager, proxy_client, xvb_client):
        self.state_manager = state_manager
        self.proxy_client = proxy_client
        self.xvb_client = xvb_client
        # Per-worker connection tracking for true uptime (#169) + stale-row fall-off (#182).
        self._lifecycle = WorkerLifecycle(WORKER_FALLOFF_SEC)
        # New-release check (#224): off unless dashboard.check_for_updates is set. Routed over the
        # bridge Tor SOCKS (reusing TOR_SOCKS_PROXY) so it can't reveal the host IP to GitHub.
        self.update_checker = UpdateChecker(
            GitHubReleaseClient(GITHUB_RELEASES_API, TOR_SOCKS_PROXY),
            (os.environ.get("PITHEAD_VERSION") or "").strip(),
            enabled=CHECK_FOR_UPDATES,
            interval=UPDATE_CHECK_INTERVAL,
        )
        # RigForge latest-release check (#596): the same flag, throttle and Tor route, pointed at
        # the RigForge repo. ONE fleet-wide fetch — the per-worker "rig is behind" verdict is
        # derived at the render seam from each rig's live reported version, never stored (#664).
        self.rigforge_update_checker = UpdateChecker(
            GitHubReleaseClient(GITHUB_RIGFORGE_RELEASES_API, TOR_SOCKS_PROXY),
            None,
            enabled=CHECK_FOR_UPDATES,
            interval=UPDATE_CHECK_INTERVAL,
        )
        # Live XMR/XTM price feed (#520's auto half): off unless dashboard.energy.price_feed is
        # set. Same Tor SOCKS route as the update check — CoinGecko only ever sees a Tor exit.
        self.price_feed = PriceFeed(
            CoinGeckoClient(DASHBOARD_ENERGY["currency"], TOR_SOCKS_PROXY),
            enabled=DASHBOARD_ENERGY["price_feed"],
        )
        # Share-health delta baseline (#116): the previous poll's cumulative proxy /summary
        # totals; None until the first poll seeds it (and again after a counter reset).
        self._last_share_totals = None
        # v1.7 telemetry backbone (#196 Wave-0) capture-cadence state — see the _*_CAPTURE_SEC
        # constants above. `_last_blocks_found` baselines the cumulative pool blocks_found
        # counter (reused via `_shares_to_record`, same re-baseline-on-restart contract as
        # shares); the `_last_*` wall-clock stamps start at 0.0 so each series captures on its
        # first eligible poll.
        self._last_blocks_found = None
        self._last_xvb_history_write = 0.0
        self._last_hourly_capture = 0.0
        self._last_worker_capture = 0.0
        # Out-of-band audit watcher (#530): the last config.json snapshot this poll loop read
        # (None until the first poll baselines it — never diff against nothing, same "re-baseline,
        # never backfill" contract as every other watcher here) and the wall-clock of that read, so
        # a later change can be checked against control.log entries that landed AFTER it.
        self._last_host_config = None
        self._last_host_check = 0.0
        # (worker, change_id) pairs already recorded as a rig-edit this run, so a rig that keeps
        # reporting the same terminal change_id in its /status mirror every poll is flagged ONCE,
        # not on every ~30s cycle. In-memory only: the deterministic audit-row id below is what
        # actually bounds the table across restarts (INSERT OR IGNORE); this just skips the
        # redundant DB work in the steady state. Bounded by the count of distinct real rig edits.
        self._flagged_rig_changes = set()
        # Per-worker fixed-window flood cap on NEW rig-edit rows (#724): {worker: (window_start,
        # count)}. Distinct change_ids clear #530's deterministic-id dedup, so a rogue rig can
        # spam a permanent audit row every poll; this bounds them to _RIG_EDIT_CAP_PER_HOUR per
        # worker per hour. In-memory like _flagged_rig_changes — a restart resets the window, which
        # at worst grants one extra window's budget, still bounded per wall-hour.
        # A device rotating the worker NAME each poll used to sidestep this per-worker cap; the
        # map is bounded to a fixed number of live names since #1695 (worker_change_audit.
        # admit_worker). The broader unauth-feed vector this was once deferred to is still #235.
        self._rig_edit_window = {}
        # Wall-clock of the first name that ceiling refused in the current saturation episode, None
        # while a slot is free. Gives the refusal ONE marker per episode the way first_over does per
        # worker, and is cleared the moment a new name is admitted again.
        self._rig_edit_names_over = None
        # XvB raffle-winners mirror: wall-clock of the last successful winners-file read. Starts
        # at 0.0 so the first eligible poll reads it; NOT stamped on a failed fetch, so a failure
        # retries on the next 10th poll instead of waiting out the 30-min gate.
        self._last_xvb_winners_sync = 0.0
        # XvB raffle auto-registration (#263): wall-clock of the last successful register() call,
        # None until the wallet is first entered. Drives the daily re-register cadence below.
        self._xvb_last_registered = None
        # Consecutive transient register() failures while never-yet-registered (drives the "failing"
        # badge), and a latch that stops retrying once the endpoint calls the wallet invalid — a
        # permanent error that won't fix itself on retry (#263).
        self._xvb_register_failures = 0
        self._xvb_invalid_wallet = False

        self.latest_data = {
            "workers": [],
            "proxy_summary": {},
            "total_live_h15": 0,
            "total_live_h10": 0,
            "pool": {"p2p": {}, "pool": {}},
            "network": {},
            "system": {},
            "tari": {},
            "stratum": {},
            "monero_sync": {},
            "tari_sync": {},
            "global_sync": False,
            "tari_syncing_passive": False,
            "workers_rejected": False,
            "miner_released": False,
            "miner_held": False,
            "fail_closed_held": False,
            "timestamp": 0,
        }

        # Node-down detection + optional worker rejection (Issue #31).
        self.docker_control = DockerControl()
        self.monero_health = NodeHealthMonitor()
        self.tari_health = NodeHealthMonitor()
        # Peer-loss staleness (#972): the same debounce machine, fed monerod's own
        # `synchronized` flag instead of reachability. "Ever synchronized" plays the ever-up
        # guard, so a node mid-initial-sync (synchronized false for days) never alarms; only a
        # node that WAS in sync and stayed out for NODE_STALE_AFTER_SEC trips `down` (= stale).
        self.monero_sync_stale = NodeHealthMonitor(down_after=NODE_STALE_AFTER_SEC)

        # Healthchecks.io dead-man's switch (Issue #79). Disabled by default — when off this is
        # a no-op. When on, each cycle pings a unique URL; the alert fires externally on the
        # *absence* of a ping, so it survives a host death the in-stack notifier can't report.
        self.healthchecks = HealthchecksClient.from_config()

        # Auto-transition a clearnet initial-sync node back to Tor once it's synced (#234). Reuses
        # the same docker control proxy as the #31 failover (start/stop only). on_transition surfaces
        # the event into the snapshot so the UI/status can reflect "switched back to Tor".
        self.clearnet_supervisor = ClearnetSyncSupervisor(
            CLEARNET_STATE_DIR,
            self.docker_control,
            on_transition=self._on_clearnet_transition,
        )
        # Per-chain "currently exposed on clearnet" flags, surfaced in the snapshot for the UI/banner.
        self.clearnet_sync_state = {"monero": False, "tari": False, "active": False}

        # Notifications-only Telegram alerter (Issue #121). Consumes the loop's existing edges
        # (node down/recovered, sync gate open) plus a debounced per-worker presence tracker.
        # Disabled unless telegram.enabled + bot_token + chat_id are configured, so this is a
        # cheap no-op for the default stack. The payout-wallet tripwire baseline (#375) is backed
        # by the SQLite kv_store, not AlertService memory — `apply` recreates this container, and
        # an in-memory baseline would silently re-seed to a tampered wallet.
        self.alert_service = AlertService(
            kv_get=self.state_manager.get_kv, kv_set=self.state_manager.set_kv
        )
        # On-chain payout confirmation (#381): a view-only wallet-rpc client, polled on the slow
        # cadence below. Only constructed when the feature is on (view key set on a local node);
        # off, this stays None and no payout polling ever runs.
        self.wallet_client = MoneroWalletClient() if _runtime().PAYOUT_CONFIRM_ENABLED else None
        # Tari on-chain payout confirmation (#462): a view-only console-wallet gRPC client, polled on
        # the same slow cadence. Only constructed when the Tari feature is on (tari view key set on a
        # local Tari node); off, this stays None and no Tari payout polling ever runs.
        self.tari_wallet_client = (
            TariWalletClient() if _runtime().TARI_PAYOUT_CONFIRM_ENABLED else None
        )
        # Tor guard self-heal (#424), opt-in via tor.auto_heal — a no-op (no probes, no
        # restarts) unless enabled. Reuses the #31 docker-control proxy (start/stop only)
        # to restart tor when clearnet egress is stuck on a failing guard; the recovery
        # note rides the Telegram notifier, which works again exactly when the heal worked.
        self.tor_healer = TorEgressHealer(
            self.docker_control, notify=self.alert_service.tor_heal_alert
        )
        # Hashrate-degradation detector (Issue #99): flags a sustained total-hashrate drop and its
        # recovery. Runs every cycle (cheap, self-contained EMA baseline) so it can mark the chart
        # even with Telegram off; a loss also drives a hashrate_loss alert.
        self.degradation = DegradationMonitor(
            threshold_frac=HASHRATE_DROP_THRESHOLD_PCT / 100,
            sustained_sec=HASHRATE_DROP_MINUTES * 60,
        )
        # True while we've stopped the proxy to reject workers. Persisted in the snapshot so
        # a dashboard restart mid-outage still readmits workers once the node recovers.
        self.workers_rejected = False

        # Hold the miner (p2pool + xmrig-proxy) until the required chain(s) finish syncing
        # (Issue #35). One-way latch: `miner_released` flips True the first time the gate is
        # satisfied, and we never re-hold after that (a later node blip is #31's job, which
        # stops only xmrig-proxy so p2pool keeps its sidechain position). Persisted so a
        # restart mid-sync keeps holding, and a restart after release doesn't re-stop a
        # running, mining stack. `miner_held` is transient UI/log state, not persisted.
        self.miner_released = False
        self.miner_held = False

        # Opt-in fail-closed miner hold on an UNRECOVERABLE health failure (#490), dashboard.
        # fail_closed, default false — see `_apply_fail_closed_gate`. Transient like `miner_held`,
        # not persisted: a restart re-derives it from the current health signals.
        self.fail_closed_held = False

        # Restore persistent state from DB to prevent empty dashboard on service restart
        loaded_snapshot = self.state_manager.load_snapshot()
        if loaded_snapshot and isinstance(loaded_snapshot, dict):
            # Derived state must not outlive its inputs across a restart (#664): `update` is a
            # pure function of (running version, latest tag), and the running version may have
            # JUST changed — the very upgrade the restored badge advertised. The checker
            # recomputes it on its own cadence; never resurrect the pre-upgrade banner.
            loaded_snapshot.pop("update", None)
            # Same rule for the fleet-wide RigForge release (#596): with the flag now off, a
            # restored `rigforge_release` would keep serving stale per-worker badges until the
            # first poll cycle. The checker re-fetches on its cadence; drop it on restore.
            loaded_snapshot.pop("rigforge_release", None)
            for worker in loaded_snapshot.get("workers", []):
                rigforge = worker.get("rigforge") or {}
                if rigforge and "generated_at" not in rigforge:
                    rigforge["stale"] = True
            self.latest_data.update(loaded_snapshot)
            self.workers_rejected = bool(self.latest_data.get("workers_rejected", False))
            self.miner_released = bool(self.latest_data.get("miner_released", False))
