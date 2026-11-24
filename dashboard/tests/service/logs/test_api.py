import struct

import pytest
from aiohttp import web

from mining_dashboard.config import config
from mining_dashboard.service.logs import api


def frame(text, stream=1):
    payload = text.encode()
    return bytes([stream, 0, 0, 0]) + struct.pack(">I", len(payload)) + payload


@pytest.fixture
async def docker(aiohttp_server, monkeypatch):
    seen = []
    body = {"raw": b"", "status": 200}

    async def logs(request):
        seen.append((request.match_info["name"], dict(request.query)))
        return web.Response(body=body["raw"], status=body["status"])

    app = web.Application()
    app.router.add_get("/containers/{name}/logs", logs)
    server = await aiohttp_server(app)
    monkeypatch.setattr(config, "DOCKER_PROXY_URL", f"tcp://127.0.0.1:{server.port}")
    return seen, body


def test_cursor_round_trips_at_nanosecond_precision():
    ns = api.parse_cursor("2026-11-23T10:11:12.123456789Z")
    assert api.format_cursor(ns) == "2026-11-23T10:11:12.123456789Z"
    assert api.parse_cursor("2026-11-23T10:11:12Z") % 10**9 == 0


@pytest.mark.parametrize("value", [None, "", "yesterday", "2026-11-23T10:11:12+01:00", "1; rm"])
def test_cursor_rejects_anything_that_is_not_a_timestamp(value):
    assert api.parse_cursor(value) is None


def test_the_documented_limits():
    assert api.MAX_TAIL == 500
    assert api.MAX_RESPONSE_BYTES == 256 * 1024
    assert api.IDLE_TIMEOUT_S == 60
    assert api.MAX_FOLLOWERS == 4
    assert api.MAX_LINES_PER_S == 20
    assert api.LIFETIME_S == 900


def test_bound_entries_keeps_the_newest_lines_under_the_byte_cap():
    big = "x" * 1000
    entries = [(i, big) for i in range(1, 600)]
    kept, truncated = api.bound_entries(entries)
    assert truncated
    assert kept[-1][0] == 599
    size = sum(len(api.entry_json(ns, text).encode()) + 1 for ns, text in kept)
    assert size <= api.MAX_RESPONSE_BYTES


def test_bound_entries_counts_json_escaping_not_raw_length():
    nasty = "\x01" * 1000
    kept, _ = api.bound_entries([(i, nasty) for i in range(1, 200)])
    size = sum(len(api.entry_json(ns, text).encode()) + 1 for ns, text in kept)
    assert size <= api.MAX_RESPONSE_BYTES


def test_bound_entries_drops_lines_at_or_before_the_cursor():
    kept, truncated = api.bound_entries([(1, "a"), (2, "b"), (3, "c")], since_ns=2)
    assert kept == [(3, "c")]
    assert not truncated


def test_follower_gate_admits_four_and_refuses_the_fifth():
    gate = api.FollowerGate()
    assert [gate.acquire() for _ in range(5)] == [True, True, True, True, False]
    gate.release()
    assert gate.acquire()


async def test_fetch_redacts_and_requests_timestamps(docker, monkeypatch):
    seen, body = docker
    monkeypatch.setattr(config, "LOG_API_SERVICES", ("p2pool",))
    body["raw"] = frame("2026-11-23T10:00:00.000000001Z p2pool --rpc-login u:p --x\n") + frame(
        "not-a-timestamp line\n"
    )
    entries = await api.fetch("p2pool", since_ns=api.parse_cursor("2026-11-23T09:00:00Z"), tail=7)
    assert entries == [
        (api.parse_cursor("2026-11-23T10:00:00.000000001Z"), "p2pool --rpc-login [redacted] --x")
    ]
    name, query = seen[0]
    assert name == "p2pool"
    assert query["timestamps"] == "1"
    assert query["tail"] == "7"
    assert query["since"] == "1795424400.000000000"


async def test_fetch_raises_on_a_refusing_proxy(docker):
    _, body = docker
    body["status"] = 403
    with pytest.raises(api.LogFetchError):
        await api.fetch("tor")


async def test_fetch_raises_when_the_proxy_is_unreachable(monkeypatch):
    monkeypatch.setattr(config, "DOCKER_PROXY_URL", "tcp://127.0.0.1:1")
    with pytest.raises(api.LogFetchError):
        await api.fetch("tor")
