import copy
import json
import math
import os

import dashboard_access_log_plugin as adapter
import pytest

from mining_dashboard.service import audit_service

# ruff: noqa: S101

pytest_plugins = ["dashboard_access_log_plugin"]
pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)


def _outcome(function, *args, **kwargs):
    try:
        return "value", function(*args, **kwargs)
    except Exception as error:
        return "error", type(error), str(error)


def _summary(monkeypatch, rows, limit=50, now=None):
    try:
        snapshot = json.dumps(rows)
    except (TypeError, ValueError, OverflowError):
        snapshot = None
    expected_rows = copy.deepcopy(rows)
    actual_rows = copy.deepcopy(rows)
    with adapter.python_operations():
        monkeypatch.setattr(audit_service, "access_rows", lambda _path: expected_rows)
        expected = _outcome(audit_service.access_summary, limit, now)
    monkeypatch.setattr(audit_service, "access_rows", lambda _path: actual_rows)
    actual = _outcome(audit_service.access_summary, limit, now)
    assert actual == expected
    if snapshot is not None:
        assert json.dumps(expected_rows) == snapshot, "reference access summary mutated its input"
        assert json.dumps(actual_rows) == snapshot, "native access summary mutated its input"
        assert json.dumps(rows) == snapshot
    return actual


def _row(ts=100.0, status=200, method="GET", uri="/", user="admin", probe=None):
    return {
        "ts": ts,
        "status": status,
        "request": {"method": method, "uri": uri},
        "user_id": user,
        "pithead_probe": probe,
    }


class Hostile:
    def __str__(self):
        return "<hostile>"


def test_comparison_guard_rejects_input_mutation(monkeypatch):
    native = audit_service.access_summary

    def mutated(*args, **kwargs):
        result = native(*args, **kwargs)
        audit_service.access_rows("ignored")[0]["mutation"] = True
        return result

    monkeypatch.setitem(adapter.NATIVES, "access_summary", mutated)
    monkeypatch.setattr(audit_service, "access_summary", mutated)
    with pytest.raises(AssertionError, match="native access summary mutated its input"):
        _summary(monkeypatch, [_row()], now=200.0)


def test_unavailable_summary_matches(monkeypatch):
    outcome = _summary(monkeypatch, None)
    assert outcome[1]["available"] is False


def test_normal_rows_sort_limit_sanitize_and_count_match(monkeypatch):
    rows = [
        _row(100.0, 401, uri="/<script>", user='admin"'),
        _row(102.0, 401, method="EVIL", uri="/second"),
        _row(101.0, 200, method="POST", uri="/middle"),
        _row(103.0, 401, probe="boot-health-v1"),
    ]
    outcome = _summary(monkeypatch, rows, limit=3, now=200.0)
    assert outcome[0] == "value"
    summary = outcome[1]
    assert [entry["ts"] for entry in summary["entries"]] == [103.0, 102.0, 101.0]
    assert summary["failures_24h"] == 2
    assert summary["last_failure_ts"] == 102.0
    assert summary["rotate_hint"] is False


@pytest.mark.parametrize("limit", [0, 1, 2, 50, -1, -2, True, False, 10**400])
def test_limit_shapes_match(monkeypatch, limit):
    _summary(monkeypatch, [_row(1.0), _row(2.0), _row(3.0)], limit=limit, now=10.0)


@pytest.mark.parametrize(
    ("now", "ts", "status"),
    [
        (200.0, 200.0 - 86400, 401),
        (200.0, 201.0, 401),
        (math.nan, 100.0, 401),
        (math.inf, 100.0, 401),
        (False, True, True),
        (10**300, 10**300, 401),
    ],
)
def test_numeric_window_and_coercion_match(monkeypatch, now, ts, status):
    _summary(monkeypatch, [_row(ts, status)], now=now)


def test_stable_ties_and_exact_probe_exemption_match(monkeypatch):
    rows = [
        _row(100.0, 401, uri="/first"),
        _row(100.0, 401, uri="/second", probe="boot-health-v1"),
        _row(100.0, 401, uri="/third", probe="boot-health-v1-extra"),
    ]
    outcome = _summary(monkeypatch, rows, now=100.0)
    assert [row["uri"] for row in outcome[1]["entries"]] == ["/first", "/second", "/third"]
    assert outcome[1]["failures_24h"] == 2


@pytest.mark.parametrize(
    "rows",
    [
        [Hostile()],
        [_row(ts=10**400)],
        [_row(status=10**400)],
        [_row(uri=Hostile())],
        [_row(user=Hostile())],
        [_row(probe=Hostile())],
    ],
)
def test_explicit_compatibility_shapes_match(monkeypatch, rows):
    before = sum(adapter.COMPATIBILITY.values())
    _summary(monkeypatch, rows, now=200.0)
    assert sum(adapter.COMPATIBILITY.values()) > before


def test_iterator_compatibility_matches_and_preserves_late_error(monkeypatch):
    def rows():
        yield _row()
        raise RuntimeError("late row failure")

    with adapter.python_operations():
        monkeypatch.setattr(audit_service, "access_rows", lambda _path: rows())
        expected = _outcome(audit_service.access_summary, 50, 200.0)
    monkeypatch.setattr(audit_service, "access_rows", lambda _path: rows())
    before = sum(adapter.COMPATIBILITY.values())
    actual = _outcome(audit_service.access_summary, 50, 200.0)
    assert actual == expected
    assert sum(adapter.COMPATIBILITY.values()) > before


def test_explicit_compatibility_helper_matches_reference(monkeypatch):
    rows = [_row(uri={"hostile": "<value>"})]
    monkeypatch.setattr(audit_service, "access_rows", lambda _path: rows)
    with adapter.python_operations():
        expected = audit_service.access_summary(now=200.0)
    from mining_dashboard import go_access_log

    assert go_access_log._access_compat("row-shape", rows, 50, 200.0) == expected
