# ruff: noqa: S101, S603

from dataclasses import asdict

import dashboard_metrics_plugin as adapter
import pytest


class Manager:
    def __init__(self, history=None, stats=None, tiers=None):
        self.history = history or []
        self.stats = stats or {"current_mode": "P2POOL"}
        self.tiers = tiers or {
            "donor_mega": 1_000_000,
            "donor_whale": 100_000,
            "donor_vip": 10_000,
            "donor": 1_000,
        }
        self.history_calls = 0

    def get_history(self):
        self.history_calls += 1
        return self.history

    def get_xvb_stats(self):
        return self.stats

    def get_tiers(self):
        return self.tiers


def _data(**extra):
    value = {
        "shares": [],
        "workers": [],
        "global_sync": False,
        "total_live_h15": 0,
        "monero_sync": {"percent": 100, "current": 10, "target": 10},
        "tari_sync": {"percent": 100, "current": 5, "target": 5},
    }
    value.update(extra)
    return value


def _compare(data, manager, monkeypatch, history=None):
    import mining_dashboard.service.metrics as metrics

    monkeypatch.setattr(metrics.time, "time", lambda: 1_000_000.0)
    metrics._avg_p2pool_over_window = adapter.PYTHON_AVG_P2POOL
    metrics._avg_xvb_over_window = adapter.PYTHON_AVG_XVB
    try:
        expected = adapter.PYTHON_BUILD_METRICS(data, manager, history)
    finally:
        metrics._avg_p2pool_over_window = adapter.native_avg_p2pool
        metrics._avg_xvb_over_window = adapter.native_avg_xvb
    actual = adapter.native_build_metrics(data, manager, history)
    assert asdict(actual) == asdict(expected)


def test_empty_snapshot_and_lazy_history(monkeypatch):
    manager = Manager(history=[])
    _compare({}, manager, monkeypatch)
    assert manager.history_calls == 2


def test_split_history_and_legacy_rows(monkeypatch):
    history = [
        {"timestamp": 999_970, "v": 1000, "v_p2pool": 600, "v_xvb": 400},
        {"timestamp": 999_940, "v": 800, "v_p2pool": 0, "v_xvb": 0},
    ]
    _compare(_data(), Manager(history=history), monkeypatch, history=history)


def test_tier_warning_and_sync_edges(monkeypatch):
    import mining_dashboard.service.metrics as metrics

    monkeypatch.setattr(metrics, "XVB_DONATION_LEVEL", "mega")
    data = _data(
        total_live_h15=50_000,
        monero_sync={"percent": 0, "target": 0, "reachable": True, "is_syncing": False},
        tari_sync={"percent": 40, "current": 40, "target": 100},
    )
    _compare(data, Manager(), monkeypatch)


def test_stale_credited_stats_and_raw_figures(monkeypatch):
    data = _data(
        stratum={"hashrate_15m": 100, "hashrate_1h": 200, "hashrate_24h": 300},
        pool={"p2p": {"type": "Nano"}, "pool": {"difficulty": 100_000, "pplns_window": 5}},
        network={"difficulty": 380_000_000_000, "height": 3210001},
        tari={"active": True, "difficulty": 420_000_000_000, "reward": 13_000.5},
    )
    stats = {"current_mode": "XVB", "avg_1h": 50_000, "avg_24h": 50_000, "last_update": 1}
    history = [{"timestamp": 999_970, "v_p2pool": 1000, "v_xvb": 0, "v": 1000}]
    _compare(data, Manager(history=history, stats=stats), monkeypatch, history=history)


def test_domain_helper_rejects_malformed_input():
    import os
    import subprocess

    env = os.environ.copy()
    env["PITHEAD_DASHBOARD_HELPER"] = "domain"
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


@pytest.mark.asyncio
async def test_http_domain_path_does_not_call_python_metrics(aiohttp_client, monkeypatch):
    import mining_dashboard.service.metrics as metrics
    from mining_dashboard.service.storage_service import StateManager
    from mining_dashboard.web import server
    from mining_dashboard.web.views import views

    def fail(*_args, **_kwargs):
        raise AssertionError("Python build_metrics was called")

    monkeypatch.setattr(metrics, "build_metrics", fail)
    monkeypatch.setattr(server, "build_metrics", fail)
    monkeypatch.setattr(views, "build_metrics", fail)
    state_manager = StateManager(db_path=":memory:")
    app_data = {
        "shares": [],
        "workers": [],
        "monero_sync": {"percent": 100, "current": 10, "target": 10},
        "tari_sync": {"percent": 100, "current": 5, "target": 5},
        "global_sync": False,
    }
    try:
        client = await aiohttp_client(server.create_app(state_manager, app_data))
        response = await client.get("/metrics")
        assert response.status == 200
        assert "pithead_hashrate_15m_hs" in await response.text()
        state = await client.get("/api/state")
        assert state.status == 200
        assert (await state.json())["hashrate"]["total"] == "0.00 H/s"
    finally:
        state_manager.close()


@pytest.mark.parametrize("field", ["history", "shares"])
@pytest.mark.asyncio
async def test_null_timestamp_preserves_reference_error(aiohttp_client, monkeypatch, field):
    from mining_dashboard.service.storage_service import StateManager
    from mining_dashboard.web import server

    state_manager = StateManager(db_path=":memory:")
    data = {"shares": [], "workers": []}
    if field == "history":
        monkeypatch.setattr(state_manager, "get_history", lambda: [{"timestamp": None}])
    else:
        data["shares"] = [{"ts": None}]
    try:
        client = await aiohttp_client(server.create_app(state_manager, data))
        response = await client.get("/api/state")
        assert response.status == 500
        assert await response.json() == {"error": "Failed to build dashboard state."}
        response = await client.get("/metrics")
        assert response.status == 500
        assert await response.text() == "Failed to render metrics."
    finally:
        state_manager.close()
