import math
import os
from datetime import UTC, datetime

import dashboard_fleet_plugin as adapter
import pytest

# ruff: noqa: S101

pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)

NOW = 1_800_000_000.0
GIB = 1024**3


def _assert_call(operation, *args, **kwargs):
    expected = adapter.python_call(operation, *args, **kwargs)
    actual = adapter.NATIVES[operation](*args, **kwargs)
    assert actual == expected


def _fresh(**values):
    return {
        "generated_at": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        **values,
    }


def _samples(now=NOW):
    return {
        "cpu": {"sampled_at": now, "value": 0},
        "load": {"sampled_at": now, "value": [0, 0.5, 1.5]},
        "memory": {
            "sampled_at": now,
            "value": {"total": 4 * GIB, "used": GIB, "available": 3 * GIB},
        },
        "filesystem": {
            "sampled_at": now,
            "value": {"total": 500 * GIB, "used": 123 * GIB},
        },
        "hugepages": {
            "sampled_at": now,
            "value": {"total": 0, "used": 0, "free": 0},
        },
    }


def _history(count=24, interval=3600, end=NOW):
    return [
        {
            "ts": end - (count - index - 1) * interval,
            "disk_used_gb": 100 + index,
            "disk_total_gb": 500,
        }
        for index in range(count)
    ]


def test_fleet_scalar_helpers_match_python():
    for accepted, rejected in ((1000, 0), (2, 1), (90, 10), (0, 3)):
        _assert_call("_reject_flag", accepted, rejected)
    for address in ("10.0.0.1", "255.255.255.255", "nope", None):
        _assert_call("_ip_to_sort_int", address)
    for value in (None, True, 0, 1.5, "2"):
        _assert_call("_num", value)
    for value in (2.0, 2.5, 2, "2"):
        _assert_call("_fmt", value)


@pytest.mark.parametrize("shares", [1e20, 1e-7, 1e-4, 1e15, 1e16, -0.0, 1.23456789e20])
def test_worker_float_share_format_matches_python(shares):
    _assert_call(
        "build_workers",
        [
            {
                "name": "float-shares",
                "ip": "10.0.0.1",
                "status": "online",
                "accepted": shares,
                "rejected": shares,
            }
        ],
    )


def test_negative_zero_and_whitespace_ip_match_python():
    _assert_call("_fmt", -0.0)
    for address in (" 10.0.0.1", "10. 0.0.1 ", "\t10.0.0.1\n"):
        _assert_call("_ip_to_sort_int", address)


def test_rigforge_display_and_update_match_python():
    report = _fresh(
        version="1.11.1",
        miner_down=True,
        power={"watts": 142.0, "hs_per_watt": 86.9},
        health={"governor": "powersave", "throttling": True, "hugepages_total": 1280},
        watchdog={"enabled": True, "temp_c": 62, "max_temp_c": 85},
    )
    _assert_call("rigforge_display", report, True)
    worker = {
        "name": "rig",
        "ip": "10.0.0.1",
        "status": "online",
        "active_pool": "3333",
        "rigforge": report,
    }
    release = {"tag": "v1.11.2", "url": "https://example.invalid/v1.11.2"}
    _assert_call("rigforge_update_for", worker, release)


def test_workers_match_python_with_sorting_skips_and_rigforge():
    release = {"tag": "v1.11.2", "url": "https://example.invalid/v1.11.2"}
    workers = [
        {
            "name": "offline",
            "ip": "10.0.0.2",
            "status": "offline",
            "active_pool": "3344",
            "accepted": 90,
            "rejected": 10,
        },
        {
            "name": "online",
            "ip": "10.0.0.1",
            "status": "online",
            "active_pool": "3333",
            "uptime": 3661,
            "h60": 5100,
            "h15": 5200,
            "rigforge": _fresh(version="1.11.1"),
        },
        {"name": "broken", "status": "online", "active_pool": "3333"},
    ]
    _assert_call("build_workers", workers, release)


