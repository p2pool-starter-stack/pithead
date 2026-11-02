from types import SimpleNamespace

import pytest

from mining_dashboard import go_polling, go_wizard_config


def test_diff_and_unexplained_validate_native_selection(monkeypatch):
    replies = iter([["a", "nested.b"], ["nested.b"]])
    monkeypatch.setattr(go_polling, "_audit_keys", lambda *_a, **_k: next(replies))
    assert go_polling._diff_config_keys({}, {}) == ["a", "nested.b"]
    assert go_polling._unexplained_config_keys(["a", "nested.b"], ["a"]) == ["nested.b"]
    monkeypatch.setattr(go_polling, "_audit_keys", lambda *_a, **_k: ["b", "a"])
    with pytest.raises(RuntimeError, match="invalid diff"):
        go_polling._diff_config_keys({}, {})
    monkeypatch.setattr(go_polling, "_audit_keys", lambda *_a, **_k: ["missing"])
    with pytest.raises(RuntimeError, match="invalid selection"):
        go_polling._unexplained_config_keys(["a"], [])


def test_audit_log_rows_and_recent_reader(monkeypatch):
    row = {field: field for field in go_polling._AUDIT_FIELDS}
    seen = []

    def call(operation, config):
        seen.append((operation, config))
        return [row], {}

    monkeypatch.setattr(go_wizard_config, "_call", call)
    monkeypatch.setattr(go_wizard_config, "_value", lambda result, identities: result)
    assert go_polling._audit_log_rows("recent", [{"raw": True}], limit=1) == [row]
    assert seen[0][0] == "audit-recent"

    from mining_dashboard.service import audit_service

    monkeypatch.setattr(
        audit_service,
        "_tail_json_lines",
        lambda path: [{"ts": 1, "id": None, "actor": "operator"}],
    )
    assert go_polling.recent_audit_changes(3) == [row]
    assert seen[1][1]["limit"] == 3
    monkeypatch.setattr(audit_service, "_tail_json_lines", lambda path: None)
    assert go_polling.recent_audit_changes() == []


def test_audit_log_rejects_bad_rows(monkeypatch):
    monkeypatch.setattr(go_wizard_config, "_call", lambda *_a, **_k: ([{"id": "x"}], {}))
    monkeypatch.setattr(go_wizard_config, "_value", lambda result, identities: result)
    with pytest.raises(RuntimeError, match="invalid rows"):
        go_polling._audit_log_rows("recent", [])


def test_control_audit_rows_validates_mirror(monkeypatch):
    from mining_dashboard.service import audit_service

    fields = {
        "id": "one",
        "ts": "now",
        "source": "control",
        "actor": "operator",
        "action": "commit",
        "status": "applied",
        "keys": "a",
    }
    monkeypatch.setattr(audit_service, "recent_changes", go_polling.recent_audit_changes)
    monkeypatch.setattr(go_wizard_config, "_call", lambda *_a, **_k: ([fields], {}))
    monkeypatch.setattr(go_wizard_config, "_value", lambda result, identities: result)
    assert go_polling.control_audit_rows([{"id": "one"}]) == [fields]


def test_polling_clock_and_telemetry(monkeypatch):
    from mining_dashboard.service import data_helpers

    monkeypatch.setattr(
        data_helpers,
        "datetime",
        SimpleNamespace(now=lambda zone: SimpleNamespace(timestamp=lambda: 9)),
    )
    assert go_polling._clock(None) == 9
    monkeypatch.setattr(go_polling, "_run", lambda operation, args: (operation, args))
    assert go_polling.telemetry_plan(object(), "begin", [1]) == ("telemetry_begin", [1])


def test_audit_keys_uses_wizard_identity_decoder(monkeypatch):
    marker = object()
    monkeypatch.setattr(go_wizard_config, "_call", lambda *_a, **_k: (marker, {"id": 1}))
    monkeypatch.setattr(
        go_wizard_config,
        "_value",
        lambda result, identities: ["a"] if result is marker and identities == {"id": 1} else None,
    )
    assert go_polling._audit_keys("diff", old={}, new={}) == ["a"]


def test_control_audit_rows_uses_replaced_reader(monkeypatch):
    from mining_dashboard.service import audit_service, data_audit

    marker = [{"opaque": True}]
    monkeypatch.setattr(audit_service, "recent_changes", lambda: [])
    monkeypatch.setattr(data_audit, "_control_audit_rows_with_entries", lambda entries: marker)
    assert go_polling.control_audit_rows([]) is marker


def test_native_rigforge_merge_and_window_aggregate(monkeypatch):
    from mining_dashboard import go_rigforge
    from mining_dashboard.service import data_helpers

    monkeypatch.setattr(data_helpers, "parse_rigforge", go_rigforge.parse_rigforge)
    monkeypatch.setattr(
        go_polling,
        "_run",
        lambda operation, args, **kwargs: (
            [{"rigforge": {"native": True}}] if operation == "merge_rigforge_stats" else {"h10": 1}
        ),
    )
    worker = {"name": "one"}
    assert go_polling._merge_direct_stats([worker], [{}], 1)[0]["rigforge"] == {"native": True}
    assert go_polling._aggregate_window_hashrates([worker]) == {"h10": 1}


@pytest.mark.asyncio
async def test_probe_rejects_invalid_completion(monkeypatch):
    replies = iter([[False], {}, [False], {"result_indices": [0], "answered": []}])
    monkeypatch.setattr(go_polling, "_run", lambda *_a, **_k: next(replies))
    owner = SimpleNamespace(_answered=set())
    client = SimpleNamespace(get_stats=None)
    with pytest.raises(RuntimeError, match="invalid result"):
        await go_polling.probe(owner, client, [{"name": "one", "ip": "host"}])
    with pytest.raises(RuntimeError, match="invalid alignment"):
        await go_polling.probe(owner, client, [{"name": "one", "ip": "host"}])


def test_polling_install_binds_service_entrypoints(monkeypatch):
    from mining_dashboard import go_editor
    from mining_dashboard.service import (
        audit_service,
        data_audit,
        data_helpers,
        data_service,
        worker_probe,
    )

    monkeypatch.setattr(go_polling, "REFERENCE_FUNCTIONS", {})
    for name in go_polling.HELPERS:
        monkeypatch.setattr(data_helpers, name, getattr(data_helpers, name))
        if hasattr(data_service, name):
            monkeypatch.setattr(data_service, name, getattr(data_service, name))
    bindings = (
        (data_helpers.WorkerLifecycle, "update"),
        (worker_probe.WorkerProber, "probe"),
        (data_service.DataService, "_telemetry_plan"),
        (data_helpers, "_diff_config_keys"),
        (data_audit, "_diff_config_keys"),
        (data_audit, "_unexplained_config_keys"),
        (audit_service, "recent_changes"),
        (data_audit, "_control_audit_rows"),
    )
    for module, name in bindings:
        monkeypatch.setattr(module, name, getattr(module, name))
    monkeypatch.setattr(go_editor, "PROVIDERS", {"audit_provider": audit_service.recent_changes})
    go_polling.install()
    assert data_helpers.WorkerLifecycle.update is go_polling.lifecycle_update
    assert worker_probe.WorkerProber.probe is go_polling.probe
    assert data_service.DataService._telemetry_plan is go_polling.telemetry_plan
    assert audit_service.recent_changes is go_polling.recent_audit_changes
    assert data_audit._control_audit_rows is go_polling.control_audit_rows
    assert go_editor.PROVIDERS["audit_provider"] is go_polling.recent_audit_changes
