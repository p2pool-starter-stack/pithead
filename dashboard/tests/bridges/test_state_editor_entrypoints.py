import pytest

from mining_dashboard import go_editor
from mining_dashboard.service import config_operations


def test_editor_metadata_runs_providers_once_and_applies_plan(monkeypatch):
    calls = []

    def core():
        calls.append("core")
        return ["core.key"]

    def editable():
        calls.append("editable")
        return ["free.key"]

    def confirm(cfg):
        calls.append(("confirm", tuple(cfg["_core_keys"])))
        return ["confirm.key"]

    def getter(*args):
        return args

    entry = {"action": "commit", "status": "applied", "id": "change"}

    def audit():
        calls.append("audit")
        return [entry]

    providers = {
        "core_loader": core,
        "editable_provider": editable,
        "confirm_provider": confirm,
        "getter": getter,
        "audit_provider": audit,
    }
    monkeypatch.setattr(go_editor, "PROVIDERS", providers)
    monkeypatch.setattr(go_editor, "VERSION_PROVIDER", config_operations.parse_semver)
    for name in go_editor.FUNCTIONS[:-1]:
        monkeypatch.setattr(config_operations, name, getattr(go_editor, name))
    seen = {}

    def native(operation, **arguments):
        seen.update(operation=operation, arguments=arguments)
        return {
            "confirm_keys": ["confirm.key"],
            "approval_keys": ["approval.key"],
            "default_keys": ["default.key"],
            "last_apply_index": 0,
            "pop_version": True,
            "newer": False,
        }

    monkeypatch.setattr(go_editor, "_call", native)
    cfg = {"config_version": "old", "value": True}
    result = go_editor.editor_metadata(
        cfg, {"config_version": "1.2.3"}, {"value": False}, **providers
    )
    assert result is cfg
    assert cfg["_core_keys"] == ["core.key"]
    assert cfg["_editable_keys"] == ["free.key"]
    assert cfg["_confirm_keys"] == ["confirm.key"]
    assert cfg["_last_apply"] == {"status": "applied", "id": "change"}
    assert cfg["_config_version_newer"] is False
    assert "config_version" not in cfg
    assert calls == [
        "core",
        "editable",
        ("confirm", ("core.key",)),
        "editable",
        "editable",
        "audit",
    ]
    assert seen["operation"] == "metadata"
    assert seen["arguments"]["entries"] == [{"action": "commit", "status": "applied"}]


def test_editor_metadata_rejects_invalid_native_plan(monkeypatch):
    def provider(*args):
        return []

    providers = {
        "core_loader": provider,
        "editable_provider": provider,
        "confirm_provider": provider,
        "getter": provider,
        "audit_provider": provider,
    }
    monkeypatch.setattr(go_editor, "PROVIDERS", providers)
    monkeypatch.setattr(go_editor, "VERSION_PROVIDER", config_operations.parse_semver)
    for name in go_editor.FUNCTIONS[:-1]:
        monkeypatch.setattr(config_operations, name, getattr(go_editor, name))
    monkeypatch.setattr(go_editor, "_call", lambda *_a, **_k: {})
    with pytest.raises(RuntimeError, match="invalid plan"):
        go_editor.editor_metadata({}, {}, {}, **providers)


def test_editor_path_and_version_helpers_validate_replies(monkeypatch):
    monkeypatch.setattr(go_editor, "_call", lambda *_a, **_k: ["one", "two"])
    assert list(go_editor.leaf_paths({"one": True})) == ["one", "two"]
    monkeypatch.setattr(go_editor, "_call", lambda *_a, **_k: [1])
    with pytest.raises(RuntimeError, match="invalid paths"):
        list(go_editor.leaf_paths({}))
    cfg = {"config_version": "old"}
    monkeypatch.setattr(go_editor, "_call", lambda *_a, **_k: {"pop_version": False, "newer": True})
    monkeypatch.setattr(go_editor, "VERSION_PROVIDER", config_operations.parse_semver)
    assert go_editor.config_version_metadata(cfg, {"config_version": "1.2.3"}) is cfg
    assert cfg["_config_version_newer"] is True


