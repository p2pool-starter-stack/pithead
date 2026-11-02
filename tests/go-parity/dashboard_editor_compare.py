import copy
import os

import dashboard_editor_plugin as adapter
import pytest

from mining_dashboard.service import config_operations

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


def _paired(operation, *args, **kwargs):
    expected_args = copy.deepcopy(args)
    actual_args = copy.deepcopy(args)
    expected_kwargs = copy.deepcopy(kwargs)
    actual_kwargs = copy.deepcopy(kwargs)
    expected = _outcome(adapter.python_call, operation, *expected_args, **expected_kwargs)
    actual = _outcome(getattr(config_operations, operation), *actual_args, **actual_kwargs)
    assert actual == expected
    return actual, expected_args, actual_args


@pytest.mark.parametrize("include_arrays", [False, True])
def test_leaf_paths_nested_private_arrays_and_secret_sentinels_match(include_arrays):
    cfg = {
        "config_version": "2.0.0",
        "_metadata": {"ignored": 1},
        "plain": 1,
        "nested": {
            "_private": 2,
            "leaf": False,
            "secret": {"__secret__": True, "slot": 3},
            "not_secret": {"__secret__": 1, "value": "kept"},
            "array": [1, {"opaque": 2}],
        },
    }
    expected = list(
        adapter.python_call("leaf_paths", copy.deepcopy(cfg), ("root",), include_arrays)
    )
    actual = list(config_operations.leaf_paths(copy.deepcopy(cfg), ("root",), include_arrays))
    assert actual == expected


def test_classification_order_overlap_and_retired_ssh_match():
    reference = {
        "telegram": {"enabled": True, "events": {"wallet_changed": True}},
        "dashboard": {"host": "auto", "energy": {"price_feed": "fixed"}},
        "monero": {"wallet_address": "", "prune": True},
        "ssh": {"enabled": False},
    }
    free = ["monero.prune", "dashboard.host"]
    confirm = ["telegram.events.wallet_changed"]
    approval, _expected, _actual = _paired("approval_paths", reference, {}, free, confirm)
    assert approval == ("value", ["dashboard.energy.price_feed", "telegram.enabled"])
    confirmed, _expected, _actual = _paired(
        "confirmed_paths", reference, free, confirm, approval[1]
    )
    assert confirmed == ("value", ["monero.wallet_address"])


def test_sparse_defaults_use_getter_order_and_array_leaves(monkeypatch):
    reference = {"first": {"value": 1}, "workers": {"list": []}, "last": False}
    host = {"workers": {"list": []}}
    expected_calls = []
    actual_calls = []

    def getter(calls):
        def get(node, path):
            calls.append(path)
            for part in path:
                if not isinstance(node, dict) or part not in node:
                    return False, None
                node = node[part]
            return True, node

        return get

    expected = adapter.python_call(
        "missing_default_paths",
        copy.deepcopy(reference),
        copy.deepcopy(host),
        getter(expected_calls),
    )
    actual = config_operations.missing_default_paths(
        copy.deepcopy(reference), copy.deepcopy(host), getter(actual_calls)
    )
    assert actual == expected == ["first.value", "last"]
    assert actual_calls == expected_calls == [("first", "value"), ("workers", "list"), ("last",)]


@pytest.mark.parametrize(
    "entries",
    [
        [],
        [{"action": "preview", "status": "applied", "id": "skip"}],
        [
            {"action": "commit", "status": "pending", "id": "skip"},
            {"action": "commit-confirmed", "status": "failed"},
            {"action": "commit-approved", "status": "applied", "id": "older"},
        ],
        [{"action": "commit-approved", "status": "applied", "id": False}],
    ],
)
def test_last_apply_terminal_selection_matches(entries):
    _paired("last_apply_state", entries)


@pytest.mark.parametrize(
    ("stamp", "current", "newer"),
    [
        ("2.1.0", "2.0.0-pre.1+build", True),
        ("2.0.0", "2.0.0", False),
        (None, "2.0.0", False),
        ("2.０.0", "1.0.0", False),
        ("9" * 5000 + ".0.0", "2.0.0", False),
        ({"x": 1}, "2.0.0", False),
        ("2.0.0", "².a.1", False),
        ("2.0.0", "².1.a", False),
    ],
)
def test_version_metadata_ascii_stamp_and_lenient_current_match(monkeypatch, stamp, current, newer):
    monkeypatch.setenv("PITHEAD_VERSION", current)
    cfg = {"config_version": "reference", "nested": {"config_version": "kept"}}
    host = {} if stamp is None else {"config_version": stamp}
    outcome, _expected, actual = _paired("config_version_metadata", cfg, host)
    assert outcome[0] == "value"
    assert outcome[1] is actual[0]
    assert outcome[1]["_config_version_newer"] is newer
    assert outcome[1]["nested"]["config_version"] == "kept"


@pytest.mark.parametrize("current", ["².1.0", "9" * 5000 + ".0.0"])
def test_version_metadata_integer_conversion_failures_match(monkeypatch, current):
    monkeypatch.setenv("PITHEAD_VERSION", current)
    cfg = {"config_version": "reference"}
    expected_cfg = copy.deepcopy(cfg)
    actual_cfg = copy.deepcopy(cfg)
    expected = _outcome(adapter.python_call, "config_version_metadata", expected_cfg, {})
    actual = _outcome(config_operations.config_version_metadata, actual_cfg, {})
    assert actual == expected
    assert actual[0:2] == ("error", ValueError)
    assert actual_cfg == expected_cfg == {}


def test_last_apply_preserves_opaque_identifier_identity():
    opaque = object()
    entries = [{"action": "commit", "status": "applied", "id": opaque}]
    result = config_operations.last_apply_state(entries)
    assert result == {"status": "applied", "id": opaque}
    assert result["id"] is opaque


@pytest.mark.parametrize("entry", [None, "bad", 1, 1.5, True, []])
def test_last_apply_malformed_entry_exception_type_matches(entry):
    expected = _outcome(adapter.python_call, "last_apply_state", [entry])
    actual = _outcome(config_operations.last_apply_state, [entry])
    assert actual == expected
    assert actual[0:2] == ("error", AttributeError)
