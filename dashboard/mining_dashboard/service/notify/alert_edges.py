import logging
import time

from mining_dashboard.config.config import (
    DISK_CRITICAL_PERCENT,
    DISK_WARN_PERCENT,
    TELEGRAM_BOT_TOKEN,
    TELEGRAM_CHAT_ID,
    TELEGRAM_ENABLED,
    TELEGRAM_EVENTS,
)
from mining_dashboard.service.notify.telegram_notifier import TelegramNotifier

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


class AlertEdgesMixin:
    def _node_edges(self, label, down, attr):
        prev = getattr(self, attr)
        setattr(self, attr, down)
        if prev is None or down == prev:
            return []
        if down:
            self._record_incident(self.EVT_NODE_DOWN)
            return [
                (
                    self.EVT_NODE_DOWN,
                    self._fmt(
                        f"\U0001f534 ⛓️ {label} node is DOWN — workers failing over to backup pools."
                    ),
                )
            ]
        return [
            (
                self.EVT_NODE_RECOVERED,
                self._fmt(f"\U0001f7e2 ⛓️ {label} node recovered — workers readmitted."),
            )
        ]

    def _stale_edges(self, stale):
        """Monero node reachable but OUT of sync (#972): the debounced ``synchronized: false``
        strand a tor restart leaves behind. Distinct from node-down — the node answers its RPC
        and every container reads healthy while mining sits on a stale tip. Rides the
        node_down/node_recovered toggles: same conversation, different failure mode."""
        prev = self._prev_monero_stale
        self._prev_monero_stale = stale
        if prev is None or stale == prev:
            return []
        if stale:
            self._record_incident(self.EVT_NODE_DOWN)
            return [
                (
                    self.EVT_NODE_DOWN,
                    self._fmt(
                        "\U0001f534 ⛓️ Monero node is OUT OF SYNC — reachable but reporting "
                        "not-synchronized (peers usually die like this after a Tor restart). "
                        "Mining sits on a stale tip until it re-peers: run "
                        "'./pithead restart monerod'."
                    ),
                )
            ]
        return [
            (
                self.EVT_NODE_RECOVERED,
                self._fmt("\U0001f7e2 ⛓️ Monero node is back in sync with the network."),
            )
        ]

    def _disk_edges(self, disk_percent):
        """Alert on the data disk crossing the dashboard's own warn/critical thresholds (#138)."""
        level = (
            "critical"
            if disk_percent >= DISK_CRITICAL_PERCENT
            else "warn"
            if disk_percent >= DISK_WARN_PERCENT
            else "ok"
        )
        prev = self._prev_disk_level
        self._prev_disk_level = level
        if prev is None or level == prev:
            return []
        pct = f"{disk_percent:.0f}%"
        if level in ("critical", "warn"):
            self._record_incident(self.EVT_DISK_SPACE)
        if level == "critical":
            return [
                (
                    self.EVT_DISK_SPACE,
                    self._fmt(
                        f"\U0001f534 \U0001f4be Data disk almost full ({pct}) — free space now; a "
                        "full disk can corrupt the Monero database."
                    ),
                )
            ]
        if level == "warn":
            return [
                (
                    self.EVT_DISK_SPACE,
                    self._fmt(f"\U0001f7e0 \U0001f4be Data disk filling up ({pct})."),
                )
            ]
        return [
            (
                self.EVT_DISK_SPACE,
                self._fmt(f"\U0001f7e2 \U0001f4be Data disk back to healthy ({pct})."),
            )
        ]

    def _db_edges(self, db_healthy):
        """Alert when the dashboard can no longer persist to its SQLite DB (#131)."""
        prev = self._prev_db_healthy
        self._prev_db_healthy = db_healthy
        if prev is None or db_healthy == prev:
            return []
        if not db_healthy:
            self._record_incident(self.EVT_DB_UNHEALTHY)
            return [
                (
                    self.EVT_DB_UNHEALTHY,
                    self._fmt(
                        "\U0001f534 \U0001f5c4️ Dashboard DB write failing — hashrate history, shares "
                        "and stats won't persist. Check disk space + permissions on the data dir."
                    ),
                )
            ]
        return [
            (
                self.EVT_DB_UNHEALTHY,
                self._fmt("\U0001f7e2 \U0001f5c4️ Dashboard DB writes recovered."),
            )
        ]

    def _db_reset_edges(self, db_reset_seq, detail):
        """One-shot alert when a corrupt DB was auto-healed by resetting it (#489).

        ``db_reset_seq`` is StateManager's monotonic reset counter. We edge on an increase rather than
        the db_healthy flip because a reset can be invisible to ``_db_edges``: a startup reset happens
        before the first cycle (no prior state), and a runtime reset flips back to healthy within one
        cycle. The message is loud — the operator must know history before now was quarantined and
        cleared, even though the stack recovered on its own."""
        prev = self._prev_db_reset_seq
        self._prev_db_reset_seq = db_reset_seq
        # Seed silently on the first observation (or after a restart): only a genuine increase alerts.
        if prev is None or db_reset_seq <= prev:
            return []
        self._record_incident(self.EVT_DB_RESET)
        where = ""
        if isinstance(detail, dict) and detail.get("quarantine"):
            where = f" The corrupt file was kept at {detail['quarantine']} for inspection."
        return [
            (
                self.EVT_DB_RESET,
                self._fmt(
                    "\U0001f504 \U0001f5c4️ Dashboard DB was corrupt and has been reset — hashrate "
                    "history and stats before now were cleared so persistence could resume." + where
                ),
            )
        ]

    def _wallet_edges(self, observed):
        """Payout-wallet tamper tripwire (#375). ``observed`` is the wallet p2pool itself reports
        mining to (stratum stats), with the env address as fallback — ground truth of where
        rewards go. Baseline in the kv_store so an `apply`-driven container recreate can't wipe
        it (that recreate IS the attack window). Empty/Unknown observations no-op: p2pool briefly
        reports no wallet while restarting, and that must not read as "changed to ''" or re-seed.
        The first-ever observation seeds silently. Only the first 8 chars of each address are
        ever put in a message."""
        if not observed or observed == "Unknown" or self._kv_get is None or self._kv_set is None:
            return []
        baseline = self._kv_get("payout_wallet")
        if not baseline:
            self._kv_set("payout_wallet", observed)
            return []
        if observed == baseline:
            return []
        old8, new8 = baseline[:8], observed[:8]
        self._kv_set("payout_wallet", observed)
        self._kv_set("payout_wallet_prev8", old8)  # for the dashboard banner's tooltip
        self._kv_set("payout_wallet_changed_ts", time.time())
        self._record_incident(self.EVT_WALLET_CHANGED)
        return [
            (
                self.EVT_WALLET_CHANGED,
                self._fmt(
                    f"\U0001f6a8 Payout wallet CHANGED: {old8}… → {new8}… — if you did not do "
                    "this, your rewards are being redirected. Check config.json and run "
                    "'pithead status'."
                ),
            )
        ]

    def _xvb_share_edges(self, xvb_enabled, shares_in_window):
        """Alert on losing / regaining the PPLNS share XvB needs to bank a raffle win (#158).

        Only meaningful while XvB is on. A donating rig with **no** share in the PPLNS window has
        its wins skipped (and accrues a fail) regardless of tier — a make-or-break, revenue-costing
        state worth a ping."""
        if not xvb_enabled:
            # No XvB → the share gate doesn't apply; drop the baseline so turning XvB back on later
            # doesn't replay a stale edge.
            self._prev_xvb_has_share = None
            return []
        has_share = shares_in_window > 0
        prev = self._prev_xvb_has_share
        self._prev_xvb_has_share = has_share
        if prev is None or has_share == prev:
            return []
        if not has_share:
            self._record_incident(self.EVT_XVB_NO_SHARE)
            return [
                (
                    self.EVT_XVB_NO_SHARE,
                    self._fmt(
                        "⚠️ \U0001f3b0 No PPLNS share — XvB raffle wins are skipped until you land "
                        "one (donations are wasted meanwhile)."
                    ),
                )
            ]
        return [
            (
                self.EVT_XVB_NO_SHARE,
                self._fmt(
                    "\U0001f7e2 \U0001f3b0 PPLNS share restored — XvB raffle wins count again."
                ),
            )
        ]

    def _clearnet_edges(self, clearnet_active):
        """Alert while a node is doing its initial sync over CLEARNET (#183): the host IP is exposed
        to that chain's P2P network until it finishes (it reverts to Tor automatically, #234)."""
        prev = self._prev_clearnet_active
        self._prev_clearnet_active = clearnet_active
        if prev is None or clearnet_active == prev:
            return []
        if clearnet_active:
            self._record_incident(self.EVT_CLEARNET_EXPOSED)
            return [
                (
                    self.EVT_CLEARNET_EXPOSED,
                    self._fmt(
                        "⚠️ \U0001f310 Clearnet initial sync ACTIVE — this host's IP is exposed to the "
                        "chain's P2P network until it finishes syncing (reverts to Tor automatically)."
                    ),
                )
            ]
        return [
            (
                self.EVT_CLEARNET_EXPOSED,
                self._fmt(
                    "\U0001f7e2 \U0001f9c5 Back on Tor-only — clearnet sync finished, host IP no "
                    "longer exposed."
                ),
            )
        ]

    def _registration_edges(self, xvb_enabled, state):
        """Alert on XvB auto-registration going bad / recovering (#263). ``state`` is one of
        ``""`` / ``registered`` / ``invalid`` (wallet rejected — permanent) / ``failing``."""
        if not xvb_enabled:
            self._prev_xvb_reg = None
            return []
        prev = self._prev_xvb_reg
        self._prev_xvb_reg = state
        if prev is None or state == prev:
            return []
        if state in ("invalid", "failing"):
            self._record_incident(self.EVT_XVB_REGISTRATION)
        if state == "invalid":
            return [
                (
                    self.EVT_XVB_REGISTRATION,
                    self._fmt(
                        "\U0001f534 \U0001f3b0 XvB wallet rejected — auto-registration failed "
                        "(check the payout address); raffle wins won't count."
                    ),
                )
            ]
        if state == "failing":
            return [
                (
                    self.EVT_XVB_REGISTRATION,
                    self._fmt("⚠️ \U0001f3b0 XvB auto-registration failing — retrying."),
                )
            ]
        if state == "registered" and prev in ("invalid", "failing"):
            return [
                (
                    self.EVT_XVB_REGISTRATION,
                    self._fmt(
                        "\U0001f7e2 \U0001f3b0 XvB registration recovered — you're in the raffle."
                    ),
                )
            ]
        return []

    def _release_edges(self, update_available):
        """One-shot ping when a newer Pithead release becomes available (#224)."""
        prev = self._prev_update_available
        self._prev_update_available = bool(update_available)
        if prev is None or not update_available or update_available == prev:
            return []
        return [
            (
                self.EVT_NEW_RELEASE,
                self._fmt(
                    "\U0001f195 A new Pithead release is available — see the dashboard header."
                ),
            )
        ]

    def _hashrate_low_edges(self, low_hr_warning):
        """Alert when a manually-chosen XvB tier can't be sustained by the current hashrate (#158),
        and when it recovers. Edge-only (fires on the transition, not every cycle)."""
        prev = self._prev_hashrate_low
        self._prev_hashrate_low = bool(low_hr_warning)
        if prev is None or bool(low_hr_warning) == prev:
            return []
        if low_hr_warning:
            self._record_incident(self.EVT_HASHRATE_LOW)
            return [
                (
                    self.EVT_HASHRATE_LOW,
                    self._fmt(
                        "⚠️ \U0001f4c9 Hashrate too low for the chosen XvB tier — it can't be "
                        "sustained; lower the tier or add hashrate."
                    ),
                )
            ]
        return [
            (
                self.EVT_HASHRATE_LOW,
                self._fmt("\U0001f7e2 \U0001f4c8 Hashrate back above the chosen XvB tier."),
            )
        ]

    def _reject_rate_edges(self, reject_rate_pct):
        """Alert on the trailing-1h reject rate (from the #116 delta series) crossing
        ``REJECT_ALERT_PCT``, and on it dropping back. ``None`` — no shares submitted in the
        window (proxy idle or held) — is no verdict either way: stay quiet and drop the baseline
        so resumed mining seeds fresh instead of replaying a stale edge."""
        if reject_rate_pct is None:
            self._prev_reject_high = None
            return []
        high = reject_rate_pct >= REJECT_ALERT_PCT
        prev = self._prev_reject_high
        self._prev_reject_high = high
        if prev is None or high == prev:
            return []
        if high:
            self._record_incident(self.EVT_HIGH_REJECT_RATE)
            return [
                (
                    self.EVT_HIGH_REJECT_RATE,
                    self._fmt(
                        f"⚠️ ⛏️ High reject rate: {reject_rate_pct:.1f}% of shares rejected over "
                        "the last hour — check the rigs' Workers table for the ⚠ flag (bad "
                        "overclock, clock drift, flaky network)."
                    ),
                )
            ]
        return [
            (
                self.EVT_HIGH_REJECT_RATE,
                self._fmt(
                    f"\U0001f7e2 ⛏️ Reject rate back to normal "
                    f"({reject_rate_pct:.1f}% over the last hour)."
                ),
            )
        ]

    def _block_edges(self, blocks_found_total, block_height, shares_in_window):
        """Alert when the pool's cumulative ``totalBlocksFound`` counter advances (#336): the
        P2Pool sidechain found a Monero block. Pool-wide news; when this node also held a PPLNS
        share at that poll, a second alert says the block pays *this* node (PPLNS pays every
        miner with a share in the window on every pool block). The first observation seeds
        silently (a dashboard restart must not replay the last block). A counter that went
        backwards (p2pool restart, or the stats file briefly reading 0 mid-write) arms a
        TWO-STEP rebaseline: the next observation seeds the baseline silently, whatever it is —
        so a transient 7→0→7 blank never fires "found 7 blocks", while a genuine restart
        (7→0→0→1) still fires for the 1. A burst between polls alerts once, with the count.
        Good news, not incidents — never recorded in the daily incident log."""
        if self._blocks_rebaselining:
            self._blocks_rebaselining = False
            self._prev_blocks_found = blocks_found_total
            return []
        prev = self._prev_blocks_found
        if prev is not None and blocks_found_total < prev:
            self._blocks_rebaselining = True
            return []
        self._prev_blocks_found = blocks_found_total
        if prev is None or blocks_found_total <= prev:
            return []
        delta = blocks_found_total - prev
        if delta > 1:
            block_text = (
                f"\U0001f389 ⛏️ P2Pool found {delta} Monero blocks! (latest height {block_height:,})"
            )
        else:
            block_text = f"\U0001f389 ⛏️ P2Pool found a Monero block! (height {block_height:,})"
        alerts = [(self.EVT_BLOCK_FOUND, self._fmt(block_text))]
        if shares_in_window > 0:
            alerts.append(
                (
                    self.EVT_PAYOUT_FOUND,
                    self._fmt(
                        f"\U0001f4b0 Payout incoming — you held {shares_in_window} PPLNS "
                        "share(s) when the block was found."
                    ),
                )
            )
        return alerts

    def _advisory_edge(self, problem, attr, event, problem_text, recovery_text=None):
        """Persistent host-perf advisory (#104): fires once when ``problem`` is first observed true
        (including on the first cycle — a stable bad state must still alert, unlike the seed-silent
        transient edges), stays quiet while it persists, and — if ``recovery_text`` is given — fires
        once when it clears. These are static host facts, not transient incidents, so they aren't
        tallied in the daily incident log."""
        prev = getattr(self, attr)
        setattr(self, attr, problem)
        if problem == prev:
            return []
        if problem:
            return [(event, self._fmt(problem_text))]
        return [(event, self._fmt(recovery_text))] if recovery_text else []
