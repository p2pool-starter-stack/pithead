import os
from types import SimpleNamespace
from unittest.mock import MagicMock

import dashboard_overview_plugin as adapter
import pytest

# ruff: noqa: S101

pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)


def _metrics(**values):
    fields = {
        "global_syncing": False,
        "mode": "Mining",
        "pool_type": "mini",
        "low_hr_warning": False,
        "xvb_enabled": False,
        "current_tier": "Disabled",
        "xvb_registration_state": "",
        "xvb_registered_at": 0,
        "shares_in_window": 1,
        "monero": SimpleNamespace(down=False),
        "tari": SimpleNamespace(down=False, percent=0),
        "monero_mode": "Unknown",
        "stratum_h15": 1234,
        "stratum_h1h": 2345,
        "stratum_h24h": 3456,
        "pool_difficulty": 1234567,
        "pool_hashrate": 987654,
        "pplns_window": 2160,
        "block_time": 10,
        "network_height": 3210123,
        "network_difficulty": 1234567890,
    }
    return SimpleNamespace(**{**fields, **values})


def _assert_call(operation, *args, **kwargs):
    expected = adapter.python_call(operation, *args, **kwargs)
    actual = adapter.NATIVES[operation](*args, **kwargs)
    assert actual == expected


@pytest.mark.parametrize("shares", [0, 1, 2**53 + 1])
def test_pool_network_matches_python_with_native_monero_input(monkeypatch, shares):
    from mining_dashboard.web.views import views

    monkeypatch.setattr(views.time, "time", lambda: 1800000000)
    data = {
        "stratum": {"shares_found": shares, "wallet": "a" * 32, "last_share_found_time": 0},
        "pool": {"pool": {"last_block_ts": 1799996339, "syncing": True}},
        "network": {"reward": 600000000000, "hash": "b" * 64},
    }
    _assert_call(
        "build_pool_network",
        data,
        _metrics(shares_in_window=shares),
        lambda *_args: {"db_size": "existing native value", "health": None},
    )


@pytest.mark.parametrize("tier", ["None", "Disabled", "Donor", None, ""])
@pytest.mark.parametrize("shares", [0, 1])
def test_raffle_eligibility_matches_python(tier, shares):
    _assert_call(
        "build_raffle_eligibility",
        _metrics(xvb_enabled=True, current_tier=tier, shares_in_window=shares),
    )


def test_raffle_log_preserves_order_limit_and_timezone(monkeypatch):
    monkeypatch.setenv("TZ", "UTC")
    wins = [
        {"ts": index, "tier": "donor", "hashrate": index * 1000, "height": index}
        for index in range(25)
    ]
    _assert_call("build_raffle_log", wins)


@pytest.mark.parametrize("level,leaks", [("ok", 0), ("warn", 0), ("bad", 1)])
def test_egress_badge_matches_python(level, leaks):
    _assert_call("_egress_badge", {"level": level, "leaks": leaks, "label": "egress status"})


@pytest.mark.parametrize(
    "latest,running",
    [
        ("v2.0.0", "v2.0.0"),
        ("v2.0.1", "v2.0.0"),
        ("v1.9.9", "v2.0.0"),
        ("invalid", "dev"),
        ("v2.0.0", None),
    ],
)
def test_update_filter_matches_python(latest, running):
    _assert_call(
        "visible_update",
        {"available": True, "latest": latest, "url": "https://example.invalid/release"},
        running,
    )


@pytest.mark.parametrize("state", ["", "invalid", "failing", "registered"])
def test_badges_match_python_for_xvb_states(state):
    metrics = _metrics(
        xvb_enabled=True,
        xvb_registration_state=state,
        xvb_registered_at=123,
        shares_in_window=0,
        low_hr_warning=True,
    )
    _assert_call("build_badges", {}, metrics, "ok", False)


@pytest.mark.parametrize("syncing", [False, True])
def test_badges_match_python_for_host_and_wallet_warnings(syncing):
    data = {
        "workers_rejected": True,
        "miner_held": True,
        "fail_closed_held": True,
        "tari_syncing_passive": True,
        "system": {
            "disk": {"percent": 99.5},
            "memory": {"total_gb": 1.5, "available_gb": 0.5},
            "hugepages": ["Disabled"],
            "avx2": False,
        },
    }
    metrics = _metrics(
        global_syncing=syncing,
        monero_mode="Pruned",
        monero=SimpleNamespace(down=True),
        tari=SimpleNamespace(down=True, percent=42.5),
    )
    _assert_call(
        "build_badges", data, metrics, "ok", False, {"old8": "old", "new8": "new", "ts": 123}
    )


def test_production_capture_has_scalar_settings_and_preserves_monero():
    from mining_dashboard import go_overview

    captured = {}
    builders = go_overview.builders(captured)
    monero = {"db_size": "existing native value"}
    skeleton = builders["build_pool_network"]({}, _metrics(), lambda *_: monero)
    assert skeleton["monero"] == monero
    assert captured["pool_network"]["args"][2] == monero
    assert builders["build_badges"]({}, _metrics(), "ok") == []
    assert set(captured["badges"]["args"][5]) == {
        "disk_warn_percent",
        "disk_critical_percent",
        "low_ram_available_gb",
        "low_ram_floor_gb",
        "monero_local",
        "tari_local",
    }


def test_wallet_prefix_mock_inputs_keep_python_string_conversion():
    _assert_call(
        "build_badges",
        {},
        _metrics(),
        "ok",
        True,
        {"old8": MagicMock(name="old"), "new8": MagicMock(name="new"), "ts": 123},
    )


@pytest.mark.asyncio
async def test_http_state_owns_overview_and_badges(aiohttp_client, monkeypatch):
    from mining_dashboard.service.storage_service import StateManager
    from mining_dashboard.web import server
    from mining_dashboard.web.views import views, xvb_views

    def fail(*_args, **_kwargs):
        raise AssertionError("Python overview or badge builder was called")

    for name in adapter.OPERATIONS:
        monkeypatch.setattr(views, name, fail)
    monkeypatch.setattr(xvb_views, "build_badges", fail)
    state = StateManager(db_path=":memory:")
    data = {
        "shares": [],
        "workers": [],
        "system": {},
        "global_sync": False,
        "monero_sync": {"percent": 100, "current": 10, "target": 10},
        "tari_sync": {"percent": 100, "current": 5, "target": 5},
    }
    try:
        client = await aiohttp_client(server.create_app(state, data))
        response = await client.get("/api/state")
        assert response.status == 200
        body = await response.json()
        assert isinstance(body["badges"], list)
        assert body["badges"][-1]["title"]
        assert "type" in body["pool"]
        assert body["raffle_wins"] == []
    finally:
        state.close()
