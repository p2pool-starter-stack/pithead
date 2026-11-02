from types import SimpleNamespace

import pytest

from mining_dashboard import go_worker_detail


def _detail_result():
    return {
        "name": "one",
        "snapshot_at": 1,
        "found": True,
        "editable": True,
        "control_enabled": True,
        "ip": "host",
        "status": "online",
        "hashrate": "1 kH/s",
        "rigforge": {},
        "rigforge_update": None,
        "writable_keys": ["cpu.threads"],
        "rig_config": {},
        "rig_config_meta": {},
        "config_origin": "local",
        "last_applied": None,
        "config_drift": [],
        "config_revision_drift": None,
        "history": [],
        "hashrate_by_config": [],
        "hashrate_history": {"hashrate": [], "markers": []},
    }


def test_prepare_captures_all_storage_inputs_and_detaches(monkeypatch):
    from mining_dashboard.web.views import worker_detail

    monkeypatch.setattr(
        worker_detail.config,
        "current_worker_endpoints",
        lambda: [{"name": "one", "ip": "host"}],
    )
    monkeypatch.setattr(worker_detail.config, "DASHBOARD_CONTROL_ENABLED", True)
    calls = []

    def record(label, *args, **kwargs):
        calls.append((label, args, kwargs))
        return {"source": label}

    state = SimpleNamespace(
        get_worker_config_history=lambda *a, **k: record("history", *a, **k),
        get_worker_hashrate_by_config=lambda *a, **k: record("by-config", *a, **k),
        get_worker_config_change=lambda *a, **k: record("change", *a, **k),
        get_last_applied_worker_config=lambda *a, **k: record("applied", *a, **k),
        get_worker_revision_drift=lambda *a, **k: record("drift", *a, **k),
        get_worker_history=lambda *a, **k: record("samples", *a, **k),
    )
    data = {
        "workers": [
            {
                "name": "one",
                "rigforge": {"config_meta": {"revision": "r", "last_change_id": "c"}},
            }
        ]
    }
    prepared = go_worker_detail.prepare("one", data, state, "day", (1, 2), now=10)
    assert prepared["descriptor"] == {"name": "one", "ip": "host"}
    assert prepared["matched"] == {"source": "change"}
    assert prepared["revision_drift"] == {"source": "drift"}
    assert prepared["range_arg"] == "day"
    assert prepared["window"] == (1, 2)
    assert prepared["control_enabled"] is True
    prepared["data"]["workers"].clear()
    assert data["workers"]
    assert [name for name, *_ in calls].count("history") == 2


def test_build_prepared_accepts_complete_result_and_forwards_time(monkeypatch):
    result = _detail_result()
    seen = {}

    def native(operation, args, **kwargs):
        seen.update(operation=operation, args=args, kwargs=kwargs)
        return result

    monkeypatch.setattr(go_worker_detail, "_run", native)
    prepared = {"now": 7, "opaque": object()}
    assert go_worker_detail.build_prepared(prepared) is result
    assert seen == {
        "operation": "build_worker_detail",
        "args": [prepared],
        "kwargs": {"now": 7},
    }


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("found", 1),
        ("writable_keys", [1]),
        ("config_drift", {}),
        ("hashrate_history", {"hashrate": []}),
    ],
)
def test_build_prepared_rejects_invalid_field_types(monkeypatch, field, value):
    result = _detail_result()
    result[field] = value
    monkeypatch.setattr(go_worker_detail, "_run", lambda *_a, **_k: result)
    with pytest.raises(RuntimeError, match="invalid native worker detail types"):
        go_worker_detail.build_prepared({"now": 1})


def test_build_captured_prepares_then_builds(monkeypatch):
    prepared = {"now": 1}
    result = {"done": True}
    monkeypatch.setattr(go_worker_detail, "prepare", lambda *a, **k: prepared)
    monkeypatch.setattr(
        go_worker_detail, "build_prepared", lambda value: result if value is prepared else None
    )
    assert go_worker_detail.build_captured("one", {}, object(), "all", None, now=1) is result


def test_worker_detail_policy_helpers_forward_exact_arguments(monkeypatch):
    calls = []
    monkeypatch.setattr(
        go_worker_detail,
        "_run",
        lambda operation, args, **kwargs: calls.append((operation, args, kwargs)) or operation,
    )
    assert go_worker_detail.config_drift({"a": 1}, {"b": 2}, True) == "config_drift"
    assert go_worker_detail._has_unsettled_apply([{"status": "pending"}]) == "_has_unsettled_apply"
    assert calls == [
        ("config_drift", [{"a": 1}, {"b": 2}, True], {}),
        ("_has_unsettled_apply", [[{"status": "pending"}]], {}),
    ]


def test_build_worker_detail_captures_then_builds(monkeypatch):
    captured = {"workers": []}
    marker = {"result": True}
    monkeypatch.setattr(go_worker_detail, "capture", lambda name, data: (captured, 5))
    seen = {}

    def build(name, data, state, range_arg, window, *, now):
        seen.update(name=name, data=data, state=state, range=range_arg, window=window, now=now)
        return marker

    monkeypatch.setattr(go_worker_detail, "build_captured", build)
    owner = object()
    assert go_worker_detail.build_worker_detail("one", {}, owner, "day", (1, 2)) is marker
    assert seen == {
        "name": "one",
        "data": captured,
        "state": owner,
        "range": "day",
        "window": (1, 2),
        "now": 5,
    }


def test_worker_detail_install_binds_all_aliases(monkeypatch):
    from mining_dashboard.client import rig_config_meta
    from mining_dashboard.web import server
    from mining_dashboard.web.views import worker_detail

    monkeypatch.setattr(go_worker_detail, "REFERENCE_FUNCTIONS", {})
    names = (
        "build_worker_detail",
        "build_worker_hashrate_history",
        "config_drift",
        "_has_unsettled_apply",
        "config_origin",
    )
    for name in names:
        monkeypatch.setattr(worker_detail, name, getattr(worker_detail, name))
    monkeypatch.setattr(rig_config_meta, "config_origin", rig_config_meta.config_origin)
    monkeypatch.setattr(server, "build_worker_detail", server.build_worker_detail)
    go_worker_detail.install()
    for name in names:
        assert getattr(worker_detail, name) is getattr(go_worker_detail, name)
    assert rig_config_meta.config_origin is go_worker_detail.config_origin
    assert server.build_worker_detail is go_worker_detail.build_worker_detail
