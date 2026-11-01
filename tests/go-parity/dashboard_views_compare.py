import os
import subprocess
from types import SimpleNamespace
from unittest.mock import MagicMock

import dashboard_views_plugin as adapter
import pytest

# ruff: noqa: S101, S603

pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)

NOW = 2_000_000_000.0


def _sync(**overrides):
    values = {
        "percent": 100,
        "current": 10,
        "target": 10,
        "remaining": 0,
        "has_target": True,
        "done": True,
        "down": False,
    }
    values.update(overrides)
    return SimpleNamespace(**values)


def _metrics(**overrides):
    values = {
        "mode": "P2POOL",
        "total_h15": 10_500.0,
        "p2pool_1h": 8_000.0,
        "p2pool_24h": 8_100.0,
        "xvb_1h": 2_100.0,
        "xvb_24h": 2_300.0,
        "xvb_routed_1h": 2_000.0,
        "xvb_routed_24h": 2_050.0,
        "current_tier": "Donor",
        "target_tier": "Donor",
        "xvb_fail_count": 0,
        "xvb_last_update": 0.0,
        "xvb_stale": False,
        "low_hr_warning": False,
        "last_block_ts": 0.0,
        "expected_share_sec": 0.0,
        "luck_pct": 0.0,
        "own_pplns_weight": 0.0,
        "monero": _sync(),
        "tari": _sync(),
        "monero_mode": "Unknown",
        "monero_local": True,
        "tari_local": True,
    }
    values.update(overrides)
    return SimpleNamespace(**values)


def _assert_call(operation, *args, **kwargs):
    expected = adapter.python_call(operation, *args, **kwargs)
    actual = adapter.NATIVES[operation](*args, **kwargs)
    assert actual == expected


def test_proxy_percentage_preserves_python_operation_order():
    data = {"proxy_summary": {"accepted": 19_993, "rejected": 7}}
    _assert_call("build_proxy_summary", data)
    assert adapter.native_build_proxy_summary(data)["reject_pct"] == "0.03%"


@pytest.mark.parametrize("timestamp", [9_007_199_254_740_993, 1e20])
def test_large_series_timestamps_match_python(timestamp):
    _assert_call("build_blocks", [{"ts": timestamp}], "all")


def test_cadence_formats_duration_above_int64(monkeypatch):
    from mining_dashboard.web.views import series_views

    monkeypatch.setattr(series_views.time, "time", lambda: NOW)
    _assert_call("build_cadence", _metrics(expected_share_sec=1e20))


@pytest.mark.parametrize("timestamp", [None, [], {}, False, 0.0])
def test_falsy_time_values_match_python(timestamp):
    _assert_call("build_hashrate", _metrics(xvb_last_update=timestamp), "ok", "ok", "muted")
    _assert_call("build_cadence", _metrics(last_block_ts=timestamp))


def test_integer_bucket_totals_preserve_precision():
    gauges = [
        {"ts": 1, "value": 9_007_199_254_740_993},
        {"ts": 2, "value": -9_007_199_254_740_992},
    ]
    _assert_call("_downsample_gauge_rows", gauges, ["value"], target=1)
    shares = [{"ts": 1, "accepted": 2**63}, {"ts": 2, "accepted": 3}]
    _assert_call("_downsample_share_stats", shares, target=1)


@pytest.mark.parametrize("component", ["disk", "memory"])
@pytest.mark.asyncio
async def test_numeric_string_percentage_preserves_failure(aiohttp_client, component):
    from mining_dashboard.service.storage_service import StateManager
    from mining_dashboard.web import server

    data = {"system": {component: {"percent": "95"}}, "shares": [], "workers": []}
    with pytest.raises(TypeError):
        adapter.python_call("build_system", data)
    state = StateManager(db_path=":memory:")
    try:
        client = await aiohttp_client(server.create_app(state, data))
        response = await client.get("/api/state")
        assert response.status == 500
        assert await response.json() == {"error": "Failed to build dashboard state."}
    finally:
        state.close()