def test_editor_path_groups_and_last_apply(monkeypatch):
    replies = iter([["approval"], ["confirmed"], 0])
    monkeypatch.setattr(go_editor, "_call", lambda *_a, **_k: next(replies))
    assert go_editor.approval_paths({"a": True}, {}, ["a"], ["b"]) == ["approval"]
    assert go_editor.confirmed_paths({"a": True}, ["a"], ["b"], ["c"]) == ["confirmed"]
    assert go_editor.last_apply_state(
        [{"action": "commit-approved", "status": "failed", "id": "one", "opaque": object()}]
    ) == {"status": "failed", "id": "one"}
    assert go_editor._last_apply(None, []) is None
    with pytest.raises(RuntimeError, match="invalid audit state"):
        go_editor._last_apply(0, [{"action": "other", "status": "failed"}])


def test_editor_call_decodes_wizard_result_and_wraps_decoder_errors(monkeypatch):
    marker = object()
    monkeypatch.setattr(go_editor.go_channel, "call", lambda helper, payload: marker)
    monkeypatch.setattr(
        go_editor, "_value", lambda value, identities: ["ok"] if value is marker else []
    )
    monkeypatch.setattr(go_editor, "_tree", lambda arguments, identities: {"wrapped": arguments})
    assert go_editor._call("leaves", reference={}) == ["ok"]
    monkeypatch.setattr(go_editor, "_value", lambda *_a: (_ for _ in ()).throw(KeyError("bad")))
    with pytest.raises(RuntimeError, match="invalid data"):
        go_editor._call("leaves")


def test_missing_defaults_uses_native_for_captured_getter(monkeypatch):
    getter = object()
    monkeypatch.setattr(go_editor, "PROVIDERS", {"getter": getter})
    monkeypatch.setattr(go_editor, "_call", lambda *_a, **_k: ["missing"])
    assert go_editor.missing_default_paths({"a": True}, {"a": False}, getter) == ["missing"]


def test_editor_install_binds_config_operations(monkeypatch):
    from mining_dashboard.service import audit_service, control_service

    monkeypatch.setattr(go_editor, "PROVIDERS", {})
    monkeypatch.setattr(go_editor, "REFERENCE_FUNCTIONS", {})
    monkeypatch.setattr(go_editor, "VERSION_PROVIDER", None)
    for name in go_editor.FUNCTIONS:
        monkeypatch.setattr(config_operations, name, getattr(config_operations, name))
    go_editor.install()
    for name in go_editor.FUNCTIONS:
        assert getattr(config_operations, name) is getattr(go_editor, name)
    assert go_editor.PROVIDERS == {
        "core_loader": control_service._load_core_keys,
        "editable_provider": control_service._editable_paths,
        "confirm_provider": control_service._confirm_paths,
        "getter": control_service._get,
        "audit_provider": audit_service.recent_changes,
    }
    assert go_editor.VERSION_PROVIDER is config_operations.parse_semver


def test_editor_replaced_providers_delegate_reference_helpers(monkeypatch):
    marker = object()
    getter = object()
    monkeypatch.setattr(
        config_operations,
        "_defaults_with_getter",
        lambda reference, host, value: marker if value is getter else None,
    )
    monkeypatch.setattr(go_editor, "PROVIDERS", {"getter": object()})
    assert go_editor.missing_default_paths({}, {}, getter) is marker
    monkeypatch.setattr(config_operations, "_version_with_provider", lambda cfg, host: marker)
    monkeypatch.setattr(go_editor, "VERSION_PROVIDER", object())
    assert go_editor.config_version_metadata({}, {}) is marker


def test_editor_version_rejects_flags_and_removes_missing_stamp(monkeypatch):
    monkeypatch.setattr(go_editor, "VERSION_PROVIDER", config_operations.parse_semver)
    monkeypatch.setattr(go_editor, "_call", lambda *_a, **_k: {"pop_version": False, "newer": 1})
    with pytest.raises(RuntimeError, match="invalid version flags"):
        go_editor.config_version_metadata({}, {})
    cfg = {"config_version": "old"}
    monkeypatch.setattr(go_editor, "_call", lambda *_a, **_k: (_ for _ in ()).throw(ValueError))
    with pytest.raises(ValueError):
        go_editor.config_version_metadata(cfg, {})
    assert "config_version" not in cfg
