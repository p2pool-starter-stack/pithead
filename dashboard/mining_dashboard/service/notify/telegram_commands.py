# ruff: noqa: F401

import asyncio
import logging
import time

import requests

from mining_dashboard.config import config
from mining_dashboard.config.config import (
    DASHBOARD_CONTROL_ENABLED,
    HOST_IP,
    TELEGRAM_BOT_TOKEN,
    TELEGRAM_CHAT_ID,
    TELEGRAM_COMMANDS_ENABLED,
    TELEGRAM_CONTROL_ALLOWED_IDS,
    TELEGRAM_CONTROL_CONFIRM_S,
    TELEGRAM_CONTROL_ENABLED,
    TELEGRAM_ENABLED,
    TOR_SOCKS_PROXY,
)
from mining_dashboard.helper.http import bounded_get
from mining_dashboard.service import control_service
from mining_dashboard.service.config_approval import ControlGate
from mining_dashboard.service.metrics import build_metrics
from mining_dashboard.service.network.egress import egress_posture_from_config
from mining_dashboard.service.notify.telegram_formatters import (
    _human_count,
    _incident_line,
    _node_state,
    _prefix,
    _running_lines,
    _sync_line,
    _xvb_split_frac,
    format_daily_summary,
    format_earnings,
    format_hashrate_reply,
    format_luck,
    format_pool,
    format_status,
    format_sync,
    format_system,
    format_workers,
    format_xvb,
    parse_command,
    status_warnings,
)
from mining_dashboard.service.notify.telegram_notifier import TELEGRAM_API_BASE
from mining_dashboard.service.xvb.earnings import (
    MICRO_PER_XTM,
    confirmed_payouts_summary,
)
from mining_dashboard.version import resolve_version

logger = logging.getLogger("TelegramCommands")

# Seconds handed to getUpdates: Telegram holds the request open until an update arrives or this
# elapses, so the bot makes ~one request per interval while idle (long-poll, not busy-poll).
LONG_POLL_SECONDS = 25
# Quiet retry after a failed poll — a Tor-only / offline host can't reach api.telegram.org, so a
# persistently-blocked bot backs off instead of hot-looping (and never spams ERROR; #59 discipline).
POLL_ERROR_BACKOFF_SECONDS = 15
# getUpdates batch cap. The offset can only advance after a batch is *parsed*, so a batch that
# trips bounded_get's size cap would be re-fetched forever — bounding the batch keeps the worst
# case (10 updates at Telegram's own per-message field limits) far under the cap instead.
GETUPDATES_LIMIT = 10

# The commands the bot answers. All are read-only status queries — the bot can never change the
# stack (start/stop/apply live on the CLI), so a leaked chat can at worst read status, not act.
COMMANDS = (
    "status",
    "info",
    "hashrate",
    "workers",
    "sync",
    "system",
    "pool",
    "xvb",
    "earnings",
    "luck",
    "help",
)

HELP_TEXT = (
    "Pithead bot — commands:\n"
    "/status — stack health at a glance\n"
    "/info — version, updates, DB mode, privacy posture\n"
    "/hashrate — total + per-worker hashrate\n"
    "/workers — each rig's online/offline state\n"
    "/sync — Monero + Tari node sync progress\n"
    "/system — host disk, RAM, CPU, HugePages\n"
    "/pool — P2Pool sidechain + Monero network\n"
    "/xvb — XvB mode, tier, and raffle eligibility\n"
    "/earnings — estimated P2Pool XMR per day + confirmed yesterday/7d/30d\n"
    "/luck — pool cadence: time-to-share, luck, PPLNS weight\n"
    "/help — this message"
)

# The write commands, each mapping 1:1 to a bounded host action the #33 runner knows (see pithead
# control_lifecycle). The Telegram input only ever SELECTS one of these — it never becomes a host
# command — so the action set is fixed and there is no arbitrary execution.
CONTROL_COMMANDS = ("restart", "apply")

CONTROL_HELP_TEXT = (
    "\n\nControl commands (allow-listed operators only, each needs confirmation):\n"
    "/restart — recreate the running stack\n"
    "/apply — re-apply the current config on the host"
)

