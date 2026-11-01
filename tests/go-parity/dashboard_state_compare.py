import math
import os
import subprocess
from unittest.mock import MagicMock, patch

import pytest
from dashboard_state_plugin import BINARY, PYTHON_BUILD_CHART, native_build_chart

from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.web import server
from mining_dashboard.web.views import charts

# ruff: noqa: S101, S603

pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)

NOW = 2_000_000_000.0


@pytest.fixture
def app_data():
    return {
        "shares": [],
        "workers": [],
        "monero_sync": {"percent": 100, "current": 10, "target": 10},
        "tari_sync": {"percent": 50, "current": 5, "target": 10},
        "global_sync": False,
    }


def row(timestamp, value=100.0, p2pool=None, xvb=0.0):
    p2pool = value if p2pool is None else p2pool
    result = {
        "timestamp": timestamp,
        "t": "fixture",
        "v": value,
    }
    for suffix, scale in (("1m", 1.1), ("", 1.0), ("1h", 0.9), ("12h", 0.8), ("24h", 0.7)):
        ending = f"_{suffix}" if suffix else ""
        result[f"v_p2pool{ending}"] = p2pool * scale
        result[f"v_xvb{ending}"] = xvb * scale
    return result


def line(count, start, step=30):
    return [
        row(start + index * step, 100.005 + index / 100, 70.005 + index / 200, 30.0)
        for index in range(count)
    ]


def chart_cases():
    recent = [row(NOW - 7_200, 10), row(NOW - 60, 20)]
    yield "empty", [], [], "all", None, "10m", [], [], []
    yield "legacy", [{"timestamp": 1, "t": "x", "v": 800}], [], "all", None, "10m", [], [], []
    for average in ("1m", "10m", "1h", "12h", "24h", "unknown"):
        yield (
            f"average-{average}",
            [row(NOW - 30, 140, 100, 40)],
            [],
            "all",
            None,
            average,
            [],
            [],
            [],
        )
    for range_arg in ("1h", "24h", "1w", "1m", "all", "unknown"):
        yield f"range-{range_arg}", recent, [{"ts": NOW - 60}], range_arg, None, "10m", [], [], []
    yield "window", line(20, NOW - 600), [], "all", (NOW - 360, NOW - 180), "10m", [], [], []
    yield "zero-window", line(20, 0), [], "24h", (0, 86_400), "1m", [], [], []
    yield (
        "gap-and-shares",
        line(10, NOW - 20_000) + line(10, NOW - 1_000),
        [
            {"ts": NOW - 19_999},
            {"ts": NOW - 19_998},
            {"ts": NOW - 999},
        ],
        "all",
        None,
        "10m",
        [],
        [],
        [],
    )
    yield (
        "markers",
        [row(NOW - 60)],
        [],
        "all",
        None,
        "10m",
        [
            {"ts": NOW - 50, "type": "loss", "detail": "-62%"},
            {"ts": NOW - 40, "type": "recovered", "detail": ""},
        ],
        [{"ts": NOW - 30, "hashrate": 4.2e6, "tier": "donor", "height": 3, "block_id": "aa"}],
        [
            {
                "ts": NOW - 20,
                "amount_atomic": 1_500_000_000_000,
                "chain": "monero",
                "txid": "bb",
                "height": 4,
            }
        ],
    )
    yield "downsample-rounding", line(1_403, NOW - 100_000), [], "all", None, "24h", [], [], []
    first = line(1_000, NOW - 200_000)
    second = line(1_000, first[-1]["timestamp"] + 21_600)
    yield "downsample-gap", first + second, [], "all", None, "1h", [], [], []


@pytest.mark.parametrize("case", list(chart_cases()), ids=lambda case: case[0])
def test_native_chart_matches_python(monkeypatch, case):
    _, history, shares, range_arg, window, average, events, wins, payouts = case
    monkeypatch.setattr(charts.time, "time", lambda: NOW)
    arguments = {
        "history": history,
        "shares": shares,
        "range_arg": range_arg,
        "window": window,
        "avg_window": average,
        "events": events,
        "raffle_wins": wins,
        "payouts": payouts,
    }
    assert native_build_chart(**arguments) == PYTHON_BUILD_CHART(**arguments)


