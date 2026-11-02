import os

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


def _outcome(function, *args):
    try:
        return "value", function(*args)
    except Exception as error:
        return "error", type(error), str(error)


def test_equal_limits_share_one_compiled_plan(monkeypatch):
    monkeypatch.setattr(worker_change_audit, "_WORKERS_MAX", 3)
    monkeypatch.setattr(data_audit, "_RIG_EDIT_CAP_PER_HOUR", 3)
    go_audit_cap._CACHE.clear()
    before = adapter.CALLS["audit-cap-policy"]
    assert worker_change_audit.admit_worker(
        Service({str(index): (0, 0) for index in range(3)}), "new", 1, 60
    ) == (False, True)
    assert data_audit.DataAuditMixin._rig_edit_within_cap(
        Service({"worker": (0, 0)}), "worker", 1
    ) == (True, False)
    assert adapter.CALLS["audit-cap-policy"] == before + 1


def test_independent_limits_compile_independent_plans(monkeypatch):
    monkeypatch.setattr(worker_change_audit, "_WORKERS_MAX", 2)
    monkeypatch.setattr(data_audit, "_RIG_EDIT_CAP_PER_HOUR", 3)
    go_audit_cap._CACHE.clear()
    before = adapter.CALLS["audit-cap-policy"]
    worker_change_audit.admit_worker(Service({"a": (0, 0), "b": (0, 0)}), "new", 1, 60)
    data_audit.DataAuditMixin._rig_edit_within_cap(Service({"worker": (0, 0)}), "worker", 1)
    assert adapter.CALLS["audit-cap-policy"] == before + 2
    assert set(go_audit_cap._CACHE) == {2, 3}


def test_existing_name_returns_before_episode_lookup():
    class Existing:
        _rig_edit_window = {"worker": (0, 0)}

        @property
        def _rig_edit_names_over(self):
            raise AssertionError("episode read")

    before = adapter.CALLS["audit-cap-policy"]
    assert worker_change_audit.admit_worker(Existing(), "worker", 1, 60) == (True, False)
    assert adapter.CALLS["audit-cap-policy"] == before


def test_existing_name_returns_before_missing_limit_lookup(monkeypatch):
    monkeypatch.delattr(worker_change_audit, "_WORKERS_MAX")
    service = Service({"worker": (0, 0)})
    assert worker_change_audit.admit_worker(service, "worker", 1, 60) == (True, False)


def test_expiry_deletion_precedes_later_arithmetic_error():
    service = Service({"expired": (0, 0), "broken": (object(), 0)})
    with pytest.raises(TypeError):
        worker_change_audit.admit_worker(service, "new", 100, 60)
    assert "expired" not in service._rig_edit_window
    assert "broken" in service._rig_edit_window


def test_count_write_precedes_native_error(monkeypatch):
    service = Service({"worker": (0, 0)})
    monkeypatch.setattr(
        go_audit_cap, "_plan", lambda _limit: (_ for _ in ()).throw(RuntimeError("native"))
    )
    with pytest.raises(RuntimeError, match="native"):
        data_audit.DataAuditMixin._rig_edit_within_cap(service, "worker", 1)
    assert service._rig_edit_window["worker"] == (0, 1)


def test_count_write_precedes_missing_cap_error(monkeypatch):
    service = Service({"worker": (0, 0)})
    monkeypatch.delattr(data_audit, "_RIG_EDIT_CAP_PER_HOUR")
    with pytest.raises(NameError):
        data_audit.DataAuditMixin._rig_edit_within_cap(service, "worker", 1)
    assert service._rig_edit_window["worker"] == (0, 1)


def test_names_refusal_returns_before_missing_count_limit(monkeypatch):
    monkeypatch.setattr(worker_change_audit, "_WORKERS_MAX", 1)
    monkeypatch.delattr(data_audit, "_RIG_EDIT_CAP_PER_HOUR")
    service = Service({"full": (0, 0)})
    assert data_audit.DataAuditMixin._rig_edit_within_cap(service, "new", 1) == (
        False,
        True,
    )
    assert "new" not in service._rig_edit_window