_ALL_COMMANDS = frozenset(COMMANDS) | frozenset(CONTROL_COMMANDS)


def format_info(version, update, metrics, egress_summary, host_label=""):
    """The 'about this stack' card — the answer to '/info'. Folds the build version, whether an
    upgrade is available, the Monero DB mode, the P2Pool sidechain, and the privacy (egress) posture
    into one glance. Static-ish facts, kept out of /status (which is live health)."""
    lines = [f"{_prefix(host_label)}\U0001f4df Pithead info"]

    ver = (version or {}).get("text", "unknown")
    lines.append(f"Version: {ver}{' (dev build)' if (version or {}).get('dev') else ''}")

    update = update or {}
    if update.get("available") and update.get("latest"):
        lines.append(f"Updates: \U0001f195 {update['latest']} available — ./pithead upgrade")
    else:
        lines.append("Updates: ✅ Up to date")

    mode = metrics.monero_mode
    lines.append(f"Monero DB: {mode}" if mode in ("Pruned", "Full") else "Monero DB: unknown")
    lines.append(f"Sidechain: P2Pool {metrics.pool_type}")

    egress_summary = egress_summary or {}
    if egress_summary.get("all_tor", True):
        lines.append("Egress: \U0001f9c5 Tor-only")
    else:
        lines.append(f"Egress: ⚠️ {egress_summary.get('label', 'clearnet exposure')}")
    return "\n".join(lines)


# Friendly labels for the daily incident log (#342), keyed by AlertService event.
_INCIDENT_LABELS = {
    "node_down": "node down",
    "worker_offline": "worker offline",
    "disk_space": "disk warning",
    "db_unhealthy": "DB write fail",
    "xvb_no_share": "XvB no-share",
    "xvb_registration": "XvB registration",
    "clearnet_exposed": "clearnet exposure",
    "hashrate_low": "hashrate low",
    "hashrate_loss": "hashrate drop",
    "container_unhealthy": "container unhealthy",
}


