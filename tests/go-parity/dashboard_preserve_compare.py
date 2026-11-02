import os
from datetime import UTC, datetime, timedelta

import dashboard_preserve_plugin as adapter
import pytest

from mining_dashboard.service.workers import worker_refresh

# ruff: noqa: S101

pytest_plugins = ["dashboard_preserve_plugin"]
pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)
NOW = datetime(2026, 9, 29, 22, 2, tzinfo=UTC)


class Opaque:
    pass


def _stamp(delta=0):
    return (NOW + timedelta(seconds=delta)).strftime("%Y-%m-%dT%H:%M:%SZ")


def _report(stamp, marker):
    return {"generated_at": stamp, "marker": marker, "opaque": Opaque()}


@pytest.fixture(autouse=True)
def frozen_time(monkeypatch):
    from mining_dashboard.client import rigforge_freshness

    monkeypatch.setattr(rigforge_freshness.time, "time", lambda: NOW.timestamp())


def _run(function, current, following):
    try:
        value = function(current, following)
        return "value", value
    except Exception as error:
        return "error", type(error), str(error)


def _paired(make_case):
    expected_current, expected_next = make_case()
    actual_current, actual_next = make_case()
    expected = _run(adapter.python_call, expected_current, expected_next)
    actual = _run(worker_refresh.preserve_newer_reports, actual_current, actual_next)
    assert actual == expected
    return expected_next, actual_next, expected


@pytest.mark.parametrize(
    ("old_delta", "new_delta", "preserved"),
    [
        (0, -1, True),
        (0, 0, True),
        (-1, 0, False),
        (120, 0, False),
        (0, 120, True),
    ],
)
def test_freshness_and_timestamp_order_match(old_delta, new_delta, preserved):
    def case():
        old = _report(_stamp(old_delta), "old")
        new = _report(_stamp(new_delta), "new")
        return (
            [{"name": "rig", "ip": "192.0.2.1", "rigforge": old}],
            [{"name": "rig", "ip": "192.0.2.1", "rigforge": new}],
        )

    _expected, actual, outcome = _paired(case)
    assert outcome == ("value", None)
    assert (actual[0]["rigforge"]["marker"] == "old") is preserved


@pytest.mark.parametrize(
    ("old_stamp", "new_stamp", "preserved"),
    [
        ("2026-9-7T5:0:0Z", "2026-09-07T05:00:00z", True),
        ("2026-09-07T05:00:00z", "2026-9-7T5:0:0Z", False),
        ("invalid", "2026-09-07T05:00:00Z", False),
        ("2026-09-07T05:00:00Z", "invalid", True),
    ],
)
def test_accepted_format_and_lexical_comparison_edges_match(
    monkeypatch, old_stamp, new_stamp, preserved
):
    from mining_dashboard.client import rigforge_freshness

    monkeypatch.setattr(rigforge_freshness.time, "time", lambda: 1_800_000_000)

    def case():
        old = _report(old_stamp, "old")
        new = _report(new_stamp, "new")
        return (
            [{"name": "rig", "ip": "192.0.2.1", "rigforge": old}],
            [{"name": "rig", "ip": "192.0.2.1", "rigforge": new}],
        )

    _expected, actual, _outcome = _paired(case)
    assert (actual[0]["rigforge"]["marker"] == "old") is preserved


def test_duplicate_current_key_uses_last_report_and_preserves_identity():
    stamp = _stamp()

    def case():
        first = _report(stamp, "first")
        last = _report(stamp, "last")
        new = _report(_stamp(-1), "new")
        return (
            [
                {"name": "rig", "ip": "192.0.2.1", "rigforge": first},
                {"name": "rig", "ip": "192.0.2.1", "rigforge": last},
            ],
            [{"name": "rig", "ip": "192.0.2.1", "rigforge": new}],
        )

    _expected, actual, _outcome = _paired(case)
    assert actual[0]["rigforge"]["marker"] == "last"
    assert isinstance(actual[0]["rigforge"]["opaque"], Opaque)


def test_none_name_and_ip_are_matching_keys():
    stamp = _stamp()

    def case():
        return (
            [{"name": None, "ip": None, "rigforge": _report(stamp, "old")}],
            [{"name": None, "ip": None, "rigforge": _report(_stamp(-1), "new")}],
        )

    _expected, actual, _outcome = _paired(case)
    assert actual[0]["rigforge"]["marker"] == "old"


def test_boolean_and_numeric_keys_follow_python_equality():
    stamp = _stamp()

    def case():
        return (
            [{"name": True, "ip": 2, "rigforge": _report(stamp, "old")}],
            [{"name": 1.0, "ip": 2.0, "rigforge": _report(_stamp(-1), "new")}],
        )

    _expected, actual, _outcome = _paired(case)
    assert actual[0]["rigforge"]["marker"] == "old"


@pytest.mark.parametrize("key", [[], {}])
def test_unhashable_worker_keys_match_reference_error(key):
    def case():
        return ([{"name": key, "ip": None}], [])

    _expected, _actual, outcome = _paired(case)
    assert outcome[0:2] == ("error", TypeError)


