import asyncio
import logging
import time

from mining_dashboard.config.config import (
    HOST_IP,
    TELEGRAM_BOT_TOKEN,
    TELEGRAM_CHAT_ID,
    TELEGRAM_DAILY_SUMMARY_TIME,
    TELEGRAM_ENABLED,
    TELEGRAM_EVENTS,
)
from mining_dashboard.helper.utils import format_hashrate
from mining_dashboard.service.health.container_health import ContainerHealthMonitor
from mining_dashboard.service.notify.alert_edges import AlertEdgesMixin
from mining_dashboard.service.notify.notify_sinks import config_sinks
from mining_dashboard.service.notify.telegram_notifier import TelegramNotifier
from mining_dashboard.service.workers.worker_presence import WorkerPresenceMonitor

logger = logging.getLogger("AlertService")

# Trailing-1h reject rate (percent) above which the high_reject_rate alert fires (#116). Matches
# the dashboard's presentational _REJECT_FLAG_RATE (5%) so the alert and the on-screen warning
# flag agree on what "high" means.
REJECT_ALERT_PCT = 5.0


def build_default_notifier():
    """Construct the Telegram notifier from the process config (Issue #121)."""
    return TelegramNotifier(
        enabled=TELEGRAM_ENABLED,
        bot_token=TELEGRAM_BOT_TOKEN,
        chat_id=TELEGRAM_CHAT_ID,
        events=TELEGRAM_EVENTS,
    )


def _parse_hhmm(value):
    """Parse a 'HH:MM' 24-hour string to minutes-since-midnight, or None if malformed (which
    disables the daily digest rather than guessing a time)."""
    try:
        hh, mm = (value or "").strip().split(":")
        h, m = int(hh), int(mm)
        if 0 <= h < 24 and 0 <= m < 60:
            return h * 60 + m
    except (ValueError, AttributeError):
        pass
    return None


