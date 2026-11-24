import json

import pytest

from mining_dashboard.client.rig_reply import usable_reply
from mining_dashboard.client.xmrig_client import (
    XMRigWorkerClient,
    parse_rigforge,
    parse_worker_control_status,
)
from mining_dashboard.service import mining_verdict as mv
from mining_dashboard.service.data_helpers import _merge_direct_stats
from mining_dashboard.service.workers.worker_change_audit import note_revision_drift

BIG = "9" * 400
LONG = "v" * 900_000

HOSTILE = [
    '{"hashrate": null}',
    '{"hashrate": "x"}',
    '{"hashrate": {"total": ["a", "b", "c"]}}',
    '{"hashrate": {"total": [NaN, Infinity, 1e308]}}',
    '{"hashrate": {"total": [true, "5", null]}}',
    '{"hashrate": {"total": [1e999, 1.7e308, -1.7e308]}}',
    '{"hashrate": {"total": [@, 1, 1]}}'.replace("@", BIG),
    '{"uptime": "@"}'.replace("@", BIG),
    '{"uptime": @}'.replace("@", BIG),
    '{"uptime": Infinity}',
    '{"kind": ["proxy"]}',
    '{"connection": null}',
    '{"connection": {"uptime": "5", "pool": ["x"]}}',
    '{"connection": {"uptime": 5, "pool": "h:@"}}'.replace("@", "9" * 5000),
    '{"connection": {"uptime": 5, "pool": "host\\u202e:3333"}}',
    '{"rigforge": "x"}',
    '{"rigforge": [1]}',
    '{"rigforge": 5}',
    '{"rigforge": {"tune": "x"}}',
    '{"rigforge": {"tune": {"autotune": [1]}}}',
    '{"rigforge": {"power": "x"}}',
    '{"rigforge": {"watchdog": "x"}}',
    '{"rigforge": {"health": "x"}}',
    '{"rigforge": {"health": {"firmware": [1]}}}',
    '{"rigforge": {"version": "@"}}'.replace("@", LONG),
    '{"rigforge": {"health": {"governor": "x\\n\\u202eperformance"}}}',
    '{"rigforge": {"power": {"watts": "300", "hs_per_watt": "9"}}}',
    '{"rigforge": {"power": {"watts": NaN, "hs_per_watt": 1e999}}}',
    '{"rigforge": {"watchdog": {"mode": "enabled", "temp_c": "hot", "max_temp_c": true}}}',
    '{"rigforge": {"config": "x"}}',
    '{"rigforge": {"config": {"DONATION": 1e999, "pools": [{"url": "@"}]}}}'.replace("@", LONG),
    '{"rigforge": {"config_meta": "x"}}',
    '{"rigforge": {"config_meta": {"revision": @}}}'.replace("@", BIG),
    '{"rigforge": {"control": "x"}}',
    '{"rigforge": {"control": {"change_id": 5, "status": ["applied"]}}}',
    '{"rigforge": {"control": {"change_id": "x", "status": "applied", "reason": "@"}}}'.replace(
        "@", LONG
    ),
]


def _row(name):
    return {
        "name": name,
        "ip": "10.0.0.1",
        "status": "online",
        "h10": 1,
        "h60": 2,
        "h15": 3,
        "uptime": 0,
    }


def _reply(raw):
    reply = usable_reply(json.loads(raw))
    reply["api_ok"], reply["adopted"] = True, False
    return reply


@pytest.mark.parametrize("raw", HOSTILE, ids=lambda raw: raw[:48])
async def test_hostile_reply_reaches_no_reader_unchecked(raw):
    reply = _reply(raw)
    good = {"api_ok": True, "uptime": 50, "hashrate": {"total": [4, 5, 6]}}

    await note_revision_drift(None, {"name": ""}, reply, cap=1, window_sec=60)
    parse_worker_control_status(reply)
    mv.mining_verdict(reply, ("127.0.0.1",), 3333)
    [bad, ok] = _merge_direct_stats([_row("bad"), _row("ok")], [reply, good], "3333")

    assert (ok["telemetry_h10"], ok["telemetry_h60"], ok["telemetry_h15"]) == (4, 5, 6)
    assert ok["uptime"] == 50
    assert len(json.dumps(bad, allow_nan=False)) < 20_000
    for key in ("uptime", "telemetry_h10", "telemetry_h60", "telemetry_h15"):
        assert type(bad.get(key, 0)) in (int, float), key
    assert bad["mining"]["pool"] is None or bad["mining"]["pool"].isprintable()


@pytest.mark.parametrize("block", ['"x"', "[1]", "5"])
async def test_revision_drift_ignores_a_rigforge_block_that_is_not_an_object(block):
    raw = json.loads('{"api_ok": true, "rigforge": @}'.replace("@", block))
    await note_revision_drift(None, {"name": "rig"}, raw, cap=1, window_sec=60)


def test_wrong_types_are_dropped_and_real_values_kept():
    reply = _reply(
        '{"uptime": "9", "rigforge": {"version": 5, "stamp": "@", "power": {"watts": "300"},'
        ' "health": {"governor": "performance", "throttling": "no", "firmware": {"board": "B650"}},'
        ' "watchdog": {"mode": "enabled", "temp_c": 61, "thermal_hold": false}}}'.replace(
            "@", "s" * 200
        )
    )
    assert "uptime" not in reply
    block = parse_rigforge(reply)
    assert block["version"] is None and block["stamp"] == "s" * 200
    assert block["power"] == {"watts": None, "hs_per_watt": None}
    assert block["health"]["governor"] == "performance" and block["health"]["board"] == "B650"
    assert block["health"]["throttling"] is None
    assert block["watchdog"]["temp_c"] == 61 and block["watchdog"]["thermal_hold"] is False


def test_unread_values_are_bounded_and_a_long_reason_is_clipped():
    reply = _reply(
        '{"extra": {"n": 1e999, "s": "@"}, "rigforge": {"config": {"DONATION": 1e999},'
        ' "control": {"change_id": "c1", "status": "failed", "reason": "#"}}}'.replace(
            "@", LONG
        ).replace("#", "r" * 900)
    )
    assert reply["extra"] == {"n": 0, "s": "v" * 1024}
    assert reply["rigforge"]["config"]["DONATION"] == 0
    assert parse_worker_control_status(reply)["reason"] == "r" * 500


class _Response:
    def __init__(self, status, payload):
        self.status, self._raw, self.content = status, json.dumps(payload).encode(), self

    async def read(self, n=-1):
        chunk, self._raw = self._raw[:n], self._raw[n:]
        return chunk


class _Get:
    def __init__(self, response):
        self._response = response

    async def __aenter__(self):
        return self._response

    async def __aexit__(self, *exc):
        return False


class _Session:
    def __init__(self, first, followed=None):
        self._first, self._followed = first, followed

    def get(self, url, headers=None, timeout=None, allow_redirects=True):
        return _Get(self._followed if allow_redirects and self._followed else self._first)


async def test_a_redirect_from_a_rig_is_not_followed():
    followed = _Response(200, {"kind": "internal", "uptime": 777})
    client = XMRigWorkerClient(_Session(_Response(302, {}), followed))
    assert await client.get_stats("10.0.0.1", "rig1") == {"api_ok": False, "adopted": False}


async def test_get_stats_returns_the_checked_reply():
    session = _Session(_Response(200, {"uptime": float("inf"), "rigforge": "x", "kind": "proxy"}))
    reply = await XMRigWorkerClient(session).get_stats("10.0.0.1", "rig1")
    assert reply == {"kind": "proxy", "api_ok": True, "adopted": False}