def test_energy_matches_python_with_live_and_configured_power(monkeypatch):
    from mining_dashboard.config import config
    from mining_dashboard.web.views import infra_views

    monkeypatch.setattr(infra_views.time, "time", lambda: NOW)
    monkeypatch.setattr(
        config,
        "DASHBOARD_ENERGY",
        {
            "cost_per_kwh": 0.2,
            "xmr_price": 150.0,
            "tari_price": 2.5,
            "currency": "EUR",
            "price_feed": True,
        },
    )
    monkeypatch.setattr(config, "DASHBOARD_WORKERS", [{"name": "estimated", "watts": 60}])
    generated_at = datetime.fromtimestamp(NOW, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    workers = [
        {
            "name": "measured",
            "h60": 2000,
            "rigforge": {"generated_at": generated_at, "power": {"watts": 100}},
        },
        {"name": "estimated", "h60": 1000},
        {"name": "unknown", "h60": 500},
    ]
    prices = {"xmr": 333.97, "tari": 0.4, "currency": "USD", "fetched_at": NOW - 60}
    _assert_call("build_energy", workers, prices)


def test_resources_and_capacity_match_python():
    samples = _samples()
    rows = _history()
    _assert_call("build_host_resources", samples, rows, NOW)
    filesystem = adapter.python_call("build_host_resources", samples, rows, NOW)["filesystem"]
    _assert_call("capacity_outlook", rows, filesystem, NOW)


@pytest.mark.parametrize("value", [math.nan, math.inf, -math.inf])
def test_nonfinite_resource_values_are_invalid_not_null(value):
    samples = _samples()
    samples["cpu"]["value"] = value
    _assert_call("build_host_resources", samples, [], NOW)


def test_stream_sessions_are_reused_and_restart_after_bad_request():
    fleet_pid = adapter.FLEET.pid
    resource_pid = adapter.RESOURCES.pid
    for _ in range(3):
        assert adapter.native__ip_to_sort_int("10.0.0.1") == 167772161
        assert adapter.native_build_host_resources({}, [], NOW)["cpu"]["reason"] == "missing"
    assert adapter.FLEET.pid == fleet_pid
    assert adapter.RESOURCES.pid == resource_pid
    with pytest.raises(RuntimeError):
        adapter.RESOURCES.run({"operation": "missing", "args": [], "now": NOW, "max_age": 90})
    assert adapter.RESOURCES.pid is None
    assert adapter.native_build_host_resources({}, [], NOW)["cpu"]["reason"] == "missing"
    assert adapter.RESOURCES.pid != resource_pid


def test_rigforge_fractional_stamp_is_not_trusted(monkeypatch):
    monkeypatch.setattr(adapter.time, "time", lambda: NOW)
    stamp = datetime.fromtimestamp(NOW, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    report = {"generated_at": stamp[:-1] + ".5Z", "version": "1.2.3"}
    _assert_call("rigforge_display", report, True)


@pytest.mark.parametrize("age", [True, False, "61", "bad", {"invalid": True}, 2**80])
def test_legacy_rigforge_age_inputs_match_python(age):
    _assert_call("rigforge_display", {"age_sec": age}, False)


@pytest.mark.parametrize("style", ["unpadded", "lowercase", "zero_year"])
def test_rigforge_stamp_parsing_matches_python(monkeypatch, style):
    monkeypatch.setattr(adapter.time, "time", lambda: NOW)
    stamp = datetime.fromtimestamp(NOW, UTC)
    report = {
        "generated_at": f"{stamp.year:04}-{stamp.month}-{stamp.day}T{stamp.hour}:{stamp.minute}:{stamp.second}Z",
        "version": "1.2.3",
    }
    if style == "lowercase":
        report["generated_at"] = stamp.strftime("%Y-%m-%dT%H:%M:%SZ").lower()
    elif style == "zero_year":
        report["generated_at"] = "0000-01-01T00:00:00Z"
    _assert_call("rigforge_display", report, True)


def test_large_integer_fleet_values_match_python():
    for value in (2**53 + 1, 2**80 + 123):
        _assert_call("_num", value)
        _assert_call("_fmt", value)
        _assert_call(
            "build_workers",
            [{"name": "large", "ip": "", "status": "online", "uptime": value}],
        )


def test_resource_validation_keeps_exact_integer_conservation():
    samples = _samples()
    samples["memory"]["value"] = {"total": 2**53 + 1, "used": 2**53, "available": 0}
    _assert_call("build_host_resources", samples, [], NOW)
    samples["memory"]["value"]["available"] = 1
    _assert_call("build_host_resources", samples, [], NOW)


@pytest.mark.parametrize("now", [True, False])
def test_boolean_explicit_resource_time_matches_python(now):
    _assert_call("build_host_resources", _samples(), [], now)


def test_production_resource_capture_preserves_invalid_values(monkeypatch):
    from mining_dashboard import go_fleet

    monkeypatch.setattr(go_fleet.time, "time", lambda: NOW)
    samples = _samples()
    samples["cpu"]["value"] = math.nan
    captured = {}
    go_fleet.builders(captured)["build_host_resources"](samples, [])
    request = captured["host_resources"]
    assert request["args"][0]["cpu"]["value"] == {"__pithead_nonfinite__": "nan"}
    assert adapter.RESOURCES.run(request) == adapter.python_call(
        "build_host_resources", samples, [], NOW
    )


def test_production_energy_capture_projects_only_name_and_watts(monkeypatch):
    from mining_dashboard import go_fleet
    from mining_dashboard.config import config

    endpoints = [
        {
            "name": "estimated",
            "watts": 60,
            "read_token": object(),
            "token": object(),
            "api_token": object(),
            "host": "example.invalid",
            "port": 1,
        }
    ]
    monkeypatch.setattr(config, "current_worker_endpoints", lambda: endpoints)
    captured = {}
    workers = [{"name": "estimated", "h60": 1000}]
    go_fleet.builders(captured)["build_energy"](workers, None)
    request = captured["energy"]
    assert request["args"][3] == [{"name": "estimated", "watts": 60}]
    assert adapter.FLEET.run(request) == adapter.python_call("build_energy", workers, None)


@pytest.mark.asyncio
async def test_http_state_owns_native_fleet_and_resources(aiohttp_client, monkeypatch):
    from mining_dashboard.service import host_resources
    from mining_dashboard.service.storage_service import StateManager
    from mining_dashboard.web import server
    from mining_dashboard.web.views import infra_views, views

    def fail(*_args, **_kwargs):
        raise AssertionError("Python fleet or resource builder was called")

    for module, names in (
        (infra_views, ("build_workers", "build_energy")),
        (host_resources, ("build_host_resources",)),
        (views, ("build_workers", "build_energy", "build_host_resources")),
    ):
        for name in names:
            monkeypatch.setattr(module, name, fail)
    state = StateManager(db_path=":memory:")
    data = {
        "shares": [],
        "workers": [],
        "system": {"host_resources": {}},
        "monero_sync": {"percent": 100, "current": 10, "target": 10},
        "tari_sync": {"percent": 100, "current": 5, "target": 5},
        "global_sync": False,
    }
    try:
        client = await aiohttp_client(server.create_app(state, data))
        response = await client.get("/api/state")
        assert response.status == 200
        body = await response.json()
        assert body["workers"] == []
        assert body["energy"]["available"] is False
        assert body["host_resources"]["cpu"]["reason"] == "missing"
    finally:
        state.close()