class AlertService(AlertEdgesMixin):
    """
    Turns the data loop's per-cycle signals into a small set of debounced operator alerts and
    fans them out to the configured sinks: Telegram (Issue #121) plus any webhook/ntfy sinks
    (#380). Notifications-only — no interactive bot (#45).

    It *consumes* signals the loop already computes rather than re-collecting anything:

    - **node down / recovered** — transitions of ``NodeHealthMonitor``'s debounced ``down``
      flag per node (#31). Tari is only alerted when it's treated as required; a non-blocking
      Tari going down isn't operator-critical (we keep mining Monero), matching the
      worker-rejection rule.
    - **node out of sync / back in sync** — the debounced peer-loss strand (#972): monerod
      reachable and healthy-looking but reporting ``synchronized: false`` past the stale
      threshold (a tor restart kills its SOCKS peers and it doesn't re-dial). Rides the
      ``node_down``/``node_recovered`` toggles — same conversation, different failure mode.
    - **sync finished** — the sync gate's ``miner_released`` latch flipping open once (#35).
    - **worker offline / back online / joined / left** — a debounced :class:`WorkerPresenceMonitor`
      over the live worker rows (offline keys off the same DOWN status the dashboard shows; joined /
      left track fleet membership).
    - **disk filling / critical** — the data disk crossing the same ``DISK_WARN_PERCENT`` /
      ``DISK_CRITICAL_PERCENT`` thresholds the dashboard's low-disk badge uses (#138): a full disk
      corrupts monerod's DB mid-write.
    - **DB write failing** — ``StateManager.is_db_healthy`` flipping false (#131): the dashboard
      keeps serving but history/shares/stats stop persisting.
    - **high reject rate** — the trailing-1h reject rate (from the persisted per-poll share
      deltas, #116) crossing ``REJECT_ALERT_PCT``: sustained rejects waste hashrate (bad
      overclock, clock drift, flaky network). Recovers when the rate drops back below.
    - **payout wallet changed** — the wallet p2pool actually mines to differing from the
      kv_store baseline (#375): the highest-value tamper against the stack. Fires on every
      change, including a legitimate ``pithead apply`` — a confirmation, not only an intrusion
      signal. Addresses are truncated to 8 chars; the full address never leaves the host.
    - **block found / payout incoming** — p2pool's cumulative ``totalBlocksFound`` counter
      advancing (#336): the sidechain found a Monero block (pool-wide good news), plus a second
      alert when this node held a PPLNS share at that poll — PPLNS pays every miner with a share
      in the window, so that block pays *you*. Good news, not incidents — never tallied in the
      daily incident log.
    - **container crash-loop / unhealthy / recovered** — a debounced
      :class:`ContainerHealthMonitor` over the per-container inspect snapshots from the
      read-only docker-proxy (#337): a stack container restarting repeatedly (OOM, bad config)
      or stuck failing its healthcheck. Keys ONLY off restart deltas / ``restarting`` /
      ``health=="unhealthy"`` — never off "exited", because the stack stops p2pool and
      xmrig-proxy on purpose (#35/#31).

    Edge state is seeded silently on the first observation (``None`` baselines), so a dashboard
    restart can't replay a stale transition as a fresh alert. The exception is the persistent
    host-perf advisories (HugePages not reserved, low RAM — #104): a stable bad state never
    "transitions", so those fire on first observation instead of seeding silently.

    :meth:`evaluate` is pure (folds signals into the alert list, no I/O) so it's fully
    unit-testable; :meth:`process` calls it and dispatches each message off-thread so a slow or
    blocked Telegram send never stalls the data loop.
    """

    # Event keys — must match config.json's telegram.events toggles and TELEGRAM_EVENTS.
    EVT_NODE_DOWN = "node_down"
    EVT_NODE_RECOVERED = "node_recovered"
    EVT_WORKER_OFFLINE = "worker_offline"
    EVT_WORKER_RECOVERED = "worker_recovered"
    EVT_WORKER_JOINED = "worker_joined"
    EVT_WORKER_LEFT = "worker_left"
    EVT_SYNC_FINISHED = "sync_finished"
    EVT_DISK_SPACE = "disk_space"
    EVT_DB_UNHEALTHY = "db_unhealthy"
    EVT_DB_RESET = "db_reset"
    EVT_XVB_NO_SHARE = "xvb_no_share"
    EVT_CLEARNET_EXPOSED = "clearnet_exposed"
    EVT_XVB_REGISTRATION = "xvb_registration"
    EVT_NEW_RELEASE = "new_release"
    EVT_STACK_ONLINE = "stack_online"
    EVT_DAILY_SUMMARY = "daily_summary"
    EVT_HASHRATE_LOW = "hashrate_low"
    EVT_HASHRATE_LOSS = "hashrate_loss"
    EVT_HUGEPAGES = "hugepages"
    EVT_LOW_RAM = "low_ram"
    EVT_WALLET_CHANGED = "wallet_changed"
    EVT_HIGH_REJECT_RATE = "high_reject_rate"
    EVT_BLOCK_FOUND = "block_found"
    EVT_PAYOUT_FOUND = "payout_found"
    EVT_PAYOUT_CONFIRMED = "payout_confirmed"
    EVT_CONTAINER_UNHEALTHY = "container_unhealthy"
    EVT_RAFFLE_WIN = "raffle_win"

    # WorkerPresenceMonitor edge -> (event key, message template).
    _WORKER_EDGES = {
        "offline": (EVT_WORKER_OFFLINE, "\U0001f534 ⛏️ Worker offline: {name}"),
        "recovered": (EVT_WORKER_RECOVERED, "\U0001f7e2 ⛏️ Worker back online: {name}"),
        "joined": (EVT_WORKER_JOINED, "\U0001f389 New worker joined: {name}"),
        "left": (EVT_WORKER_LEFT, "\U0001f44b Worker left: {name}"),
    }

    # ContainerHealthMonitor edge -> (event key, message template). One toggle for all three
    # edges (#337) — problem and recovery are the same conversation.
    _CONTAINER_EDGES = {
        "crash_loop": (
            EVT_CONTAINER_UNHEALTHY,
            "\U0001f534 \U0001f4e6 Container {name} is crash-looping — restarting repeatedly "
            "(OOM or bad config?). Check: docker logs {name}",
        ),
        "unhealthy": (
            EVT_CONTAINER_UNHEALTHY,
            "\U0001f7e0 \U0001f4e6 Container {name} is running but unhealthy — its healthcheck "
            "keeps failing.",
        ),
        "recovered": (
            EVT_CONTAINER_UNHEALTHY,
            "\U0001f7e2 \U0001f4e6 Container {name} recovered.",
        ),
    }

    def __init__(
        self,
        notifier=None,
        worker_monitor=None,
        container_monitor=None,
        host_label=HOST_IP,
        daily_time=TELEGRAM_DAILY_SUMMARY_TIME,
        kv_get=None,
        kv_set=None,
        sinks=None,
    ):
        self.notifier = notifier if notifier is not None else build_default_notifier()
        # Every alert fans out to N transports (#380): the Telegram notifier plus any configured
        # webhook/ntfy sinks — each with `enabled` / `event_enabled(evt)` / `send(text, evt)`.
        # On a default stack this is just the (disabled) Telegram notifier, so nothing new runs.
        self.sinks = list(sinks) if sinks is not None else [self.notifier, *config_sinks()]
        self.workers = worker_monitor if worker_monitor is not None else WorkerPresenceMonitor()
        self.containers = (
            container_monitor if container_monitor is not None else ContainerHealthMonitor()
        )
        # Once-daily digest: target local minute-of-day (HH:MM → h*60+m), and the day we last sent
        # (so it fires once per day). A malformed time disables it.
        self._daily_target_min = _parse_hhmm(daily_time)
        self._daily_last = None
        self._daily_seeded = False
        # "Unknown Host" is config.py's placeholder when HOST_IP isn't set — don't prefix with it.
        self.host_label = "" if host_label in (None, "", "Unknown Host") else host_label
        # None = "not yet observed": the first cycle seeds the baseline without emitting.
        self._prev_monero_down = None
        self._prev_monero_stale = None
        self._prev_tari_down = None
        self._prev_released = None
        self._prev_disk_level = None
        self._prev_db_healthy = None
        self._prev_db_reset_seq = None
        self._prev_xvb_has_share = None
        self._prev_clearnet_active = None
        self._prev_xvb_reg = None
        self._prev_update_available = None
        self._prev_hashrate_low = None
        self._prev_reject_high = None
        self._prev_blocks_found = None
        # Two-step rebaseline for the block counter (#336): a backwards move (p2pool restart, or
        # a partially-written stats file briefly reading 0) arms this; the NEXT observation then
        # seeds the baseline silently. Without it, the transient 7→0→7 glitch would read the
        # restored 7 as "found 7 blocks".
        self._blocks_rebaselining = False
        # Persistent host-perf advisories (#104): unlike the transient edges above, these fire on the
        # FIRST observation of the problem (a stable low-RAM box would never "transition"), so their
        # baseline is "no problem" (False) rather than None — a problem present on the first cycle is
        # a real edge and alerts once.
        self._prev_hugepages_problem = False
        self._prev_low_ram = False
        # Tally of problem-state transitions since the last daily digest drained it (#342). Keyed by
        # event, counted at the exact edge so recoveries / steady state don't inflate it.
        self._incidents = {}
        # One-shot "stack is online" ping, sent on the first cycle after the dashboard starts.
        self._announced_online = False
        # Payout-wallet tamper tripwire (#375): the baseline lives in the SQLite kv_store, NOT in
        # an in-memory `_prev_*` attr, because `pithead apply` recreates the dashboard container —
        # exactly the moment an attacker swaps the wallet — and an in-memory baseline would
        # silently re-seed to the attacker's address. Injected as callables so the edge stays
        # unit-testable with a plain dict. Both None => the tripwire is off.
        self._kv_get = kv_get
        self._kv_set = kv_set

    @property
    def enabled(self):
        return any(s.enabled for s in self.sinks)

    def _event_sinks(self, event):
        """The sinks this event fans out to (each sink applies its own per-event gating)."""
        return [s for s in self.sinks if s.event_enabled(event)]

    def evaluate(
        self,
        *,
        monero_down,
        monero_stale=False,
        tari_down,
        tari_required,
        miner_released,
        workers,
        workers_expected,
        disk_percent=0,
        db_healthy=True,
        db_reset_seq=0,
        db_reset_detail=None,
        xvb_enabled=False,
        shares_in_window=0,
        clearnet_active=False,
        xvb_registration_state="",
        update_available=False,
        low_hr_warning=False,
        hugepages_reserved=True,
        low_ram=False,
        observed_wallet="",
        reject_rate_1h=None,
        blocks_found_total=0,
        block_height=0,
        containers=None,
        now=None,
    ):
        """Fold this cycle's signals into the list of ``(event_key, text)`` to send, filtered to
        the events the operator left enabled. No I/O except the injected wallet-baseline kv
        callables (#375), which tests back with a plain dict."""
        alerts = []

        # --- Stack online (one-shot on the first cycle after the dashboard starts) ---
        if not self._announced_online:
            self._announced_online = True
            alerts.append(
                (
                    self.EVT_STACK_ONLINE,
                    self._fmt("\U0001f680 Pithead is online — dashboard up and monitoring."),
                )
            )

        # --- Node down / recovered (consume NodeHealthMonitor edges) ---
        alerts += self._node_edges("Monero", monero_down, "_prev_monero_down")
        alerts += self._stale_edges(monero_stale)
        if tari_required:
            alerts += self._node_edges("Tari", tari_down, "_prev_tari_down")
        else:
            # Keep the baseline current while Tari is non-blocking, so flipping it back to
            # required later doesn't fire a stale edge from a state we never alerted on.
            self._prev_tari_down = tari_down

        # --- Sync finished (one-shot when the gate first opens) ---
        if self._prev_released is None:
            self._prev_released = miner_released
        elif miner_released and not self._prev_released:
            alerts.append(
                (
                    self.EVT_SYNC_FINISHED,
                    self._fmt("✅ Node ready — required chain(s) synced; mining has started."),
                )
            )
        self._prev_released = miner_released

        # --- Worker offline / recovered / joined / left (debounced off the DOWN status) ---
        # Driven by each rig's status in the same worker rows the dashboard shows (DOWN = offline).
        # Only meaningful while workers are actually expected: when the proxy is intentionally
        # stopped (initial sync hold, or node-down failover) their absence is by design, so we
        # reset the tracker instead of aging every rig into a false "offline".
        if workers_expected:
            for name, event in self.workers.update(workers, now=now):
                evt, template = self._WORKER_EDGES[event]
                if event == "offline":
                    self._record_incident(self.EVT_WORKER_OFFLINE)
                alerts.append((evt, self._fmt(template.format(name=name))))
        else:
            self.workers.reset()

        # --- Container crash-loop / stuck-unhealthy / recovered (#337) ---
        # Driven by the read-proxy inspect snapshots; None = no data this cycle (collector
        # skipped), which is no verdict — the monitor isn't fed, so streaks stay put.
        if containers is not None:
            for name, edge in self.containers.update(containers, now=now):
                evt, template = self._CONTAINER_EDGES[edge]
                if edge != "recovered":
                    self._record_incident(self.EVT_CONTAINER_UNHEALTHY)
                alerts.append((evt, self._fmt(template.format(name=name))))

        # --- Host health: data disk filling up, dashboard DB write failing / reset ---
        alerts += self._disk_edges(disk_percent)
        alerts += self._db_edges(db_healthy)
        alerts += self._db_reset_edges(db_reset_seq, db_reset_detail)

        # --- Payout-wallet tamper tripwire (#375) — kv-backed, so it survives container recreate ---
        alerts += self._wallet_edges(observed_wallet)

        # --- Revenue / privacy: XvB PPLNS-share gate, clearnet-sync exposure ---
        alerts += self._xvb_share_edges(xvb_enabled, shares_in_window)
        alerts += self._clearnet_edges(clearnet_active)

        # --- XvB auto-registration health, and a new Pithead release being available ---
        alerts += self._registration_edges(xvb_enabled, xvb_registration_state)
        alerts += self._release_edges(update_available)
        alerts += self._hashrate_low_edges(low_hr_warning)
        alerts += self._reject_rate_edges(reject_rate_1h)

        # --- Good news: the pool found a Monero block / that block pays this node (#336) ---
        alerts += self._block_edges(blocks_found_total, block_height, shares_in_window)

        # --- Persistent host-perf advisories (#104): HugePages not reserved, low RAM ---
        alerts += self._advisory_edge(
            not hugepages_reserved,
            "_prev_hugepages_problem",
            self.EVT_HUGEPAGES,
            "\U0001f7e0 \U0001f9e0 HugePages not reserved — RandomX hashrate is capped. Apply "
            "setup's tuning (or edit GRUB) and reboot.",
            recovery_text="\U0001f7e2 \U0001f9e0 HugePages now reserved — RandomX is unthrottled.",
        )
        alerts += self._advisory_edge(
            low_ram,
            "_prev_low_ram",
            self.EVT_LOW_RAM,
            "\U0001f7e0 \U0001f4be Low RAM for this stack — syncing is memory-heavy (Tari can OOM). "
            "Add RAM for a stable node.",
        )

        # Keep an alert when ANY sink carries it (#380); incident tallies above are unaffected —
        # _record_incident runs at the edge, before this delivery filter.
        return [(evt, text) for evt, text in alerts if self._event_sinks(evt)]

    def _record_incident(self, key):
        """Tally one problem-state transition for the daily incident log (#342)."""
        self._incidents[key] = self._incidents.get(key, 0) + 1

    def drain_incidents(self):
        """Return the incidents tallied since the last drain and reset the counter. Called by the
        daily digest so the count spans ~the last day (since the previous digest)."""
        incidents, self._incidents = self._incidents, {}
        return incidents

    def _fmt(self, text):
        return f"[{self.host_label}] {text}" if self.host_label else text

    async def process(self, **signals) -> list[tuple[str, str]]:
        """Evaluate this cycle's signals and dispatch any alerts to every sink that carries
        them (#380). Near-no-op when every sink is disabled — except the payout-wallet baseline
        (#375), which must persist every cycle regardless: the dashboard's 72h tamper banner
        reads the kv keys ``_wallet_edges`` writes, and alerts-off is the default stack. Each
        send runs off-thread so a slow or blocked endpoint can't stall the data loop. Returns
        the alerts that were dispatched (handy for tests/logging)."""
        if not self.enabled:
            try:
                # Seed/update the kv baseline and change record; the returned alert (the
                # Telegram message) is the only part that stays notifier-gated.
                self._wallet_edges(signals.get("observed_wallet", ""))
            except Exception as exc:  # never let the tripwire break the data loop
                logger.debug("Wallet baseline update failed (%s)", type(exc).__name__)
            # Keep the container-health debounce state current even with every sink off (#490):
            # `dashboard.fail_closed` reads `self.containers.is_confirmed_bad("dashboard")` off
            # the same tracker this alerting path would otherwise be the only feeder for. No
            # alert fires here — just the state update the alerting branch below does anyway.
            containers = signals.get("containers")
            if containers is not None:
                try:
                    self.containers.update(containers, now=signals.get("now"))
                except Exception as exc:  # never let a tracker bug break the data loop
                    logger.debug("Container-health update failed (%s)", type(exc).__name__)
            return []
        try:
            alerts = self.evaluate(**signals)
        except Exception as exc:  # never let an alerting bug break the data loop
            logger.debug("Alert evaluation failed (%s)", type(exc).__name__)
            return []
        for evt, text in alerts:
            for sink in self._event_sinks(evt):
                await asyncio.to_thread(sink.send, text, evt)
        return alerts

    async def degradation_alert(self, kind, drop_frac):
        """Push a hashrate-loss / recovery alert for a :class:`DegradationMonitor` edge (#99). The
        detector owns the debounce + thresholds; this only formats and sends (and records the loss
        as an incident for the daily log). No-op when the event is toggled off."""
        if kind == "loss":
            self._record_incident(self.EVT_HASHRATE_LOSS)
        sinks = self._event_sinks(self.EVT_HASHRATE_LOSS)
        if not sinks:
            return None
        if kind == "loss":
            text = self._fmt(
                f"⚠️ \U0001f4c9 Hashrate dropped ~{drop_frac * 100:.0f}% — possible outage or a rig "
                "gone dark."
            )
        else:
            text = self._fmt("\U0001f7e2 \U0001f4c8 Hashrate recovered.")
        for sink in sinks:
            await asyncio.to_thread(sink.send, text, self.EVT_HASHRATE_LOSS)
        return text

    async def payout_confirmed_alert(self, chain, amount_atomic, txid):
        """Push a payout-confirmed alert (#381): the view-only wallet saw an incoming payout land
        on-chain — the ground truth behind the earnings estimate. "Alert once" is enforced upstream
        (the caller only invokes this for genuinely-new ``(chain, txid)`` rows the idempotent
        ``payouts`` table just inserted), so a dashboard restart re-scanning the tip replays nothing.
        Carries the chain so the shared table/event serves Tari's sibling (#462), and the chain
        also picks the atomic-unit divisor — Monero stores piconero (1e12/XMR), Tari microTari
        (1e6/XTM) — so the same alert formats both correctly. No-op when the event is toggled off.
        Returns the text sent (handy for tests), else ``None``."""
        sinks = self._event_sinks(self.EVT_PAYOUT_CONFIRMED)
        if not sinks:
            return None
        divisor = 1_000_000 if chain == "tari" else 1_000_000_000_000
        amount = (amount_atomic or 0) / divisor
        text = self._fmt(
            f"\U0001f4b0 Payout CONFIRMED on-chain: {amount:.6f} {chain.upper()} "
            f"landed in your wallet (tx {txid[:8]}…)."
        )
        for sink in sinks:
            await asyncio.to_thread(sink.send, text, self.EVT_PAYOUT_CONFIRMED)
        return text

    async def raffle_win_alert(self, tier, hashrate):
        """Push an XvB raffle-win alert: this wallet won a round, per XvB's public winners file.
        "Alert once" is enforced upstream exactly like payout_confirmed — the caller only invokes
        this for genuinely-new rows the idempotent ``raffle_wins`` table just inserted, so a
        restart re-reading the file's window replays nothing. No-op when the event is toggled
        off. Returns the text sent (handy for tests), else ``None``."""
        sinks = self._event_sinks(self.EVT_RAFFLE_WIN)
        if not sinks:
            return None
        text = self._fmt(
            f"\U0001f3c6 XvB raffle WIN: this wallet won a {tier} round "
            f"(credited {format_hashrate(hashrate)})."
        )
        for sink in sinks:
            await asyncio.to_thread(sink.send, text, self.EVT_RAFFLE_WIN)
        return text

    async def tor_heal_alert(self, text):
        """Push the Tor guard self-heal note (#424). Deliberately not behind a per-event toggle:
        it fires at most once per outage, only after a heal restored the very path the alert
        sinks ride (so a broken egress can never even attempt it), and an operator who opted
        into the heal wants to know it acted. No-op when every sink is off."""
        if not self.enabled:
            return None
        text = self._fmt(text)
        for sink in self.sinks:
            if sink.enabled:
                await asyncio.to_thread(sink.send, text)
        return text

    async def maybe_daily_summary(self, now, summary_provider) -> str | None:
        """Push a once-daily status digest at the configured local time.

        ``summary_provider()`` builds the digest text and is called **only when a send is actually
        due**, so it isn't run every cycle. No-op when the ``daily_summary`` event is off, the time
        is malformed, or the digest has already gone out today. On a startup that's already past
        today's time it waits for tomorrow rather than firing a stale digest immediately. Returns the
        text sent (handy for tests), else ``None``.
        """
        sinks = self._event_sinks(self.EVT_DAILY_SUMMARY)
        if self._daily_target_min is None or not sinks:
            return None
        lt = time.localtime(now)
        today = (lt.tm_year, lt.tm_yday)
        now_min = lt.tm_hour * 60 + lt.tm_min
        if not self._daily_seeded:
            self._daily_seeded = True
            # Started after today's send time → don't replay it now; wait for tomorrow.
            if now_min >= self._daily_target_min:
                self._daily_last = today
        if self._daily_last == today or now_min < self._daily_target_min:
            return None
        self._daily_last = today
        try:
            text = summary_provider()
        except Exception as exc:  # a bad summary build must not wedge the loop
            logger.debug("Daily summary build failed (%s)", type(exc).__name__)
            return None
        if text:
            for sink in sinks:
                await asyncio.to_thread(sink.send, text, self.EVT_DAILY_SUMMARY)
        return text
