import math

import pytest

from mining_dashboard import (
    go_wizard_config,
    go_wizard_preparation,
    go_wizard_values,
)


def test_tree_and_value_round_trip_json_shapes_and_float_identity():
    nan = float("nan")
    value = {
        "none": None,
        "bool": True,
        "int": 2**80,
        "float": 1.25,
        "nan": [nan, nan],
        "bad\ud800": "value\udfff",
    }
    identities = {}
    tree = go_wizard_config._tree(value, identities)
    floats = {number: item for number, item in identities.values()}
    restored = go_wizard_config._value(tree, floats)
    assert restored["none"] is None
    assert restored["bool"] is True
    assert restored["int"] == 2**80
    assert restored["float"] == 1.25
    assert restored["nan"][0] is nan
    assert restored["nan"][1] is nan
    assert restored["bad\ud800"] == "value\udfff"
    assert math.isnan(restored["nan"][0])


def test_tree_rejects_non_json_and_value_rejects_unknown():
    with pytest.raises(TypeError, match="JSON values"):
        go_wizard_config._tree(object(), {})
    with pytest.raises(RuntimeError, match="invalid value"):
        go_wizard_config._value(["other", None], {})


def test_config_call_projects_values_and_reject_flag(monkeypatch):
    captured = []

    def call(helper, payload):
        captured.append((helper, payload))
        return ["dict", [["value", ["float", "nan", 1]]]]

    nan = float("nan")
    monkeypatch.setattr(go_wizard_config.go_channel, "call", call)
    result, identities = go_wizard_config._call("merge", value=nan, reject=True)
    assert captured[0][0] == "wizard-config"
    assert captured[0][1]["reject"] is True
    assert captured[0][1]["value"][:2] == ["float", "nan"]
    assert go_wizard_config._value(result, identities)["value"] is nan


def test_merge_strip_and_name_forward_native_contract(monkeypatch):
    calls = []

    def call(operation, **values):
        calls.append((operation, values))
        if operation == "merge":
            return ["dict", [["a", ["int", "2"]]]], {}
        if operation == "strip":
            return ["dict", []], {}
        return ["null", None], {}

    monkeypatch.setattr(go_wizard_config, "_call", call)
    base = {"a": 1}
    assert go_wizard_config.deep_merge(base, {"a": 2}) == {"a": 2}
    assert base == {"a": 1}
    assert go_wizard_config.strip_defaults({"a": 1}, {}) == {}
    go_wizard_config.validate_machine_name({"dashboard": {"host": "auto"}}, [])
    assert [operation for operation, _ in calls] == ["merge", "strip", "name"]
    with pytest.raises(ValueError, match="dashboard must be an object"):
        go_wizard_config.validate_machine_name({"dashboard": []}, {})


def test_recovery_state_reads_inputs_in_order(monkeypatch):
    events = []

    def spool_json(name):
        events.append(("json", name))
        if name == "config-changes.json":
            return {"changes": [{"path": "a"}]}
        return {"disk": "disk-a", "wipe": "keep"}

    def spool_read(name):
        events.append(("read", name))
        return "token"

    monkeypatch.setattr(
        go_wizard_config,
        "_call",
        lambda operation, **values: (
            {
                "remembered": ["list", []],
                "attempt": ["dict", []],
                "mode": values["mode"],
            },
            {},
        ),
    )
    result = go_wizard_config.recovery_state(spool_json, spool_read, [{"name": "disk-a"}])
    assert result == ([], {}, "token")
    assert events == [
        ("json", "config-changes.json"),
        ("json", "install-attempt.json"),
        ("read", "auth-mode"),
    ]


def test_preparation_plan_decodes_values_and_validates_ack(monkeypatch):
    monkeypatch.setattr(
        go_wizard_preparation.go_channel,
        "call",
        lambda helper, payload: {
            "next": "prepare",
            "config": ["dict", [["value", ["int", "7"]]]],
            "changes": ["list", []],
        },
    )
    result = go_wizard_preparation._plan("object", config={"value": 7})
    assert result == {"next": "prepare", "config": {"value": 7}, "changes": []}

    monkeypatch.setattr(go_wizard_preparation.go_channel, "call", lambda *_: {"next": 7})
    with pytest.raises(RuntimeError, match="invalid native wizard preparation plan"):
        go_wizard_preparation._plan("object")


def test_preparation_phase_and_shape_validation():
    go_wizard_preparation._next({"next": "ready"}, "ready")
    with pytest.raises(RuntimeError, match="phase"):
        go_wizard_preparation._next({"next": "other"}, "ready")
    assert go_wizard_preparation._prepared(
        {"next": "ready", "config": {}, "changes": []}, "ready"
    ) == ({}, [])
    with pytest.raises(RuntimeError, match="prepared configuration"):
        go_wizard_preparation._prepared({"next": "ready", "config": [], "changes": {}}, "ready")


