import copy
import json
import os

import dashboard_editor_plugin as adapter
import pytest

from mining_dashboard import go_editor
from mining_dashboard.service import audit_service, config_operations, control_service

# ruff: noqa: S101

pytest_plugins = ["dashboard_editor_plugin"]
pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)


def _outcome(function, *args, **kwargs):
    try:
        return "value", function(*args, **kwargs)
    except Exception as error:
        return "error", type(error), str(error)


def _custom_providers(events, opaque):
    def core():
        events.append("core")
        return ["monero.wallet_address"]

    def editable():
        events.append("editable")
        return ["p2pool.pool"]

    def confirm(cfg):
        assert cfg["p2pool"]["pool"] == "main"
        events.append("confirm")
        return ["monero.prune"]

    def getter(node, path):
        events.append(("get", path))
        for part in path:
            if not isinstance(node, dict) or part not in node:
                return False, None
            node = node[part]
        return True, node

    def audit():
        events.append("audit")
        return [
            {"action": "preview", "status": "applied", "id": "skip"},
            {"action": "commit-confirmed", "status": "failed", "id": opaque},
        ]

    return {
        "core_loader": core,
        "editable_provider": editable,
        "confirm_provider": confirm,
        "getter": getter,
        "audit_provider": audit,
    }


def test_interposed_provider_order_result_and_identity_match():
    opaque = object()
    cfg = {"p2pool": {"pool": "main"}, "monero": {"prune": True}}
    host = {"p2pool": {"pool": "main"}}
    reference = {
        "config_version": "2.0.0",
        "p2pool": {"pool": "mini"},
        "monero": {"prune": False, "wallet_address": ""},
        "telegram": {"enabled": False},
    }
    expected_events = []
    actual_events = []
    expected_cfg = copy.deepcopy(cfg)
    actual_cfg = copy.deepcopy(cfg)
    expected = adapter.python_call(
        "editor_metadata",
        expected_cfg,
        copy.deepcopy(host),
        copy.deepcopy(reference),
        **_custom_providers(expected_events, opaque),
    )
    actual = config_operations.editor_metadata(
        actual_cfg,
        copy.deepcopy(host),
        copy.deepcopy(reference),
        **_custom_providers(actual_events, opaque),
    )
    assert actual == expected
    assert actual is actual_cfg and expected is expected_cfg
    assert actual_events == expected_events
    assert actual["_last_apply"]["id"] is opaque


@pytest.mark.parametrize("failed", ["core", "editable", "confirm", "getter", "audit"])
def test_interposed_provider_failures_stop_at_the_same_boundary(failed):
    def providers(events):
        def mark(name, value):
            events.append(name)
            if name == failed:
                raise RuntimeError(f"provider {name} failed")
            return value

        def core():
            return mark("core", [])

        def editable():
            return mark("editable", ["p2pool.pool"])

        def confirm(_cfg):
            return mark("confirm", [])

        def getter(_host, _path):
            return mark("getter", (False, None))

        def audit():
            return mark("audit", [])

        return {
            "core_loader": core,
            "editable_provider": editable,
            "confirm_provider": confirm,
            "getter": getter,
            "audit_provider": audit,
        }

    expected_events = []
    actual_events = []
    expected_cfg = {"p2pool": {"pool": "main"}}
    actual_cfg = copy.deepcopy(expected_cfg)
    reference = {"p2pool": {"pool": "mini"}}
    expected = _outcome(
        adapter.python_call,
        "editor_metadata",
        expected_cfg,
        {},
        reference,
        **providers(expected_events),
    )
    actual = _outcome(
        config_operations.editor_metadata,
        actual_cfg,
        {},
        reference,
        **providers(actual_events),
    )
    assert actual == expected == ("error", RuntimeError, f"provider {failed} failed")
    assert actual_events == expected_events
    assert actual_cfg == expected_cfg


