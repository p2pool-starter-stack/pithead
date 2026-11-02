import copy
import os
from types import SimpleNamespace

import dashboard_telemetry_plugin as adapter
import pytest

from mining_dashboard.service.data_service import DataService

# ruff: noqa: S101

pytest_plugins = ["dashboard_telemetry_plugin"]
pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)


def _outcome(function, *args):
    try:
        return "value", function(*args)
    except Exception as error:
        return "error", type(error), str(error)


def _paired(phase, args):
    expected_args = copy.deepcopy(args)
    actual_args = copy.deepcopy(args)
    service = SimpleNamespace()
    expected = _outcome(adapter.python_call, service, phase, expected_args)
    actual = _outcome(DataService._telemetry_plan, service, phase, actual_args)
    assert actual == expected
    assert actual_args == expected_args
    return actual


@pytest.mark.parametrize(
    ("now", "last", "interval", "due"),
    [
        (100.0, 0.0, 100.0, True),
        (99.999, 0.0, 100.0, False),
        (50.0, 100.0, 100.0, False),
        (-50.0, -150.0, 100.0, True),
    ],
)
def test_hourly_gate_threshold_and_backwards_clock_match(now, last, interval, due):
    outcome = _paired(
        "hourly",
        [
            now,
            last,
            interval,
            {"db_size": 123},
            {"used_gb": 4.5, "total_gb": 8.0},
        ],
    )
    assert outcome == ("value", {"due": due, "values": [123, 4.5, 8.0] if due else []})


@pytest.mark.parametrize(
    ("monero", "disk", "values"),
    [
        ({}, {}, [0, 0, 0]),
        ({"db_size": None}, {"used_gb": False, "total_gb": ""}, [0, 0, 0]),
        ({"db_size": -1}, None, [-1, 0, 0]),
    ],
)
def test_hourly_normalization_matches(monero, disk, values):
    assert _paired("hourly", [100, 0, 1, monero, disk]) == (
        "value",
        {"due": True, "values": values},
    )


def test_hourly_not_due_does_not_read_sample_shapes():
    assert _paired("hourly", [1, 1, 10, ["invalid"], ["invalid"]]) == (
        "value",
        {"due": False, "values": []},
    )


@pytest.mark.parametrize(
    "args",
    [
        [100, 0, 1, ["invalid"], {}],
        [100, 0, 1, {}, ["invalid"]],
    ],
)
def test_hourly_due_shape_failures_match(args):
    assert _paired("hourly", args)[0:2] == ("error", AttributeError)


@pytest.mark.parametrize(
    ("network", "pool", "values"),
    [
        ({}, {}, [0, 0, 0, 0]),
        (
            {"difficulty": 10, "height": 20, "reward": 0.6},
            {"hashrate": 30},
            [10, 20, 0.6, 30],
        ),
        (
            {"difficulty": None, "height": False, "reward": ""},
            {"hashrate": None},
            [0, 0, 0, 0],
        ),
    ],
)
def test_network_normalization_matches(network, pool, values):
    assert _paired("network", [network, pool]) == ("value", values)


@pytest.mark.parametrize("args", [[["invalid"], {}], [{}, ["invalid"]]])
def test_network_shape_failures_match(args):
    assert _paired("network", args)[0:2] == ("error", AttributeError)


def test_worker_gate_filter_order_and_normalization_match():
    records = [
        {
            "name": "first",
            "status": "online",
            "h15": 5,
            "accepted": 6,
            "rejected": 7,
        },
        {"name": "offline", "status": "offline", "h15": 99},
        {"status": "online", "h15": None, "accepted": False, "rejected": ""},
    ]
    assert _paired("workers", [100, 0, 100, records]) == (
        "value",
        {"due": True, "rows": [[100, "first", 5, 6, 7], [100, "", 0, 0, 0]]},
    )


@pytest.mark.parametrize(
    ("now", "last", "interval", "due"),
    [
        (100.0, 0.0, 100.0, True),
        (99.999, 0.0, 100.0, False),
        (50.0, 100.0, 100.0, False),
        (-50.0, -150.0, 100.0, True),
    ],
)
def test_worker_due_gate_threshold_and_backwards_clock_match(now, last, interval, due):
    assert _paired("worker_due", [now, last, interval]) == ("value", due)


def test_worker_not_due_does_not_read_record_shapes():
    assert _paired("workers", [99, 0, 100, [["invalid"]]]) == (
        "value",
        {"due": False, "rows": []},
    )


def test_worker_due_shape_failure_matches():
    assert _paired("workers", [100, 0, 100, [["invalid"]]])[0:2] == (
        "error",
        AttributeError,
    )