@pytest.mark.parametrize("raw", ['{"value":1}', ""])
def test_preparation_config_preserves_source_order(monkeypatch, raw):
    from mining_dashboard.wizard import server

    events = []

    def plan(phase, **values):
        events.append((phase, values))
        if phase == "source":
            return {"next": "parse" if raw else "build"}
        return {"next": "prepare"}

    monkeypatch.setattr(go_wizard_preparation, "_plan", plan)
    monkeypatch.setattr(server.documents, "loads", lambda text: {"value": 1})
    monkeypatch.setattr(
        server.documents, "reject_placeholders", lambda cfg: events.append(("reject", cfg))
    )
    monkeypatch.setattr(server, "_spool_read", lambda name: "test-platform")
    monkeypatch.setattr(server, "_spool_json", lambda name: {"budget": 1})
    monkeypatch.setattr(server, "_disks", lambda: [{"name": "disk"}])
    monkeypatch.setattr(server, "tari_disk_default", lambda *args: "remote")
    monkeypatch.setattr(server, "build_config", lambda *args, **kwargs: {"built": True})
    form = {"disk": "disk", "wipe": "keep"}

    result = go_wizard_preparation.config(form, raw)

    assert result == ({"value": 1} if raw else {"built": True})
    assert events[0] == ("source", {"raw": bool(raw)})
    assert events[-1][0] == "object"


def test_preparation_prepare_runs_defaults_and_validation(monkeypatch):
    from mining_dashboard.wizard import server

    phases = []

    def plan(phase, **values):
        phases.append((phase, values))
        if phase == "prepare":
            return {"next": "previous", "config": {"dashboard": {}}, "changes": ["a"]}
        if phase == "previous":
            return {"next": "defaults"}
        if phase == "defaults":
            return {"next": "validate", "config": {"dashboard": {}}, "changes": ["a"]}
        return {"next": "ready", "config": {"dashboard": {}}, "changes": ["a"]}

    attempts = []
    monkeypatch.setattr(go_wizard_preparation, "_plan", plan)
    monkeypatch.setattr(
        server, "_last_attempt", lambda: attempts.append("attempt") or {"dashboard": {}}
    )
    monkeypatch.setattr(server, "_spool_read", lambda name: "appliance")
    monkeypatch.setattr(server, "new_install_defaults", lambda platform: {"defaults": platform})

    assert go_wizard_preparation.prepare({}, None) == ({"dashboard": {}}, ["a"])
    assert [phase for phase, _ in phases] == [
        "prepare",
        "previous",
        "defaults",
        "validate",
    ]
    assert attempts == ["attempt", "attempt"]


def test_value_helpers_apply_paths_and_preserve_identity(monkeypatch):
    written = {}
    cfg = {"outer": {"value": 3}}
    go_wizard_values._apply_paths(written, cfg, [["outer", "value"]])
    assert written == cfg

    same = {"a": 1}
    monkeypatch.setattr(
        go_wizard_values,
        "_call",
        lambda *args, **kwargs: ({"same": True, "aliases": [], "paths": []}, {}),
    )
    assert go_wizard_values.explicit_wizard_config(same, {}) is same


def test_value_call_and_default_paths(monkeypatch):
    from mining_dashboard.wizard import defaults

    calls = []

    def call(helper, payload):
        calls.append((helper, payload))
        if payload["operation"] == "tari":
            return {"need_default": True}
        return ["dict", [["mode", ["str", "remote"]]]]

    monkeypatch.setattr(go_wizard_values.go_channel, "call", call)
    monkeypatch.setattr(defaults, "default_of", lambda path: "default-mode")
    monkeypatch.setattr(defaults, "new_install_defaults", lambda platform: {"platform": platform})
    monkeypatch.setattr(defaults, "tari_disk_default", lambda *args: "local")
    assert go_wizard_values.tari_disk_default({}, [], "") == "default-mode"
    assert go_wizard_values.new_machine_answers({}, [], "test") == {"mode": "remote"}
    assert [payload["operation"] for _, payload in calls] == ["tari", "answers"]


def test_remove_forwards_native_contract(monkeypatch):
    calls = []
    monkeypatch.setattr(
        go_wizard_values.go_channel,
        "call",
        lambda helper, payload: calls.append((helper, payload)),
    )
    go_wizard_values._remove("/spool", ["a"])
    assert calls == [
        ("wizard-values", {"operation": "remove-spool", "spool": "/spool", "names": ["a"]})
    ]


def test_disk_inventory_projects_rows_and_capacities(monkeypatch):
    captured = []

    def call(operation, *, plain=None, **values):
        captured.append((operation, plain, values))
        return ["list", [["str", "disk-a"]]], {}

    monkeypatch.setattr(go_wizard_values, "_call", call)
    assert go_wizard_values.disk_inventory("a\tb\tc\td\te\t12\tbad") == ["disk-a"]
    row = captured[0][1]["rows"][0]
    assert row["capacities"] == [
        {"digit": True, "integer": "12"},
        {"digit": False},
    ]


def test_remember_changes_writes_or_removes(monkeypatch):
    writes = []
    removes = []
    monkeypatch.setattr(go_wizard_values, "remove_spool", lambda *args: removes.append(args))
    monkeypatch.setattr(
        go_wizard_values,
        "_call",
        lambda *args, **kwargs: (["list", [["str", "new"]]], {}),
    )
    go_wizard_values.remember_changes(
        "/spool", ["new"], lambda _: {"changes": ["old"]}, lambda *args: writes.append(args)
    )
    assert writes and not removes

    monkeypatch.setattr(go_wizard_values, "_call", lambda *args, **kwargs: (["list", []], {}))
    go_wizard_values.remember_changes(
        "/spool", [], lambda _: {"changes": []}, lambda *args: writes.append(args)
    )
    assert removes == [("/spool", "config-changes.json")]


def test_remove_spool_calls_once_per_name(monkeypatch):
    calls = []
    monkeypatch.setattr(go_wizard_values, "_remove", lambda *args: calls.append(args))
    go_wizard_values.remove_spool("/spool", "a", "b")
    assert calls == [("/spool", ["a"]), ("/spool", ["b"])]
