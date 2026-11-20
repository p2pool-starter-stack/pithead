import asyncio
import json
import logging
import subprocess
import sys
import threading
import time
import uuid
from types import SimpleNamespace

import requests

from mining_dashboard.config.config import (
    HEALTHCHECKS_PING_URL,
    TOR_SOCKS_PROXY,
)
from mining_dashboard.helper.http import proxy_map

logger = logging.getLogger("Healthchecks")

_PING_TIMEOUT_SEC = 10
_PING_DEADLINE_SEC = 25
_PING_HARD_LIMIT_SEC = 30
_PING_INTERVAL_SEC = 60
_PING_MIN_GAP_SEC = 5


async def _in_daemon_thread(fn):
    loop = asyncio.get_running_loop()
    fut = loop.create_future()

    def settle(setter, value):
        if not fut.done():
            setter(value)

    def work():
        try:
            result = fn()
        except Exception as e:
            loop.call_soon_threadsafe(settle, fut.set_exception, e)
        else:
            loop.call_soon_threadsafe(settle, fut.set_result, result)

    threading.Thread(target=work, daemon=True).start()
    return await fut


class PingFailure(requests.RequestException):
    def __init__(self, reason, name):
        super().__init__(name)
        self.reason = reason
        self.name = name


def _fetch(url, timeout, deadline, proxies=None):
    request = {
        "url": url,
        "proxy": proxies.get("https") if proxies else None,
        "timeout": timeout,
        "deadline": deadline,
    }
    try:
        done = subprocess.run(
            [sys.executable, "-m", "mining_dashboard.service.notify.healthchecks_child"],
            input=json.dumps(request),
            capture_output=True,
            text=True,
            timeout=_PING_HARD_LIMIT_SEC,
        )
    except subprocess.TimeoutExpired:
        raise PingFailure("tor_socks" if request["proxy"] else "connect", "Timeout") from None
    try:
        out = json.loads(done.stdout)
    except ValueError:
        raise PingFailure("connect", "ChildError") from None
    if "status" in out:
        return SimpleNamespace(status_code=out["status"])
    raise PingFailure(out["reason"], out["name"])


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
        self._proxies = proxy_map(tor_proxy)
        self._clock = clock
        self._record_failure = record_failure
        self._last_ping_ok = None
        self.failing_since = None

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

    def _isolated_proxies(self):
        if not self._tor_proxy:
            return self._proxies
        proxy = self._tor_proxy.replace("://", f"://{uuid.uuid4().hex}:isolate@", 1)
        return {"http": proxy, "https": proxy}

    def ping(self) -> bool:
        if not self.url:
            return False

        now = self._clock()
        for attempt in range(2):
            proxies = self._proxies if attempt == 0 else self._isolated_proxies()
            try:
                resp = _fetch(
                    self.url,
                    timeout=_PING_TIMEOUT_SEC,
                    deadline=_PING_DEADLINE_SEC,
                    proxies=proxies,
                )
                if 200 <= resp.status_code < 300:
                    if self._last_ping_ok is False:
                        logger.info("Healthchecks ping recovered.")
                    self._last_ping_ok = True
                    self.failing_since = None
                    return True
                self.failing_since = None
                self._record("http_status", f"HTTP {resp.status_code}")
                if attempt == 0 and resp.status_code >= 500:
                    continue
                if self._last_ping_ok is not False:
                    logger.warning("Healthchecks ping rejected: HTTP %s.", resp.status_code)
                self._last_ping_ok = False
                return False
            except requests.RequestException as e:
                logger.debug("Healthchecks ping failed (offline?): %s", e)
                self._record(_failure_class(e, bool(self._tor_proxy)), _failure_name(e))
            except Exception as e:  # pragma: no cover
                logger.debug("Healthchecks unexpected error: %s", e)
                self._record("connect", type(e).__name__)
                return False
        if self.failing_since is None:
            self.failing_since = now
        return False

    async def run(self):
        if not self.enabled:
            return
        while True:
            started = time.monotonic()
            try:
                await _in_daemon_thread(self.ping)
            except asyncio.CancelledError:
                raise
            except Exception as e:
                logger.debug("Healthchecks ping task error: %s", e)
            await asyncio.sleep(
                max(
                    min(self.interval, _PING_MIN_GAP_SEC),
                    self.interval - (time.monotonic() - started),
                )
            )

    def _record(self, reason, detail=""):
        if not self._record_failure:
            return
        try:
            self._record_failure(time.time(), reason, detail)
        except Exception:  # noqa: S110
            pass


def _failure_name(exc):
    return exc.name if isinstance(exc, PingFailure) else type(exc).__name__


def _failure_class(exc, via_proxy=False):
    if isinstance(exc, PingFailure):
        return exc.reason
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
