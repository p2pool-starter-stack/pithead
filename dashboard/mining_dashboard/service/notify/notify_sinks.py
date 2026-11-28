import logging
import time

import requests

from mining_dashboard.config.config import (
    NOTIFY_TOR,
    NOTIFY_WEBHOOK_URLS,
    NTFY_TOKEN,
    NTFY_URL,
    TOR_SOCKS_PROXY,
)
from mining_dashboard.helper.http import (
    PROXY_PURPOSE_NOTIFY,
    purpose_proxy_map,
    raise_for_success,
    refuse_direct_public,
    request_failure_class,
)

logger = logging.getLogger("NotifySinks")


class _HttpSink:
    """
    Shared plumbing for the push-only HTTP alert sinks (#380). Copies
    :class:`~mining_dashboard.service.notify.telegram_notifier.TelegramNotifier`'s discipline exactly:

    - **Disabled unless configured.** A blank URL keeps the sink off; :meth:`send` is a silent
      no-op, never an error.
    - **Tor-routed by default.** POSTs ride the bridge Tor SOCKS proxy (``socks5h``, DNS included)
      so the endpoint sees a Tor exit, not the host IP (#340 posture). ``notifications.tor: false``
      passes an empty ``tor_proxy`` for LAN/self-hosted endpoints Tor can't reach.
    - **Fail silent.** Any network error is swallowed and logged at debug — an alerter must never
      crash the data loop or spam ERROR for the very condition it exists to report.
    - **Never logs the URL.** Webhook query strings and ntfy topic URLs are capability secrets; a
      ``requests`` error message can embed the full URL, so only the exception *type* is logged.

    Sinks carry every event kind: ``event_enabled`` just mirrors ``enabled``, and the interface
    leaves room for per-sink toggles later without redesign (per-event filtering stays a
    Telegram-only feature for now).
    """

    label = "sink"

    def __init__(self, url, tor_proxy=TOR_SOCKS_PROXY, timeout=10, direct=False):
        self.url = (url or "").strip()
        self.timeout = timeout
        self._proxies = None if direct else purpose_proxy_map(tor_proxy, PROXY_PURPOSE_NOTIFY)
        self.enabled = bool(self.url)
        self.last_failure = ""

    def event_enabled(self, event):
        """This sink pushes every event kind — enabled is the only gate."""
        return self.enabled

    def _post(self, **kwargs) -> bool:
        self.last_failure = ""
        if not self.enabled:
            return False
        try:
            if self._proxies is not None:
                refuse_direct_public(self.url, self._proxies)
            with requests.post(
                self.url,
                timeout=self.timeout,
                proxies=self._proxies,
                stream=True,
                allow_redirects=False,
                **kwargs,
            ) as resp:
                raise_for_success(resp)
            return True
        except requests.RequestException as exc:
            self.last_failure = request_failure_class(exc)
            # Type only: a requests error message can embed the URL, which may carry a token.
            logger.debug("%s send failed (%s)", self.label, type(exc).__name__)
            return False


class WebhookSink(_HttpSink):
    """POST each alert as JSON ``{"event", "text", "ts"}`` to one operator-configured URL."""

    label = "Webhook"

    def send(self, text, event=""):
        """Push one alert. Returns True on a 2xx, False otherwise. Never raises."""
        return self._post(json={"event": event, "text": text, "ts": int(time.time())})


class NtfySink(_HttpSink):
    """POST each alert's text as the body of an ntfy topic URL (``https://server/topic``),
    with an optional ``Authorization: Bearer`` token for protected topics."""

    label = "ntfy"

    def __init__(self, url, token="", tor_proxy=TOR_SOCKS_PROXY, timeout=10, direct=False):
        super().__init__(url, tor_proxy=tor_proxy, timeout=timeout, direct=direct)
        self._headers = {"Authorization": f"Bearer {token}"} if token else None

    def send(self, text, event=""):
        """Push one alert (``event`` is carried for interface parity; ntfy gets the text)."""
        return self._post(data=text.encode("utf-8"), headers=self._headers)


def config_sinks():
    """The webhook/ntfy sinks the process config enables — ``[]`` on a default stack."""
    direct = not NOTIFY_TOR
    sinks = [WebhookSink(u, tor_proxy=TOR_SOCKS_PROXY, direct=direct) for u in NOTIFY_WEBHOOK_URLS]
    if NTFY_URL:
        sinks.append(NtfySink(NTFY_URL, token=NTFY_TOKEN, tor_proxy=TOR_SOCKS_PROXY, direct=direct))
    return sinks