def test_custom_count_mutates_cap_between_reference_comparisons(monkeypatch):
    events = []

    class Count:
        def __add__(self, other):
            events.append(("add", other))
            return self

        def __lt__(self, other):
            events.append(("lt", other))
            data_audit._RIG_EDIT_CAP_PER_HOUR = 9
            return True

        def __eq__(self, other):
            events.append(("eq", other))
            return False

    monkeypatch.setattr(data_audit, "_RIG_EDIT_CAP_PER_HOUR", 3)
    service = Service({"worker": (0, Count())})
    assert data_audit.DataAuditMixin._rig_edit_within_cap(service, "worker", 1) == (
        True,
        False,
    )
    assert events == [("add", 1), ("lt", 3), ("eq", 9)]
    assert adapter.COMPATIBILITY["_count_compat:value"] >= 1


@pytest.mark.parametrize("limit", [-1, True, 4097, 2.5, "2"])
def test_noncanonical_name_limit_uses_reference_comparison(limit):
    before_calls = adapter.CALLS["audit-cap-policy"]
    before_compat = adapter.COMPATIBILITY["_names_compat:value"]
    expected = _outcome(go_audit_cap.COMPAT_FUNCTIONS["_names_full"], 1, limit)
    actual = _outcome(worker_change_audit._names_full, 1, limit)
    assert actual == expected
    assert adapter.CALLS["audit-cap-policy"] == before_calls
    assert adapter.COMPATIBILITY["_names_compat:value"] == before_compat + 1


@pytest.mark.parametrize("limit", [-1, True, 4097, 2.5, "2"])
def test_noncanonical_spend_limit_uses_reference_comparison(monkeypatch, limit):
    monkeypatch.setattr(data_audit, "_RIG_EDIT_CAP_PER_HOUR", limit)
    before_calls = adapter.CALLS["audit-cap-policy"]
    before_compat = adapter.COMPATIBILITY["_count_compat:value"]
    expected = _outcome(go_audit_cap.COMPAT_FUNCTIONS["_count_policy"], 1)
    actual = _outcome(data_audit._count_policy, 1)
    assert actual == expected
    assert adapter.CALLS["audit-cap-policy"] == before_calls
    assert adapter.COMPATIBILITY["_count_compat:value"] == before_compat + 1


def test_negative_count_uses_reference_comparison():
    before_calls = adapter.CALLS["audit-cap-policy"]
    before_compat = adapter.COMPATIBILITY["_count_compat:value"]
    assert data_audit._count_policy(-1) == go_audit_cap.COMPAT_FUNCTIONS["_count_policy"](-1)
    assert adapter.CALLS["audit-cap-policy"] == before_calls
    assert adapter.COMPATIBILITY["_count_compat:value"] == before_compat + 1


def test_replaced_admission_provider_runs_once(monkeypatch):
    calls = []

    def provider(_service, worker, now, window):
        calls.append((worker, now, window))
        return True, False

    monkeypatch.setattr(worker_change_audit, "admit_worker", provider)
    service = Service()
    assert data_audit.DataAuditMixin._rig_edit_within_cap(service, "worker", 7) == (
        True,
        False,
    )
    assert calls == [("worker", 7, data_audit._RIG_EDIT_WINDOW_SEC)]


@pytest.mark.parametrize(
    "reply",
    [
        {},
        {"limit": 3, "names_full": [False] * 4, "spend": [[True, False]] * 4},
        {"limit": 2, "names_full": [False] * 3, "spend": [[True, False]] * 4},
        {"limit": 2, "names_full": [False] * 4, "spend": [[True, False]] * 3},
        {"limit": 2, "names_full": [False] * 4, "spend": [[True, 0]] * 4},
    ],
)
def test_malformed_native_plan_is_fatal(monkeypatch, reply):
    go_audit_cap._CACHE.clear()
    monkeypatch.setattr(go_audit_cap.go_channel, "call", lambda *_args, **_kwargs: reply)
    with pytest.raises(RuntimeError, match="invalid audit cap policy"):
        worker_change_audit._names_full(1, 2)


def test_cached_plan_is_immutable():
    go_audit_cap._CACHE.clear()
    worker_change_audit._names_full(1, 2)
    names, spend = go_audit_cap._CACHE[2]
    assert type(names) is tuple
    assert type(spend) is tuple
    assert all(type(pair) is tuple for pair in spend)


def test_compiled_plan_cache_is_bounded_and_evicts():
    go_audit_cap._CACHE.clear()
    before = adapter.CALLS["audit-cap-policy"]
    for limit in range(17):
        worker_change_audit._names_full(0, limit)
    assert len(go_audit_cap._CACHE) == 16
    assert 0 not in go_audit_cap._CACHE
    worker_change_audit._names_full(0, 0)
    assert adapter.CALLS["audit-cap-policy"] == before + 18
