import asyncio
import json
import logging
import time
import uuid
from datetime import UTC, datetime

from aiohttp import web

from mining_dashboard.service import audit_service
from mining_dashboard.service.logs import api

logger = logging.getLogger(__name__)

_HEADERS = {"Cache-Control": "no-store"}


def _reply(status, message, **headers):
    return web.json_response({"error": message}, status=status, headers={**_HEADERS, **headers})


async def _audit(request, action, status):
    state = request.app.get("state_manager")
    if state is None:
        return
    try:
        await asyncio.to_thread(
            state.add_audit_event,
            id=f"api-{uuid.uuid4()}",
            ts=datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
            source="api",
            actor=audit_service._clean(request.headers.get("X-Auth-User", ""), 64),
            action=action,
            status=str(status),
            keys=audit_service._clean(request.match_info.get("service", ""), 400),
        )
    except Exception:
        logger.exception("Could not record the log API audit row")


def _parse(request):
    service = request.match_info["service"]
    if not request.headers.get("X-Auth-User"):
        return None, _reply(401, "Authentication required.", **{"WWW-Authenticate": "Basic"})
    if not api.allowed(service):
        return None, _reply(404, "Unknown service.")
    raw_lines = request.query.get("lines", str(api.DEFAULT_TAIL))
    if (
        not raw_lines.isascii()
        or not raw_lines.isdigit()
        or not 1 <= int(raw_lines) <= api.MAX_TAIL
    ):
        return None, _reply(400, f"'lines' must be an integer from 1 to {api.MAX_TAIL}.")
    raw_since = request.query.get("since")
    since = None
    if raw_since is not None:
        since = api.parse_cursor(raw_since)
        if since is None:
            return None, _reply(400, "'since' must be a cursor returned by this API.")
    return (service, int(raw_lines), since), None


async def handle_logs(request):
    parsed, error = _parse(request)
    if error is not None:
        await _audit(request, "log-read", error.status)
        return error
    service, lines, since = parsed
    try:
        entries = await api.fetch(service, since_ns=since, tail=lines)
    except api.LogFetchError:
        await _audit(request, "log-read", 502)
        return _reply(502, "Could not read the service logs.")
    kept, truncated = api.bound_entries(entries, since)
    cursor = api.format_cursor(kept[-1][0]) if kept else request.query.get("since")
    await _audit(request, "log-read", 200)
    return web.json_response(
        {
            "service": service,
            "lines": [{"ts": api.format_cursor(ns), "line": text} for ns, text in kept],
            "since": cursor,
            "truncated": truncated,
        },
        headers=_HEADERS,
    )


async def _send(stream, text):
    await stream.write(text.encode())


async def handle_follow(request):
    parsed, error = _parse(request)
    if error is not None:
        await _audit(request, "log-follow", error.status)
        return error
    service, _, since = parsed
    gate = request.app["log_gate"]
    if not gate.acquire():
        await _audit(request, "log-follow", 429)
        return _reply(429, "Too many concurrent log followers.", **{"Retry-After": "5"})
    stream = web.StreamResponse(
        headers={
            **_HEADERS,
            "Content-Type": "text/event-stream",
            "X-Accel-Buffering": "no",
        }
    )
    reason = "disconnected"
    try:
        await stream.prepare(request)
        await _audit(request, "log-follow", 200)
        cursor = since if since is not None else time.time_ns()
        started = last_line = last_beat = time.monotonic()
        while True:
            now = time.monotonic()
            if now - started >= api.LIFETIME_S:
                reason = "lifetime"
                break
            if now - last_line >= api.IDLE_TIMEOUT_S:
                reason = "idle"
                break
            try:
                entries = await api.fetch(service, since_ns=cursor)
            except api.LogFetchError:
                entries = []
            for ns, text in api.bound_entries(entries, cursor)[0]:
                await _send(
                    stream, f"id: {api.format_cursor(ns)}\ndata: {api.entry_json(ns, text)}\n\n"
                )
                cursor = ns
                last_line = last_beat = time.monotonic()
                await asyncio.sleep(1 / api.MAX_LINES_PER_S)
            if time.monotonic() - last_beat >= api.HEARTBEAT_S:
                await _send(stream, ": keep-alive\n\n")
                last_beat = time.monotonic()
            await asyncio.sleep(api.POLL_INTERVAL_S)
        await _send(stream, f"event: end\ndata: {json.dumps({'reason': reason})}\n\n")
        await stream.write_eof()
    except (ConnectionResetError, ConnectionError):
        pass
    finally:
        gate.release()
    return stream


def routes():
    return [
        web.get("/api/logs/{service}", handle_logs),
        web.get("/api/logs/{service}/follow", handle_follow),
    ]
