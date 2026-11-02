import copy
import math
import os

import dashboard_host_audit_plugin as adapter
import pytest

from mining_dashboard.service import data_audit, data_helpers

# ruff: noqa: S101

pytest_plugins = ["dashboard_host_audit_plugin"]
pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)


def _outcome(function, *args):
    try:
        return "value", function(*args)
    except Exception as error:
        return "error", type(error), str(error)


def _paired(name, function, *args):
    expected_args = copy.deepcopy(args)
    actual_args = copy.deepcopy(args)
    expected = _outcome(adapter.python_call, name, *expected_args)
    actual = _outcome(function, *actual_args)
    assert actual == expected
    assert actual_args == expected_args
    return actual


@pytest.mark.parametrize(
    ("old", "new"),
    [
        ({"a": 1}, {"a": 2}),
        ({"a": 1}, {"b": 2}),
        ({"a": {"b": {"c": True}}}, {"a": {"b": {"c": False}}}),
        ({"a.b": 1}, {"a": {"b": 1}}),
        ({"a.b": 1, "a": {"b": 2}}, {"a": {"b": 2}, "a.b": 1}),
        ({"config_version": 1, "x": 1}, {"config_version": 2, "x": 2}),
        ({"secret": {"__secret__": True}}, {"secret": {"__secret__": 1}}),
        ({"secret": {"__secret__": 1.0}}, {"secret": {"__secret__": False}}),
        ({"values": [None, True, 1, 1.5, "x"]}, {"values": [None, True, 1, 1.5, "y"]}),
        ({"number": True}, {"number": 1.0}),
        ({"number": 2**80}, {"number": float(2**80)}),
        ({"\ud800": "\udfff"}, {"\ud800": "changed"}),
        ("not-an-object", {"a": 1}),
        (None, None),
    ],
)
def test_tree_diff_matches_reference_for_typed_and_collision_cases(old, new):
    _paired("_diff_config_keys", data_helpers._diff_config_keys, old, new)


def test_same_nan_object_inside_lists_matches_reference_identity_semantics():
    nan = float("nan")
    outcome = _paired(
        "_diff_config_keys",
        data_helpers._diff_config_keys,
        {"values": [nan]},
        {"values": [nan]},
    )
    assert outcome == ("value", [])


def test_distinct_nan_values_and_direct_nan_leaves_match_reference():
    first = _paired(
        "_diff_config_keys",
        data_helpers._diff_config_keys,
        {"values": [float("nan")]},
        {"values": [float("nan")]},
    )
    direct = _paired(
        "_diff_config_keys",
        data_helpers._diff_config_keys,
        {"value": math.nan},
        {"value": math.nan},
    )
    assert first == ("value", ["values"])
    assert direct == ("value", ["value"])


@pytest.mark.parametrize(
    ("changed", "explained", "wanted"),
    [
        (["a", "a.b", "x", "a"], ["a"], ["x"]),
        (["a", "a.b", "a.b.c", "a.bc"], ["a.b"], ["a", "a.bc"]),
        (["z", "a", "z.b", "b"], ["z", "a"], ["b"]),
        (["a", "ab", "a.b", "a..b"], ["a"], ["ab"]),
        ([], ["a"], []),
        (["a", "a"], [], ["a", "a"]),
    ],
)
def test_unexplained_prefix_filter_preserves_changed_order(changed, explained, wanted):
    outcome = _paired(
        "_unexplained_config_keys",
        data_audit._unexplained_config_keys,
        changed,
        explained,
    )
    assert outcome == ("value", wanted)


def test_explained_iterable_is_materialized_once():
    class Once:
        def __init__(self):
            self.calls = 0

        def __iter__(self):
            self.calls += 1
            if self.calls != 1:
                raise AssertionError("explained iterable read twice")
            return iter(["a"])

    explained = Once()
    assert data_audit._unexplained_config_keys(["a", "a.b", "b"], explained) == ["b"]
    assert explained.calls == 1
