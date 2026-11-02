import os

import dashboard_worker_detail_plugin as adapter
import pytest
from dashboard_worker_detail_compare import State

# ruff: noqa: S101

pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)


@pytest.mark.parametrize(
    ("applied", "rig"),
    [
        ("0x1p2", 4),
        ("1e999", "inf"),
        ("-1e999", "-Infinity"),
        ("٥", 5),
        ("١_٢.٥", 12.5),
        ("1__2", 12),
        ("\U00011f51", 1),
        (" 5 ", 5),
    ],
)
def test_numeric_string_grammar_matches_python(applied, rig):
    left, right = {"DONATION": applied}, {"DONATION": rig}
    expected = adapter.python_call("config_drift", left, right)
    assert adapter.NATIVES["config_drift"](left, right) == expected


@pytest.mark.parametrize("stamp", [0, False, None])
def test_false_history_timestamp_stays_empty(stamp):
    class WithoutMarkers(State):
        def get_worker_config_history(self, worker, limit=50):
            return [] if limit == 200 else super().get_worker_config_history(worker, limit)

    state = WithoutMarkers(
        history=[{"ts": stamp, "status": "applied"}],
        by_config=[{"ts": stamp, "avg_h15": 0, "min_h15": 0, "max_h15": 0}],
    )
    expected = adapter.python_call("build_worker_detail", "rig", {}, state)
    actual = adapter.NATIVES["build_worker_detail"]("rig", {}, state)
    assert actual == expected
    assert actual["history"][0]["applied_at"] == ""
    assert actual["hashrate_by_config"][0]["applied_at"] == ""


def test_large_integer_marker_does_not_require_local_time_formatting():
    state = State(history=[{"ts": 10**20, "status": "applied"}])
    expected = adapter.python_call("build_worker_hashrate_history", state, "rig", "all")
    actual = adapter.NATIVES["build_worker_hashrate_history"](state, "rig", "all")
    assert actual == expected
    assert actual["markers"][0]["x"] == 10**23


@pytest.mark.parametrize("rate", [float("inf"), float("-inf"), float("nan"), "1e999", " ٥٠٠٠ "])
def test_nonfinite_hashrate_reaches_formatter(rate):
    data = {"workers": [{"name": "rig", "h60": rate}]}
    expected = adapter.python_call("build_worker_detail", "rig", data, State())
    actual = adapter.NATIVES["build_worker_detail"]("rig", data, State())
    assert actual == expected


@pytest.mark.parametrize("rig", [float("inf"), float("-inf"), "inf"])
def test_infinite_config_values_keep_comparison_semantics(rig):
    left, right = {"DONATION": float("inf")}, {"DONATION": rig}
    expected = adapter.python_call("config_drift", left, right)
    assert adapter.NATIVES["config_drift"](left, right) == expected


def test_nonfinite_result_roundtrips_without_marker_leak():
    data = {"workers": [{"name": "rig", "rigforge": {"config": {"DONATION": float("inf")}}}]}
    expected = adapter.python_call("build_worker_detail", "rig", data, State())
    actual = adapter.NATIVES["build_worker_detail"]("rig", data, State())
    assert actual == expected
    assert actual["rig_config"] == {"DONATION": float("inf")}


@pytest.mark.parametrize("full", [False, True])
def test_nonfinite_chart_values_and_markers_keep_their_values(full):
    state = State(
        samples=[{"ts": 1_700_000_000, "h15": float("inf")}],
        history=[{"ts": 1_700_000_000, "status": "applied", "changes": {"value": float("inf")}}],
    )
    operation = "build_worker_detail" if full else "build_worker_hashrate_history"
    args = ("rig", {}, state) if full else (state, "rig", "all")
    expected = adapter.python_call(operation, *args)
    actual = adapter.NATIVES[operation](*args)
    assert actual == expected