class TelegramCommandBot:
    """
    On-demand Telegram command interface (Issue #45) — the interactive half of the operator bot.

    Answers a small set of **read-only** status commands (``/status``, ``/hashrate``, ``/workers``,
    ``/sync``, ``/help``) from the data the dashboard already collects, so it never re-implements
    collection — it reuses :func:`build_metrics`, the same domain layer the web UI renders, so a
    Telegram reply and the dashboard can never disagree.

    Discipline (mirrors :class:`TelegramNotifier`):

    - **Off by default, opt-in.** Enabled only when Telegram is on *and* ``telegram.commands.enabled``
      is set *and* both ``bot_token`` and ``chat_id`` are present. Otherwise :meth:`run` returns
      immediately, so the background task is a cheap no-op for the default stack.
    - **Long-poll, no inbound port.** Uses ``getUpdates`` (outbound only) over the same egress the
      notifier uses — a webhook would need a public inbound endpoint the Tor-first appliance can't
      offer. Nothing is exposed.
    - **Single-chat access control.** Only the configured ``chat_id`` is answered; every other update
      is dropped silently, so an unknown chat gets no reply and can't use the bot as a probe oracle.
    - **Read-only by default; control commands are a separate opt-in (#338).** The status commands
      never mutate the stack. ``/restart`` and ``/apply`` are enabled only when ``telegram.control``
      is on with a non-empty operator allow-list, are honoured only from those allow-listed USER ids
      (the ``chat_id`` alone is not enough), and each needs an explicit in-chat confirmation that
      denies on timeout. They act by dropping a typed intent into the #33 host-control spool — the
      same root-runner path the config editor uses — never a second privileged path, and never
      arbitrary command execution: the message only selects one of two fixed verbs.
    - **Fail silent, never leaks the token.** Network errors (offline / Tor-only host) are swallowed
      at debug and the poll backs off; the ``bot_token`` only ever appears in the request URL and is
      never written to a log line.
    - **No stale replay.** On startup the backlog is skipped (offset primed past pending updates), so
      a command sent while the dashboard was down isn't executed minutes later on restart.
    """

    def __init__(
        self,
        data_service,
        *,
        enabled=None,
        bot_token=TELEGRAM_BOT_TOKEN,
        chat_id=TELEGRAM_CHAT_ID,
        host_label=HOST_IP,
        api_base=TELEGRAM_API_BASE,
        long_poll=LONG_POLL_SECONDS,
        tor_proxy=TOR_SOCKS_PROXY,
        control_enabled=None,
        allowed_ids=TELEGRAM_CONTROL_ALLOWED_IDS,
        confirm_timeout=TELEGRAM_CONTROL_CONFIRM_S,
    ):
        self.data_service = data_service
        self._token = (bot_token or "").strip()
        # chat_id may be a negative group id (e.g. -1001234567890); keep it a string for exact
        # equality against the id Telegram sends back.
        self.chat_id = str(chat_id or "").strip()
        self.host_label = host_label
        self._api_base = api_base.rstrip("/")
        self.long_poll = long_poll
        # Route getUpdates + replies over the bridge Tor SOCKS proxy, so polling Telegram never
        # exposes the host IP (same discipline as the notifier / Healthchecks pinger).
        self._proxies = {"http": tor_proxy, "https": tor_proxy} if tor_proxy else None
        if enabled is None:
            enabled = bool(TELEGRAM_ENABLED and TELEGRAM_COMMANDS_ENABLED)
        self.enabled = bool(enabled and self._token and self.chat_id)
        self._offset = None
        # Two-way control commands (#338), a stricter opt-in on top of the read-only bot. Enabled only
        # when telegram.control is on, the #33 spool actually exists (dashboard.control on) AND at
        # least one operator id is allow-listed — an empty allow-list means nobody could ever confirm,
        # so the feature stays fully off (fail-closed). The allow-list is the trust boundary: these
        # numeric Telegram USER ids, not merely "same chat", are the only actors a command is honoured
        # from.
        self.allowed_ids = frozenset(str(i) for i in (allowed_ids or ()))
        if control_enabled is None:
            control_enabled = bool(TELEGRAM_CONTROL_ENABLED and DASHBOARD_CONTROL_ENABLED)
        self.control_enabled = bool(self.enabled and control_enabled and self.allowed_ids)
        # Config approval uses the physical-presence Telegram identity list without enabling the
        # unrelated /restart and /apply verbs (or it could never approve that toggle while off).
        # Configuration approval is host-driven and only needs the configured bot identity. It does
        # not silently enable the dashboard's read-only command poller or the /restart,/apply verbs.
        self.config_approval_enabled = bool(self._token and self.chat_id and self.allowed_ids)
        self._gate = ControlGate(confirm_timeout)
        self._config_confirm_timeout = float(confirm_timeout)
        self._config_pause_until = 0.0
        self._poll_idle = asyncio.Event()
        self._poll_idle.set()

    async def pause_for_host_approval(self) -> bool:
        """Yield Telegram polling while the root runner verifies a configuration approval."""
        if not self.config_approval_enabled:
            return False
        self._config_pause_until = max(
            self._config_pause_until, time.monotonic() + self._config_confirm_timeout + 15
        )
        try:
            await asyncio.wait_for(self._poll_idle.wait(), timeout=self.long_poll + 12)
        except TimeoutError:
            return False
        return True

    def _payout_summary(self, chain):
        """Confirmed-payout roll-up for ``chain`` (#787), or ``None`` when that chain's view-only
        wallet is off — the same ``None`` the dashboard passes to mean "feature off, show only the
        estimate".

        Reads the stored payouts and rolls them up through the shared
        :func:`~mining_dashboard.service.xvb.earnings.confirmed_payouts_summary`, so the bot's running
        totals are the identical numbers the dashboard card renders (#61/#387). The config flags are
        read at call time (module attribute, not a from-import) so a flipped setting takes effect
        without a re-import — matching ``build_state``'s handling of the same two flags."""
        enabled = (
            config.PAYOUT_CONFIRM_ENABLED
            if chain == "monero"
            else config.TARI_PAYOUT_CONFIRM_ENABLED
        )
        if not enabled:
            return None
        payouts = self.data_service.state_manager.get_payouts(chain)
        if chain == "tari":
            return confirmed_payouts_summary(payouts, divisor=MICRO_PER_XTM, unit="xtm")
        return confirmed_payouts_summary(payouts)

    def reply_for(self, text):
        """Map an incoming message to a reply string, or ``None`` to stay silent.

        Reads the latest snapshot and runs the shared :func:`build_metrics` (a couple of quick local
        SQLite reads); the caller runs this off-thread so a slow read can't stall the poll loop.
        """
        cmd = parse_command(text)
        if cmd is None:
            return None
        # Control verbs are side-effecting and need the operator's user id + the confirm flow, so they
        # are routed in _handle_update, never here. reply_for stays pure/read-only.
        if cmd in CONTROL_COMMANDS:
            return None
        if cmd == "help":
            return f"{_prefix(self.host_label)}{self._help_text()}"
        if cmd == "unknown":
            return f"{_prefix(self.host_label)}Unknown command.\n{self._help_text()}"

        data = self.data_service.latest_data or {}
        # /system reads the raw snapshot only — no need to build the full metrics.
        if cmd == "system":
            return format_system(data.get("system", {}), self.host_label)

        metrics = build_metrics(data, self.data_service.state_manager)
        if cmd == "status":
            mining = bool(data.get("miner_released") and not data.get("workers_rejected"))
            warnings = status_warnings(
                data, metrics, self.data_service.state_manager.is_db_healthy()
            )
            # Merge-mine link = the Tari gRPC being READY (not merely the node being up) — the same
            # rule the dashboard's ✔ uses (#313). Omitted until Tari has been polled at all.
            tari = data.get("tari")
            merge = (bool(tari.get("connected")) and bool(tari.get("active"))) if tari else None
            return format_status(
                metrics, mining, self.host_label, warnings=warnings, merge_mining=merge
            )
        if cmd == "info":
            return format_info(
                resolve_version(),
                data.get("update"),
                metrics,
                egress_posture_from_config()["summary"],
                self.host_label,
            )
        if cmd == "hashrate":
            return format_hashrate_reply(metrics, data.get("workers", []), self.host_label)
        if cmd == "workers":
            return format_workers(data.get("workers", []), self.host_label)
        if cmd == "sync":
            return format_sync(metrics, self.host_label)
        if cmd == "pool":
            return format_pool(metrics, data, self.host_label)
        if cmd == "xvb":
            return format_xvb(metrics, self.host_label)
        if cmd == "earnings":
            return format_earnings(
                metrics,
                data.get("network", {}),
                self.host_label,
                confirmed=self._payout_summary("monero"),
                tari_confirmed=self._payout_summary("tari"),
            )
        if cmd == "luck":
            return format_luck(metrics, self.host_label)
        return None

    async def run(self):
        """Long-poll for commands until cancelled. A no-op when disabled.

        The network calls use ``requests`` (so they ride the same Tor SOCKS proxy as the notifier)
        run off the event loop via :func:`asyncio.to_thread`, so a 25s long-poll never blocks it.
        """
        if not self.enabled:
            return
        logger.info("Telegram command interface enabled — polling for commands (over Tor).")
        await asyncio.to_thread(self._prime_offset)
        while True:
            if time.monotonic() < self._config_pause_until:
                await asyncio.sleep(min(0.25, self._config_pause_until - time.monotonic()))
                continue
            try:
                self._poll_idle.clear()
                updates = await asyncio.to_thread(self._get_updates, self.long_poll)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                logger.debug("Telegram getUpdates failed (%s)", type(exc).__name__)
                await asyncio.sleep(POLL_ERROR_BACKOFF_SECONDS)
                continue
            finally:
                self._poll_idle.set()
            for update in updates:
                self._offset = update.get("update_id", 0) + 1
                await self._handle_update(update)

    def _prime_offset(self):
        """Advance the offset past any pending backlog without acting on it, so a command queued
        while the dashboard was down isn't run on startup. Drains batch by batch: getUpdates
        returns at most GETUPDATES_LIMIT updates per call, and returns immediately (timeout 0)
        while a backlog remains."""
        try:
            while updates := self._get_updates(0):
                self._offset = updates[-1].get("update_id", 0) + 1
        except Exception as exc:
            logger.debug("Telegram offset prime skipped (%s)", type(exc).__name__)

    def _get_updates(self, poll_timeout):
        """Blocking ``getUpdates`` over Tor. Called via ``to_thread`` from the loop."""
        allowed = '["message","callback_query"]' if self.control_enabled else '["message"]'
        params = {"timeout": poll_timeout, "allowed_updates": allowed, "limit": GETUPDATES_LIMIT}
        if self._offset is not None:
            params["offset"] = self._offset
        url = f"{self._api_base}/bot{self._token}/getUpdates"
        # The read timeout must outlast Telegram's long-poll hold, or requests aborts the request
        # the server is legitimately keeping open; (connect, read) tuple. bounded_get streams, but
        # the read timeout still covers the hold: headers only arrive once the hold ends.
        resp = bounded_get(
            url, params=params, timeout=(10, poll_timeout + 10), proxies=self._proxies
        )
        resp.raise_for_status()
        payload = resp.json()
        if not payload.get("ok"):
            return []
        return payload.get("result", [])

    def _help_text(self):
        """The /help body — read-only commands always, plus the control commands when this bot is
        configured to accept them."""
        return HELP_TEXT + (CONTROL_HELP_TEXT if self.control_enabled else "")

    async def _handle_update(self, update):
        # A tapped inline confirm button arrives as a callback_query, not a message (#338).
        callback = update.get("callback_query")
        if callback is not None:
            await self._handle_callback(callback)
            return
        message = update.get("message") or {}
        chat = message.get("chat") or {}
        # Access control: only the configured chat may drive the bot. Anything else is dropped
        # silently — no reply, so an unknown chat can't even confirm the bot exists.
        if str(chat.get("id")) != self.chat_id:
            return
        text = message.get("text", "")
        if parse_command(text) in CONTROL_COMMANDS:
            await self._handle_control(message, parse_command(text))
            return
        reply = await asyncio.to_thread(self._safe_reply_for, text)
        if reply:
            await asyncio.to_thread(self._send, reply)

    async def _handle_control(self, message, verb):
        """A /restart or /apply from within the configured chat. Gate it on the operator allow-list,
        then arm an in-chat confirmation (deny-on-timeout). Nothing reaches the host spool here — that
        only happens once the operator confirms in :meth:`_handle_callback`."""
        if not self.control_enabled:
            # The write channel is off (or nobody is allow-listed): behave like an unknown command,
            # so a read-only-only bot doesn't imply a control surface it doesn't expose.
            await asyncio.to_thread(
                self._send, f"{_prefix(self.host_label)}Unknown command.\n{self._help_text()}"
            )
            return
        uid = str((message.get("from") or {}).get("id", ""))
        if uid not in self.allowed_ids:
            # Not an allow-listed operator: refuse. Log it (audit trail) but stay SILENT to the user —
            # no reply, so the bot can't be used as an oracle to probe who is authorised, and a
            # non-allow-listed message never earns a write into the host spool (no DoS amplification).
            logger.warning(
                "Telegram control /%s refused — user id %s is not on the allow-list.",
                verb,
                uid or "?",
            )
            return
        token = self._gate.open(verb, uid, time.monotonic())
        if token is None:
            await asyncio.to_thread(
                self._send,
                f"{_prefix(self.host_label)}Too many confirmation prompts recently — wait a bit and try again.",
            )
            return
        logger.info(
            "Telegram control /%s requested by %s — awaiting in-chat confirmation.", verb, uid
        )
        await asyncio.to_thread(self._send_confirm, verb, token)

    async def _handle_callback(self, callback):
        """Handle a tapped confirm button. Answers the callback (clears the client spinner), then
        dispatches only if the token is valid, unexpired, and tapped by the same operator that issued
        it — otherwise denies. Fail-closed throughout."""
        cb_id = callback.get("id")
        chat = (callback.get("message") or {}).get("chat") or {}
        data = callback.get("data") or ""
        if cb_id:
            await asyncio.to_thread(self._answer_callback, cb_id)
        # Same outer chat boundary as messages, then the control gate does the per-operator check.
        if str(chat.get("id")) != self.chat_id:
            return
        if not self.control_enabled:
            return
        if not data.startswith("confirm:"):
            return
        uid = str((callback.get("from") or {}).get("id", ""))
        verb = self._gate.confirm(data[len("confirm:") :], uid, time.monotonic())
        if verb is None:
            logger.warning(
                "Telegram control confirm denied (stale/foreign token) for user id %s.", uid or "?"
            )
            await asyncio.to_thread(
                self._send,
                f"{_prefix(self.host_label)}⛔ Not confirmed in time (or not authorised) — denied.",
            )
            return
        await self._dispatch_control(verb, uid)

    async def _dispatch_control(self, verb, uid) -> None:
        """Drop the confirmed intent into the #33 host-control spool. This is the ONLY privileged
        leg, and it is the shared one: the root ``control-run-pending`` runner validates and runs the
        fixed verb, and records the actor + outcome in the host-side audit log. The bot never runs a
        host command itself."""
        actor = (
            f"tg-{uid}"  # 'tg-' + numeric id: passes the host actor charset, tags the audit line
        )
        try:
            rid = await asyncio.to_thread(control_service.submit, verb, None, actor)
        except Exception as exc:
            logger.warning(
                "Telegram control /%s could not be queued (%s).", verb, type(exc).__name__
            )
            await asyncio.to_thread(
                self._send,
                f"{_prefix(self.host_label)}⚠️ Could not queue {verb} — see the dashboard log.",
            )
            return
        logger.info(
            "Telegram control /%s confirmed by %s — queued to the host control spool (id %s).",
            verb,
            uid,
            rid,
        )
        await asyncio.to_thread(
            self._send,
            f"{_prefix(self.host_label)}✅ {verb.capitalize()} confirmed — the host is applying it. "
            "Use /status to watch it come back.",
        )

    def _send_confirm(self, verb, token):
        """Send the confirm prompt with a single inline button. The prompt names the CONCRETE action
        so a compromised session can't get a generic 'approve?' tapped for something else (#338)."""
        action_text = (
            "recreate the running stack" if verb == "restart" else "re-apply the host config"
        )
        text = (
            f"{_prefix(self.host_label)}Confirm /{verb}? This will {action_text}.\n"
            f"Denied automatically if not confirmed soon."
        )
        markup = {
            "inline_keyboard": [
                [{"text": f"✅ Confirm {verb}", "callback_data": f"confirm:{token}"}]
            ]
        }
        url = f"{self._api_base}/bot{self._token}/sendMessage"
        payload = {
            "chat_id": self.chat_id,
            "text": text,
            "disable_web_page_preview": True,
            "reply_markup": markup,
        }
        try:
            resp = requests.post(url, json=payload, timeout=10, proxies=self._proxies)
            resp.raise_for_status()
        except Exception as exc:
            logger.debug("Telegram confirm prompt failed (%s)", type(exc).__name__)

    def _answer_callback(self, callback_id):
        """Acknowledge a callback query so the operator's client stops showing a spinner. Best-effort:
        a failure here never blocks the dispatch decision."""
        url = f"{self._api_base}/bot{self._token}/answerCallbackQuery"
        try:
            resp = requests.post(
                url, json={"callback_query_id": callback_id}, timeout=10, proxies=self._proxies
            )
            resp.raise_for_status()
        except Exception as exc:
            logger.debug("Telegram answerCallbackQuery failed (%s)", type(exc).__name__)

    def _safe_reply_for(self, text) -> str | None:
        """Never let a formatting/read bug kill the poll loop — a broken command just goes quiet."""
        try:
            return self.reply_for(text)
        except Exception as exc:
            logger.debug("Telegram command handling failed (%s)", type(exc).__name__)
            return None

    def _send(self, text):
        """Blocking reply over Tor. Called via ``to_thread``."""
        url = f"{self._api_base}/bot{self._token}/sendMessage"
        payload = {"chat_id": self.chat_id, "text": text, "disable_web_page_preview": True}
        try:
            resp = requests.post(url, json=payload, timeout=10, proxies=self._proxies)
            resp.raise_for_status()
        except Exception as exc:
            # Log only the exception type — a requests error can embed the token-bearing URL.
            logger.debug("Telegram reply failed (%s)", type(exc).__name__)
