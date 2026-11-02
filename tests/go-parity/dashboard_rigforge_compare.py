import copy
import math
import os
from datetime import UTC, datetime

import dashboard_rigforge_plugin as adapter
import pytest

from mining_dashboard.client import xmrig_client

# ruff: noqa: S101

pytest_plugins = ["dashboard_rigforge_plugin"]
pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)

NOW = datetime(2026, 9, 7, 5, tzinfo=UTC).timestamp()
SECRET = {"__secret__": True}


def _outcome(function, *args, **kwargs):
    try:
        return "value", function(*args, **kwargs)
    except Exception as error:
        return "error", type(error), str(error)


def _paired(payload, now=NOW):
    expected = _outcome(adapter.python_call, copy.deepcopy(payload), now=now)
    actual = _outcome(xmrig_client.parse_rigforge, copy.deepcopy(payload), now=now)
    assert actual == expected
    return actual


def _merge_outcome(workers, results):
    from mining_dashboard.service import data_helpers

    with adapter.python_operations():
        expected = _outcome(
            data_helpers._merge_direct_stats,
            copy.deepcopy(workers),
            copy.deepcopy(results),
            "3333",
        )
    actual = _outcome(
        data_helpers._merge_direct_stats,
        copy.deepcopy(workers),
        copy.deepcopy(results),
        "3333",
    )
    assert actual == expected
    return actual


def test_full_nullable_blocks_and_disabled_watchdog_match():
    payload = {
        "generated_at": "2026-09-07T05:00:00Z",
        "rigforge": {
            "version": "1.7.0",
            "xmrig_api": "unreachable",
            "tune": {"target": None, "autotune": None},
            "power": None,
            "health": {"firmware": None},
            "watchdog": {"mode": "disabled", "temp_c": 99, "max_temp_c": 100},
        },
    }
    kind, value = _paired(payload)
    assert kind == "value"
    assert value["miner_down"] is True
    assert value["power"] == {"watts": None, "hs_per_watt": None}
    assert value["watchdog"] == {
        "enabled": False,
        "thermal_hold": None,
        "temp_c": None,
        "max_temp_c": None,
    }


@pytest.mark.parametrize("payload", [None, [], {}, {"rigforge": None}, {"rigforge": []}])
def test_absent_and_non_object_rigforge_shapes_match(payload):
    assert _paired(payload) == ("value", None)


@pytest.mark.parametrize(
    ("path", "value"),
    [
        (("tune",), [1]),
        (("tune", "autotune"), [1]),
        (("power",), "watts"),
        (("power",), math.nan),
        (("power",), math.inf),
        (("power",), -math.inf),
        (("health",), [1]),
        (("health", "firmware"), [1]),
        (("watchdog",), [1]),
    ],
)
def test_truthy_invalid_service_shapes_raise_the_same_error(path, value):
    block = {}
    cursor = block
    for key in path[:-1]:
        cursor[key] = {}
        cursor = cursor[key]
    cursor[path[-1]] = value
    kind, error, _message = _paired({"rigforge": block})
    assert (kind, error) == ("error", AttributeError)


@pytest.mark.parametrize("value", [False, 0, "", [], {}])
def test_falsy_service_shapes_normalize_to_empty_objects(value):
    payload = {
        "rigforge": {
            "tune": value,
            "power": value,
            "health": value,
            "watchdog": value,
        }
    }
    assert _paired(payload)[0] == "value"


@pytest.mark.parametrize(
    ("stamp", "now"),
    [
        ("2026-9-7T5:0:0Z", NOW + 30.5),
        ("2026-09-07T05:00:00z", NOW),
        ("0000-01-01T00:00:00Z", NOW),
        ("2026-09-07T05:00:00Z", NOW - 60),
        ("2026-09-07T05:00:00Z", NOW - 61),
        ("2026-09-07T05:00:00Z", NOW + 60.5),
        ("2026-09-07T05:00:00Z", NOW + 61.5),
        (None, NOW),
    ],
)
def test_freshness_formats_boundaries_and_half_even_rounding_match(stamp, now):
    _paired({"generated_at": stamp, "rigforge": {"version": "1.2.3"}}, now=now)


@pytest.mark.parametrize(
    "now",
    [math.nan, math.inf, -math.inf, True, False, "invalid", 10**23, 10**400, -(10**400)],
)
def test_invalid_and_nonfinite_explicit_times_match(now):
    _paired({"generated_at": "2026-09-07T05:00:00Z", "rigforge": {}}, now=now)


