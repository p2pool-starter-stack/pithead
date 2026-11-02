import os
from contextlib import contextmanager

import dashboard_audit_cap_plugin as adapter
import pytest

from mining_dashboard import go_audit_cap
from mining_dashboard.service import data_audit
from mining_dashboard.service.workers import worker_change_audit

# ruff: noqa: S101

pytest_plugins = ["dashboard_audit_cap_plugin"]
pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)


class Service:
    def __init__(self, windows=None, episode=None):
        self._rig_edit_window = dict(windows or {})
        self._rig_edit_names_over = episode


@contextmanager
def _reference_policy():
    names = worker_change_audit._names_full
    count = data_audit._count_policy
    worker_change_audit._names_full = go_audit_cap.COMPAT_FUNCTIONS["_names_full"]
    data_audit._count_policy = go_audit_cap.COMPAT_FUNCTIONS["_count_policy"]
    try:
        yield
    finally:
        worker_change_audit._names_full = names
        data_audit._count_policy = count


def _admit(function, windows, episode, worker, now, window):
    service = Service(windows, episode)
    result = function(service, worker, now, window)
    return result, service._rig_edit_window, service._rig_edit_names_over


@pytest.mark.parametrize(
    ("windows", "episode", "worker", "now", "window"),
    [
        ({"known": (10, 3)}, None, "known", 20, 60),
        ({}, 5, "new", 20, 60),
        ({str(index): (10, 0) for index in range(64)}, None, "new", 20, 60),
        ({str(index): (10, 0) for index in range(64)}, 7, "new", 20, 60),
        ({str(index): (0, 0) for index in range(64)}, 7, "new", 100, 60),
    ],
)
def test_admission_matches_reference(windows, episode, worker, now, window):
    with _reference_policy():
        expected = _admit(adapter.ORIGINALS["admit_worker"], windows, episode, worker, now, window)
    actual = _admit(worker_change_audit.admit_worker, windows, episode, worker, now, window)
    assert actual == expected


def _count(function, start, count, now):
    service = Service({"worker": (start, count)})
    result = function(service, "worker", now)
    return result, service._rig_edit_window, service._rig_edit_names_over


@pytest.mark.parametrize(
    ("start", "count", "now"),
    [(10, 0, 20), (10, 11, 20), (10, 12, 20), (10, 13, 20), (0, 12, 4000)],
)
def test_count_policy_matches_reference(start, count, now):
    with _reference_policy():
        expected = _count(adapter.ORIGINALS["_rig_edit_within_cap"], start, count, now)
    actual = _count(data_audit.DataAuditMixin._rig_edit_within_cap, start, count, now)
    assert actual == expected


@pytest.mark.parametrize("limit", [0, 1, 12, 64, 4096])
def test_native_tables_match_reference_helpers(limit):
    for value in (0, limit, limit + 1, limit + 100):
        with _reference_policy():
            expected_names = adapter.ORIGINALS["_names_full"](value, limit)
            original_cap = data_audit._RIG_EDIT_CAP_PER_HOUR
            data_audit._RIG_EDIT_CAP_PER_HOUR = limit
            try:
                expected_spend = adapter.ORIGINALS["_count_policy"](value)
            finally:
                data_audit._RIG_EDIT_CAP_PER_HOUR = original_cap
        assert worker_change_audit._names_full(value, limit) is expected_names
        original_cap = data_audit._RIG_EDIT_CAP_PER_HOUR
        data_audit._RIG_EDIT_CAP_PER_HOUR = limit
        try:
            assert data_audit._count_policy(value) == expected_spend
        finally:
            data_audit._RIG_EDIT_CAP_PER_HOUR = original_cap