def test_native_chart_rejects_non_finite_input(monkeypatch):
    monkeypatch.setattr(charts.time, "time", lambda: NOW)
    with pytest.raises(ValueError, match="Out of range float values"):
        native_build_chart([row(NOW, math.nan)], [], "all")


def test_native_chart_materializes_empty_mock_markers(monkeypatch):
    monkeypatch.setattr(charts.time, "time", lambda: NOW)
    arguments = {
        "history": [row(NOW - 30)],
        "shares": [],
        "range_arg": "all",
        "events": MagicMock(),
        "raffle_wins": MagicMock(),
        "payouts": MagicMock(),
    }
    assert native_build_chart(**arguments) == PYTHON_BUILD_CHART(**arguments)


def test_native_chart_helper_rejects_malformed_input():
    env = os.environ.copy()
    env["PITHEAD_DASHBOARD_HELPER"] = "chart"
    result = subprocess.run(
        [BINARY], input="{", text=True, capture_output=True, env=env, timeout=10, check=False
    )
    assert result.returncode == 125
    assert result.stdout == ""
    assert result.stderr == ""


@pytest.mark.asyncio
async def test_native_http_uses_private_inputs(aiohttp_client, app_data, monkeypatch):
    calls = []

    async def rejected(request):
        calls.append(request.path)
        raise AssertionError("public Python handler was called")

    for name in ("handle_state", "handle_xvb_standby", "handle_miner_connection", "handle_metrics"):
        monkeypatch.setattr(server, name, rejected)
    state_manager = StateManager(db_path=":memory:")
    state_manager.update_xvb_stats(mode="XVB", avg_1h=1_500.0, commanded_fraction=0.37)
    try:
        with patch.object(state_manager, "get_history", wraps=state_manager.get_history) as history:
            client = await aiohttp_client(server.create_app(state_manager, app_data))
            state = await client.get("/api/state?range=24h&avg=1h")
            assert state.status == 200
            assert (await state.json())["range"] == "24h"
            assert history.call_count == 1
            standby = await client.get("/api/xvb-standby")
            connection = await client.get("/api/miner-connection")
            metrics = await client.get("/metrics")
            assert standby.status == 200
            assert (await standby.json())["commanded_fraction"] == 0.37
            assert connection.status == 200
            assert (await connection.json())["url"].startswith("stratum+")
            assert metrics.status == 200
            assert "pithead_hashrate_15m_hs" in await metrics.text()
            assert calls == []
    finally:
        state_manager.close()


@pytest.mark.asyncio
async def test_native_state_failure_is_sanitized(aiohttp_client, app_data):
    state_manager = MagicMock()
    state_manager.get_history.side_effect = RuntimeError("private fixture detail")
    client = await aiohttp_client(server.create_app(state_manager, app_data))
    response = await client.get("/api/state")
    body = await response.text()
    assert response.status == 500
    assert await response.json() == {"error": "Failed to build dashboard state."}
    assert "private fixture detail" not in body


@pytest.mark.asyncio
async def test_native_state_preserves_raw_query_contract(aiohttp_client, app_data):
    state_manager = StateManager(db_path=":memory:")
    try:
        client = await aiohttp_client(server.create_app(state_manager, app_data))
        range_response = await client.get("/api/state?range=1h;extra=1")
        average_response = await client.get("/api/state?avg=1h&avg=24h")
        private_response = await client.get("/_go/miner-connection")
        assert range_response.status == 200
        assert (await range_response.json())["range"] == "1h;extra=1"
        assert average_response.status == 200
        assert (await average_response.json())["avg_window"] == "1h"
        assert private_response.status == 404
    finally:
        state_manager.close()