@pytest.mark.parametrize(
    ("name", "ip"),
    [("other", "192.0.2.1"), ("rig", "192.0.2.2"), (None, "192.0.2.1")],
)
def test_missing_or_changed_worker_does_not_replace(name, ip):
    stamp = _stamp()

    def case():
        old = _report(stamp, "old")
        new = _report(_stamp(-1), "new")
        return (
            [{"name": "rig", "ip": "192.0.2.1", "rigforge": old}],
            [{"name": name, "ip": ip, "rigforge": new}],
        )

    _expected, actual, _outcome = _paired(case)
    assert actual[0]["rigforge"]["marker"] == "new"


@pytest.mark.parametrize("old", [None, [], "report", 1])
def test_absent_and_non_object_old_reports_are_ignored(old):
    def case():
        return (
            [{"name": "rig", "ip": "192.0.2.1", "rigforge": old}],
            [{"name": "rig", "ip": "192.0.2.1", "rigforge": _report(_stamp(), "new")}],
        )

    _expected, actual, outcome = _paired(case)
    assert outcome == ("value", None)
    assert actual[0]["rigforge"]["marker"] == "new"


@pytest.mark.parametrize("new", [None, {}, [], "", 0, False])
def test_falsy_new_reports_are_replaced(new):
    def case():
        return (
            [{"name": "rig", "ip": "192.0.2.1", "rigforge": _report(_stamp(), "old")}],
            [{"name": "rig", "ip": "192.0.2.1", "rigforge": new}],
        )

    _expected, actual, outcome = _paired(case)
    assert outcome == ("value", None)
    assert actual[0]["rigforge"]["marker"] == "old"


def test_last_invalid_duplicate_current_report_overrides_valid_report():
    def case():
        return (
            [
                {"name": "rig", "ip": "192.0.2.1", "rigforge": _report(_stamp(), "old")},
                {"name": "rig", "ip": "192.0.2.1", "rigforge": None},
            ],
            [{"name": "rig", "ip": "192.0.2.1", "rigforge": _report(_stamp(-1), "new")}],
        )

    _expected, actual, outcome = _paired(case)
    assert outcome == ("value", None)
    assert actual[0]["rigforge"]["marker"] == "new"


@pytest.mark.parametrize("new", [["truthy"], "truthy", 1])
def test_truthy_non_object_new_report_matches_reference_error(new):
    def case():
        return (
            [{"name": "rig", "ip": "192.0.2.1", "rigforge": _report(_stamp(), "old")}],
            [{"name": "rig", "ip": "192.0.2.1", "rigforge": new}],
        )

    _expected, _actual, outcome = _paired(case)
    assert outcome[0:2] == ("error", AttributeError)


def test_replacements_before_later_error_match_and_keep_opaque_identity():
    stamp = _stamp()

    def case():
        old = _report(stamp, "old")
        return (
            [
                {"name": "first", "ip": "192.0.2.1", "rigforge": old},
                {"name": "second", "ip": "192.0.2.2", "rigforge": _report(stamp, "second")},
            ],
            [
                {"name": "first", "ip": "192.0.2.1", "rigforge": _report(_stamp(-1), "new")},
                {"name": "second", "ip": "192.0.2.2", "rigforge": ["invalid"]},
            ],
        )

    expected, actual, outcome = _paired(case)
    assert outcome[0:2] == ("error", AttributeError)
    assert expected[0]["rigforge"]["marker"] == actual[0]["rigforge"]["marker"] == "old"
    assert isinstance(actual[0]["rigforge"]["opaque"], Opaque)


def test_interposed_age_provider_keeps_call_order_and_decisions(monkeypatch):
    expected_calls = []
    actual_calls = []

    def case():
        return (
            [{"name": "rig", "ip": "192.0.2.1", "rigforge": _report("old", "old")}],
            [{"name": "rig", "ip": "192.0.2.1", "rigforge": _report("new", "new")}],
        )

    expected_current, expected_next = case()
    monkeypatch.setattr(
        worker_refresh,
        "feed_age",
        lambda stamp: expected_calls.append(stamp) or {"old": 0, "new": None}[stamp],
    )
    assert _run(adapter.python_call, expected_current, expected_next) == ("value", None)
    actual_current, actual_next = case()
    monkeypatch.setattr(
        worker_refresh,
        "feed_age",
        lambda stamp: actual_calls.append(stamp) or {"old": 0, "new": None}[stamp],
    )
    assert _run(worker_refresh.preserve_newer_reports, actual_current, actual_next) == (
        "value",
        None,
    )
    assert expected_calls == actual_calls == ["old", "new"]
    assert actual_next[0]["rigforge"]["marker"] == "old"


def test_native_helper_failure_never_falls_back(monkeypatch):
    from mining_dashboard import go_preserve

    monkeypatch.setattr(
        go_preserve.go_channel,
        "call",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(RuntimeError("native unavailable")),
    )
    with pytest.raises(RuntimeError, match="native unavailable"):
        worker_refresh.preserve_newer_reports([], [])
