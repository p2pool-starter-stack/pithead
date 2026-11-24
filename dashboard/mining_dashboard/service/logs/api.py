import calendar
import json
import re
import time

import aiohttp

from mining_dashboard.collector.logs import _parse_docker_stream
from mining_dashboard.config import config
from mining_dashboard.helper.http import bounded_read
from mining_dashboard.service.logs.redaction import redact_line

DEFAULT_TAIL = 200
MAX_TAIL = 500
MAX_RESPONSE_BYTES = 256 * 1024
IDLE_TIMEOUT_S = 60.0
LIFETIME_S = 15 * 60.0
MAX_FOLLOWERS = 4
MAX_LINES_PER_S = 20
POLL_INTERVAL_S = 1.0
HEARTBEAT_S = 15.0
_FETCH_CAP_BYTES = 4 * 1024 * 1024

_TS = re.compile(r"^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d{1,9}))?Z$")


class LogFetchError(Exception):
    pass


def allowed(service):
    return service in config.LOG_API_SERVICES


def parse_cursor(value):
    match = _TS.match(value or "")
    if not match:
        return None
    year, month, day, hour, minute, second = (int(g) for g in match.groups()[:6])
    seconds = calendar.timegm((year, month, day, hour, minute, second))
    return seconds * 10**9 + int((match.group(7) or "").ljust(9, "0") or 0)


def format_cursor(ns):
    seconds, nanos = divmod(ns, 10**9)
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(seconds)) + f".{nanos:09d}Z"


def _split(raw):
    stamp, _, text = raw.partition(" ")
    ns = parse_cursor(stamp)
    return None if ns is None else (ns, text)


async def fetch(service, since_ns=None, tail=MAX_TAIL):
    base = config.DOCKER_PROXY_URL.replace("tcp://", "http://")
    params = {"stdout": 1, "stderr": 1, "timestamps": 1, "tail": tail}
    if since_ns is not None:
        params["since"] = f"{since_ns // 10**9}.{since_ns % 10**9:09d}"
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(
                f"{base}/containers/{service}/logs", params=params, timeout=config.DOCKER_TIMEOUT
            ) as response:
                if response.status != 200:
                    raise LogFetchError(f"status {response.status}")
                raw = await bounded_read(
                    response.content, max_bytes=_FETCH_CAP_BYTES, what=f"{service} logs"
                )
    except LogFetchError:
        raise
    except Exception as exc:
        raise LogFetchError(type(exc).__name__) from exc
    entries = []
    for line in _parse_docker_stream(raw):
        parsed = _split(line)
        if parsed:
            entries.append((parsed[0], redact_line(parsed[1])))
    return entries


def entry_json(ns, text):
    return json.dumps({"ts": format_cursor(ns), "line": text}, ensure_ascii=False)


def bound_entries(entries, since_ns=None):
    if since_ns is not None:
        entries = [e for e in entries if e[0] > since_ns]
    kept, size = [], 0
    for ns, text in reversed(entries):
        size += len(entry_json(ns, text).encode()) + 1
        if size > MAX_RESPONSE_BYTES - 1024:
            break
        kept.append((ns, text))
    kept.reverse()
    return kept, len(kept) < len(entries)


class FollowerGate:
    def __init__(self, limit=None):
        self.limit = MAX_FOLLOWERS if limit is None else limit
        self.active = 0

    def acquire(self):
        if self.active >= self.limit:
            return False
        self.active += 1
        return True

    def release(self):
        self.active = max(0, self.active - 1)
