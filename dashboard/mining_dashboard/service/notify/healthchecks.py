"""Healthchecks.io dead-man's-switch pinger. Behaviour is described in docs/monitoring.md."""

import asyncio
import logging
import time
import uuid

import requests

from mining_dashboard.config.config import (
    HEALTHCHECKS_PING_URL,
    TOR_SOCKS_PROXY,
)
from mining_dashboard.helper.http import bounded_get

logger = logging.getLogger("Healthchecks")

_PING_TIMEOUT_SEC = 5
_PING_DEADLINE_SEC = 25
_PING_CYCLE_LIMIT_SEC = 2 * (_PING_DEADLINE_SEC + _PING_TIMEOUT_SEC)
_PING_INTERVAL_SEC = 60


class HealthchecksClient:
    def __init__(
        self,
        ping_url,
        interval_seconds,
        tor_proxy=None,
        clock=time.monotonic,
        record_failure=None,
    ):
        url = (ping_url or "").strip()
        self.url = url.rstrip("/") if url.startswith(("http://", "https://")) else ""
        self.enabled = bool(self.url)
        self.interval = max(0, int(interval_seconds or 0))
        self._tor_proxy = tor_proxy
        self._proxies = {"http": tor_proxy, "https": tor_proxy} if tor_proxy else None
        self._clock = clock
        self._record_failure = record_failure
        self._last_ping = None
        self._last_ping_ok = None

        if self.enabled:
            logger.info(
                "Healthchecks.io dead-man's switch enabled (ping every %ss, over Tor).",
                self.interval,
            )

    @classmethod
    def from_config(cls, record_failure=None):
        return cls(
            ping_url=HEALTHCHECKS_PING_URL,
            interval_seconds=_PING_INTERVAL_SEC,
            tor_proxy=TOR_SOCKS_PROXY,
            record_failure=record_failure,
        )

    def _due(self, now):
        if self._last_ping is None:
            return True
        return (now - self._last_ping) >= self.interval

    def _isolated_proxies(self):
        if not self._tor_proxy:
            return None
        proxy = self._tor_proxy.replace("://", f"://{uuid.uuid4().hex}:isolate@", 1)
        return {"http": proxy, "https": proxy}

    def ping(self) -> bool:
        if not self.url:
            return False

        now = self._clock()
        if not self._due(now):
            return False

        for attempt in range(2):
            proxies = self._proxies if attempt == 0 else self._isolated_proxies()
            try:
                resp = bounded_get(
                    self.url,
                    timeout=_PING_TIMEOUT_SEC,
                    deadline=_PING_DEADLINE_SEC,
                    proxies=proxies,
                )
                if 200 <= resp.status_code < 300:
                    if self._last_ping_ok is False:
                        logger.info("Healthchecks ping recovered.")
                    self._last_ping_ok = True
                    self._last_ping = now
                    return True
                if self._last_ping_ok is not False:
                    logger.warning("Healthchecks ping rejected: HTTP %s.", resp.status_code)
                self._last_ping_ok = False
                self._record("http_status", f"HTTP {resp.status_code}")
                return False
            except requests.RequestException as e:
                logger.debug("Healthchecks ping failed (offline?): %s", e)
                self._record(_failure_class(e, proxies is not None), type(e).__name__)
            except Exception as e:  # pragma: no cover
                logger.debug("Healthchecks unexpected error: %s", e)
                self._record("connect", type(e).__name__)
                return False
        return False

    async def run(self):
        if not self.enabled:
            return
        while True:
            started = time.monotonic()
            try:
                await asyncio.wait_for(asyncio.to_thread(self.ping), _PING_CYCLE_LIMIT_SEC)
            except asyncio.CancelledError:
                raise
            except Exception as e:
                logger.debug("Healthchecks ping task error: %s", e)
            await asyncio.sleep(max(0, self.interval - (time.monotonic() - started)))

    def _record(self, reason, detail=""):
        if not self._record_failure:
            return
        try:
            self._record_failure(time.time(), reason, detail)
        except Exception:  # noqa: S110
            pass


def _failure_class(exc, via_proxy=False):
    if isinstance(exc, requests.exceptions.ProxyError):
        return "tor_socks"
    cause = exc.__cause__ or exc.__context__
    hops = 0
    while cause is not None and hops < 10:
        name = type(cause).__name__
        if name.startswith("Proxy"):
            return "tor_socks"
        if name in ("NameResolutionError", "gaierror"):
            return "dns"
        cause = cause.__cause__ or cause.__context__
        hops += 1
    if via_proxy and isinstance(exc, (requests.ConnectionError, requests.Timeout)):
        if not isinstance(exc, requests.exceptions.SSLError):
            return "tor_socks"
    return "connect"