@pytest.mark.asyncio
async def test_invalid_storage_rows_preserve_reference_failure(aiohttp_client, monkeypatch):
    from mining_dashboard.service.storage_service import StateManager
    from mining_dashboard.web import server

    with pytest.raises(TypeError):
        adapter.python_call("build_blocks", None, "all")
    state = StateManager(db_path=":memory:")
    monkeypatch.setattr(state, "get_blocks", lambda: None)
    try:
        client = await aiohttp_client(server.create_app(state, {"shares": [], "workers": []}))
        response = await client.get("/api/state")
        assert response.status == 500
        assert await response.json() == {"error": "Failed to build dashboard state."}
    finally:
        state.close()


@pytest.mark.parametrize(
    ("mode", "expected"),
    [
        ("P2POOL", ("ok", "ok", "muted")),
        ("XVB", ("purple", "muted", "purple")),
        ("XVB (Split)", ("accent", "ok", "purple")),
    ],
)
def test_mode_palette_matches_python(mode, expected):
    _assert_call("_mode_palette", mode)
    assert adapter.native__mode_palette(mode) == expected


def test_share_series_filter_sum_and_nulls(monkeypatch):
    from mining_dashboard.web.views import series_views

    monkeypatch.setattr(series_views.time, "time", lambda: NOW)
    rows = [
        {"ts": NOW - 4_000, "accepted": 9, "rejected": 1},
        {"ts": NOW - 30, "accepted": None, "rejected": 2, "invalid": 1},
        {"ts": NOW - 10, "accepted": 3, "expired": 4},
    ]
    _assert_call("build_share_stats", rows, "1h", None)
    _assert_call("_filter_share_stats", rows, "all", (NOW - 35, NOW - 5))
    _assert_call("_downsample_share_stats", rows * 5, target=4)
    _assert_call("_window_reject_pct", rows, 3_600)
    _assert_call("_window_reject_pct", [], 3_600)


def test_event_payout_and_gauge_series_match_python(monkeypatch):
    from mining_dashboard.config import config
    from mining_dashboard.web.views import series_views

    monkeypatch.setattr(series_views.time, "time", lambda: NOW)
    events = [
        {"ts": NOW - 100, "height": 4, "difficulty": 12.5},
        {"ts": NOW - 50, "height": None},
    ]
    gauges = [{"ts": NOW - index, "avg_1h": index + 0.125, "avg_24h": None} for index in range(12)]
    _assert_call("build_blocks", events, "all", (NOW - 200, NOW))
    _assert_call("_downsample_gauge_rows", gauges, ("avg_1h", "avg_24h"), target=5)
    _assert_call("_gauge_series", gauges, "all", None, ("avg_1h", "avg_24h"))
    _assert_call("build_disk_growth", [], "all")
    _assert_call("build_xvb_history", gauges, "24h")

    manager = MagicMock()
    manager.get_payouts.side_effect = lambda chain: [
        {"ts": NOW - 20, "amount_atomic": 1_234_567 if chain == "monero" else 8.5}
    ]
    monkeypatch.setattr(config, "PAYOUT_CONFIRM_ENABLED", True)
    monkeypatch.setattr(config, "TARI_PAYOUT_CONFIRM_ENABLED", True)
    _assert_call("build_payouts", manager, "all", (NOW - 30, NOW))
    _assert_call("build_payouts", None, "all")


def test_hashrate_and_cadence_accept_namespace_metrics(monkeypatch):
    from mining_dashboard.web.views import series_views

    monkeypatch.setattr(series_views.time, "time", lambda: NOW)
    metrics = _metrics(
        mode="XVB (Split)",
        low_hr_warning=True,
        xvb_last_update=NOW - 30,
        last_block_ts=NOW - 90,
        expected_share_sec=3_661.5,
        luck_pct=123.5,
        own_pplns_weight=1_234_567.25,
    )
    _assert_call("build_hashrate", metrics, "accent", "ok", "purple")
    _assert_call("build_cadence", metrics)


@pytest.mark.parametrize(
    ("operation", "args"),
    [
        (
            "build_system",
            (
                {
                    "system": {
                        "cpu_percent": "n/a",
                        "load": "1 2 3",
                        "memory": {"used_gb": 1.25, "total_gb": 2.5, "percent": 81},
                        "disk": {"used_gb": 1_024.5, "total_gb": 2_048, "percent": 90.5},
                        "hugepages": ["Enabled", "status-ok", "3/4"],
                    }
                },
            ),
        ),
        (
            "build_proxy_summary",
            ({"proxy_summary": {"accepted": 90, "rejected": 10, "best": 12_345.5}},),
        ),
        (
            "build_tari",
            (
                {
                    "tari": {
                        "active": True,
                        "connected": True,
                        "status": "READY",
                        "reward": 12.125,
                        "difficulty": 1_234_567,
                        "address": "T" * 40,
                    },
                    "tari_sync": {
                        "health": {
                            "level": "red",
                            "reasons": ["behind", "no peers"],
                            "advice": "Wait",
                        }
                    },
                },
            ),
        ),
    ],
)
def test_infrastructure_dict_builders_match_python(operation, args):
    _assert_call(operation, *args)