def test_depth_six_masks_credentials_and_deeper_subtree_is_refused():
    within = {"pass": "within", "tls-fingerprint": "credential-fingerprint-secret"}
    beyond = {"pass": "beyond"}
    for _ in range(4):
        within = {"nested": within}
    for _ in range(5):
        beyond = {"nested": beyond}
    payload = {
        "rigforge": {
            "config": {
                "pools": [within, beyond],
                "DONATION": 1,
                "ACCESS_TOKEN": "drop-me",
            }
        }
    }
    kind, value = _paired(payload)
    assert kind == "value"
    encoded = str(value)
    assert "within" not in encoded
    assert "credential-fingerprint-secret" not in encoded
    assert "beyond" not in encoded
    assert "drop-me" not in encoded
    leaf = value["config"]["pools"][0]
    for _ in range(4):
        leaf = leaf["nested"]
    assert leaf == {"pass": SECRET, "tls-fingerprint": SECRET}
    leaf = value["config"]["pools"][1]
    for _ in range(5):
        leaf = leaf["nested"]
    assert leaf is None


@pytest.mark.parametrize(
    "meta",
    [
        {
            "revision": "a.B_c-1",
            "changed_at": "2026-09-07T05:00:00Z",
            "source": "control",
            "last_change_id": "0123456789abcdef",
        },
        {"revision": "x" * 64, "source": "local"},
        {"revision": "token\n", "source": "restore"},
        {"revision": "x" * 65, "source": "operator"},
        {"revision": "bad value", "changed_at": "2026-9-7T5:0:0Z"},
        {"changed_at": "9999-99-99T99:99:99Z", "source": "unknown"},
        {"changed_at": "٢٠٢٦-٠٩-٠٧T٠٥:٠٠:٠٠Z"},
        {"revision": None, "changed_at": None, "source": None, "last_change_id": None},
        [],
    ],
)
def test_config_metadata_regex_edges_match(meta):
    _paired({"rigforge": {"config_meta": meta}})


def test_aliases_share_the_native_parser():
    from mining_dashboard.service import data_helpers
    from mining_dashboard.service.workers import worker_refresh

    assert data_helpers.parse_rigforge is xmrig_client.parse_rigforge
    assert worker_refresh.parse_rigforge is xmrig_client.parse_rigforge


def test_main_poll_combines_native_parsing_and_merge():
    workers = [
        {
            "name": "rig",
            "ip": "10.0.0.1",
            "status": "online",
            "uptime": 0,
            "h10": 1,
            "h60": 2,
            "h15": 3,
        }
    ]
    results = [
        {
            "api_ok": True,
            "adopted": False,
            "kind": "miner",
            "uptime": 10,
            "hashrate": {"total": [4, 5, 6]},
            "rigforge": {
                "version": "1.2.3",
                "config": {"pools": [{"url": "rig:3333", "pass": "secret"}]},
            },
        }
    ]
    kind, value = _merge_outcome(workers, results)
    assert kind == "value"
    assert value[0]["rigforge"]["config"]["pools"][0]["pass"] == SECRET


def test_main_poll_parser_error_does_not_fall_back():
    workers = [
        {
            "name": "rig",
            "ip": "10.0.0.1",
            "status": "online",
            "uptime": 0,
            "h10": 1,
            "h60": 2,
            "h15": 3,
        }
    ]
    results = [{"api_ok": True, "rigforge": {"tune": ["invalid"]}}]
    kind, error, _message = _merge_outcome(workers, results)
    assert (kind, error) == ("error", AttributeError)


def test_implicit_time_is_captured_once(monkeypatch):
    calls = []

    def now():
        calls.append(None)
        return NOW + 30

    monkeypatch.setattr(xmrig_client.time, "time", now)
    payload = {"generated_at": "2026-09-07T05:00:00Z", "rigforge": {}}
    expected = adapter.python_call(copy.deepcopy(payload))
    before = len(calls)
    actual = xmrig_client.parse_rigforge(copy.deepcopy(payload))
    assert actual == expected
    assert len(calls) == before + 1


def test_native_helper_failure_never_falls_back(monkeypatch):
    from mining_dashboard import go_rigforge

    def fail(*args, **kwargs):
        del args, kwargs
        raise RuntimeError("native RigForge parser unavailable")

    monkeypatch.setattr(go_rigforge.go_channel, "call", fail)
    with pytest.raises(RuntimeError, match="native RigForge parser unavailable"):
        xmrig_client.parse_rigforge({"rigforge": {}})