def test_normal_metadata_uses_one_native_call_and_keeps_values_off_wire(monkeypatch):
    calls = []
    native_call = go_editor.go_channel.call

    def captured(helper, payload):
        result = native_call(helper, payload)
        wire = json.dumps([payload, result], sort_keys=True)
        assert "raw-secret-canary" not in wire
        calls.append((helper, payload["operation"]))
        return result

    monkeypatch.setattr(go_editor.go_channel, "call", captured)
    cfg = {
        "monero": {"node_password": "raw-secret-canary", "prune": True},
        "p2pool": {"pool": "main"},
    }
    host = {
        "p2pool": {"pool": "main"},
        "monero": {"node_password": "raw-secret-canary"},
    }
    reference = {
        "monero": {"node_password": "raw-secret-canary", "prune": False},
        "p2pool": {"pool": "mini"},
    }
    result = config_operations.editor_metadata(
        cfg,
        host,
        reference,
        core_loader=control_service._load_core_keys,
        editable_provider=control_service._editable_paths,
        confirm_provider=control_service._confirm_paths,
        getter=control_service._get,
        audit_provider=audit_service.recent_changes,
    )
    assert result is cfg
    assert calls == [("wizard-config", "editor-metadata")]
    assert set(result).issuperset(
        {
            "_core_keys",
            "_editable_keys",
            "_confirm_keys",
            "_approval_keys",
            "_default_keys",
            "_last_apply",
            "_config_version_newer",
        }
    )


def test_interposed_version_parser_is_honored_without_native_call(monkeypatch):
    calls = []

    def parsed(value):
        calls.append(value)
        return {"current": (1, 0, 0), "2.0.0": (2, 0, 0)}.get(value)

    def unavailable(*_args, **_kwargs):
        raise AssertionError("interposed version parser used native helper")

    monkeypatch.setattr(config_operations, "parse_semver", parsed)
    monkeypatch.setattr(go_editor.go_channel, "call", unavailable)
    monkeypatch.setenv("PITHEAD_VERSION", "current")
    cfg = {}
    assert config_operations.config_version_metadata(cfg, {"config_version": "2.0.0"}) is cfg
    assert cfg == {"_config_version_newer": True}
    assert calls == ["current", "2.0.0"]


def test_audit_selection_uses_captured_fields_and_opaque_identifier(monkeypatch):
    opaque = object()
    entries = [{"action": "commit", "status": "applied", "id": opaque}]
    native_call = go_editor.go_channel.call

    def interleaved(helper, payload):
        result = native_call(helper, payload)
        entries[0].update(status="pending", id="later")
        return result

    monkeypatch.setattr(go_editor.go_channel, "call", interleaved)
    result = config_operations.last_apply_state(entries)
    assert result == {"status": "applied", "id": opaque}
    assert result["id"] is opaque
    assert entries[0] == {"action": "commit", "status": "pending", "id": "later"}


@pytest.mark.parametrize(
    "reply",
    [
        None,
        [],
        {},
        {"core_keys": []},
        *[
            {
                "confirm_keys": [],
                "approval_keys": [],
                "default_keys": [],
                "last_apply_index": None,
                "pop_version": False,
                "newer": False,
                key: value,
            }
            for key, value in (
                ("confirm_keys", "invalid"),
                ("approval_keys", [1]),
                ("default_keys", None),
                ("last_apply_index", True),
                ("last_apply_index", 99),
                ("pop_version", "yes"),
                ("newer", 1),
            )
        ],
    ],
)
def test_invalid_native_metadata_plan_fails_before_mutation(monkeypatch, reply):
    cfg = {"p2pool": {"pool": "main"}}
    before = copy.deepcopy(cfg)
    monkeypatch.setattr(
        go_editor.go_channel, "call", lambda *_args, **_kwargs: go_editor._tree(reply, {})
    )
    with pytest.raises(RuntimeError, match="invalid"):
        config_operations.editor_metadata(
            cfg,
            {},
            {"p2pool": {"pool": "mini"}},
            core_loader=control_service._load_core_keys,
            editable_provider=control_service._editable_paths,
            confirm_provider=control_service._confirm_paths,
            getter=control_service._get,
            audit_provider=audit_service.recent_changes,
        )
    assert cfg == before


def test_metadata_transport_failure_never_uses_reference_policy(monkeypatch):
    cfg = {"config_version": "reference"}

    def unavailable(*_args, **_kwargs):
        raise RuntimeError("native unavailable")

    monkeypatch.setattr(go_editor.go_channel, "call", unavailable)
    with pytest.raises(RuntimeError, match="native unavailable"):
        config_operations.editor_metadata(cfg, {}, {}, **go_editor.PROVIDERS)
    assert cfg == {"config_version": "reference"}