def test_sync_and_monero_accept_namespace_metrics():
    metrics = _metrics(
        monero=_sync(has_target=False, done=True, current=0, target=0),
        tari=_sync(has_target=True, done=False, percent=12, remaining=88),
        monero_mode="Pruned",
        monero_local=False,
        tari_local=None,
    )
    _assert_call("build_sync", metrics, "85.5 GB")
    data = {
        "monero_sync": {
            "db_size": 8_500_000_000,
            "health": {
                "level": "red",
                "peers_out": 0,
                "peers_in": None,
                "advance_age_sec": 125,
                "reasons": ["No outgoing peers"],
                "advice": "Check the node",
            },
        }
    }
    _assert_call("build_monero", data, metrics)


@pytest.mark.asyncio
async def test_http_state_owns_native_view_sections(aiohttp_client, monkeypatch):
    import mining_dashboard.service.metrics as metrics
    from mining_dashboard.service.storage_service import StateManager
    from mining_dashboard.web import server
    from mining_dashboard.web.views import infra_views, monero_view, series_views, views

    def fail(*_args, **_kwargs):
        raise AssertionError("Python dashboard view builder was called")

    for module in (metrics, server, views):
        monkeypatch.setattr(module, "build_metrics", fail)
    for name in (
        "build_share_stats",
        "_window_reject_pct",
        "build_blocks",
        "build_payouts",
        "build_disk_growth",
        "build_xvb_history",
        "build_hashrate",
        "build_cadence",
    ):
        monkeypatch.setattr(series_views, name, fail)
        monkeypatch.setattr(views, name, fail)
    for name in ("build_system", "build_proxy_summary", "build_tari", "build_sync"):
        monkeypatch.setattr(infra_views, name, fail)
        monkeypatch.setattr(views, name, fail)
    monkeypatch.setattr(monero_view, "build_monero", fail)
    monkeypatch.setattr(views, "build_monero", fail)

    state_manager = StateManager(db_path=":memory:")
    data = {
        "shares": [],
        "workers": [],
        "monero_sync": {"percent": 100, "current": 10, "target": 10},
        "tari_sync": {"percent": 100, "current": 5, "target": 5},
        "global_sync": False,
    }
    try:
        client = await aiohttp_client(server.create_app(state_manager, data))
        response = await client.get("/api/state?range=24h&avg=1h")
        assert response.status == 200
        body = await response.json()
        assert body["range"] == "24h"
        assert body["hashrate"]["total"] == "0.00 H/s"
        assert body["system"]["disk"]["fill"] == ""
        assert body["share_stats"] == []
    finally:
        state_manager.close()


@pytest.mark.parametrize("helper", ["series", "infra"])
def test_view_helper_rejects_malformed_input(helper):
    env = os.environ.copy()
    env["PITHEAD_DASHBOARD_HELPER"] = helper
    result = subprocess.run(
        [adapter.BINARY],
        input="{",
        text=True,
        capture_output=True,
        env=env,
        timeout=10,
        check=False,
    )
    assert result.returncode == 125
    assert result.stdout == ""
    assert result.stderr == ""


def test_average_session_recovers_after_bad_input():
    session = adapter.AverageSession(adapter.BINARY, adapter.REPO_ROOT)
    try:
        with pytest.raises(RuntimeError):
            session.run_average([], 60, "bad", False)
        rows = [{"timestamp": 10, "v_p2pool": 12, "v_xvb": 4}]
        assert session.run_average(rows, 60, 10, False) == 12
        assert session.run_average(rows, 60, 10, True) == 4
        with pytest.raises(ValueError):
            session.run_average([], 60, float("nan"), False)
        assert session.run_average([], 60, 10, False) == 0
    finally:
        session.close()
    session.close()
    with pytest.raises(RuntimeError):
        session.run_average([], 60, 10, False)
