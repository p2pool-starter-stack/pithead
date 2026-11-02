import copy
import math
import os
from collections import UserDict
from types import SimpleNamespace

import dashboard_audit_query_plugin as adapter
import pytest

from mining_dashboard import go_audit_query
from mining_dashboard.service import audit_service
from mining_dashboard.web import server

# ruff: noqa: S101

pytest_plugins = ["dashboard_audit_query_plugin"]
pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)


def _outcome(function, *args, **kwargs):
    try:
        return "value", function(*args, **kwargs)
    except Exception as error:
        return "error", type(error), str(error)


def _filter(entries, frm=None, to=None, q=None):
    expected_entries = copy.deepcopy(entries)
    actual_entries = copy.deepcopy(entries)
    expected = _outcome(adapter.python_call, "filter_log_entries", expected_entries, frm, to, q)
    actual = _outcome(audit_service.filter_log_entries, actual_entries, frm, to, q)
    assert actual == expected
    assert actual_entries == expected_entries == entries
    return actual


def _manager(rows):
    return SimpleNamespace(get_audit_events=lambda: rows)


def _merge(monkeypatch, database, live):
    expected_database = copy.deepcopy(database)
    actual_database = copy.deepcopy(database)
    expected_live = copy.deepcopy(live)
    actual_live = copy.deepcopy(live)
    with adapter.python_operations():
        monkeypatch.setattr(audit_service, "recent_changes", lambda: expected_live)
        expected = _outcome(server._merged_audit_entries, _manager(expected_database))
    monkeypatch.setattr(audit_service, "recent_changes", lambda: actual_live)
    actual = _outcome(server._merged_audit_entries, _manager(actual_database))
    assert actual == expected
    assert actual_database == expected_database == database
    assert actual_live == expected_live == live
    return actual


@pytest.mark.parametrize(
    ("frm", "to", "query"),
    [
        (None, None, None),
        (100, 200, None),
        (100.0, 200.0, "ADMIN"),
        (False, True, "0"),
        (-(10**400), 10**400, "ångström"),
        (math.nan, math.inf, "missing"),
    ],
)
def test_filter_window_and_search_match(frm, to, query):
    entries = [
        {"ts": 100.0, "status": 401, "user": "Admin"},
        {"ts": 199.5, "status": 200, "user": "ÅNGSTRÖM"},
        {"ts": "2026-08-01T12:00:00Z", "action": "commit"},
        {"ts": "garbage", "action": "upgrade"},
    ]
    _filter(entries, frm, to, query)


def test_filter_keeps_original_row_identity_and_stable_order():
    rows = [{"ts": 1, "value": "match"}, {"ts": 2, "value": "match"}]
    result = audit_service.filter_log_entries(rows, q="MATCH")
    assert result == rows
    assert result[0] is rows[0]
    assert result[1] is rows[1]


@pytest.mark.parametrize(
    ("entries", "frm", "to", "query"),
    [
        ([UserDict({"ts": 1, "value": "x"})], None, None, "x"),
        ([{"ts": 1, "nested": {"key": "value"}}], None, None, "value"),
        ([{"ts": 1}], None, None, 0),
        ([{"ts": {"bad": 1}}], 0, None, None),
        ([{"ts": 1, "value": 1 << 1001}], None, None, "1"),
        ([{"ts": 1 << 1024}], 0, None, None),
    ],
)
def test_filter_compatibility_cases_match(entries, frm, to, query):
    _filter(entries, frm, to, query)
    assert adapter.COMPATIBILITY["filter"] >= 1


def test_merge_db_wins_dedupes_and_sorts_stable_ties(monkeypatch):
    database = [
        {"id": "same", "ts": "2026-08-02T00:00:00Z", "source": "database"},
        {"id": "db", "ts": "2026-08-01T00:00:00Z", "source": "host-edit"},
    ]
    live = [
        {"id": "same", "ts": "2026-08-03T00:00:00Z", "source": "live"},
        {"id": "first", "ts": "2026-08-01T00:00:00Z"},
        {"id": "second", "ts": "2026-08-01T00:00:00Z"},
    ]
    outcome = _merge(monkeypatch, database, live)
    assert outcome[0] == "value"
    assert [row["id"] for row in outcome[1]] == ["same", "db", "first", "second"]
    assert outcome[1][0]["source"] == "database"


def test_merge_no_id_row_and_synthetic_key_collision_match(monkeypatch):
    expected_live = {"id": "", "ts": "2026-08-02T00:00:00Z", "status": "refused"}
    expected_database = [
        {
            "id": f"log-{id(expected_live)}",
            "ts": "2026-08-01T00:00:00Z",
            "source": "database",
        }
    ]
    with adapter.python_operations():
        monkeypatch.setattr(audit_service, "recent_changes", lambda: [expected_live])
        expected = server._merged_audit_entries(_manager(expected_database))
    actual_live = {"id": "", "ts": "2026-08-02T00:00:00Z", "status": "refused"}
    actual_database = [
        {
            "id": f"log-{id(actual_live)}",
            "ts": "2026-08-01T00:00:00Z",
            "source": "database",
        }
    ]
    monkeypatch.setattr(audit_service, "recent_changes", lambda: [actual_live])
    actual = server._merged_audit_entries(_manager(actual_database))
    assert actual == expected
    assert len(actual) == 1
    assert actual[0]["status"] == "refused"


def test_merge_keeps_database_identity_and_copies_live(monkeypatch):
    database = [{"id": "db", "ts": "2", "source": "host-edit"}]
    live = [{"id": "live", "ts": "1", "source": "foreign"}]
    monkeypatch.setattr(audit_service, "recent_changes", lambda: live)
    result = server._merged_audit_entries(_manager(database))
    assert result[0] is database[0]
    assert result[1] is not live[0]
    assert result[1]["source"] == "control"


@pytest.mark.parametrize(
    ("database", "live"),
    [
        ([UserDict({"id": "db", "ts": "2"})], []),
        ([{"id": 1, "ts": "2"}], []),
        ([{"id": "db", "ts": {"bad": 1}}], []),
        ([], [{"id": "live", "ts": {"bad": 1}}]),
    ],
)
def test_merge_compatibility_cases_match(monkeypatch, database, live):
    _merge(monkeypatch, database, live)
    assert adapter.COMPATIBILITY["merge"] >= 1


@pytest.mark.parametrize(
    ("query", "expected"),
    [
        ({}, (None, None, None)),
        ({"from": "1.5", "to": "2", "q": "  abc  "}, (1.5, 2.0, "abc")),
        ({"from": "bad", "to": "nan", "q": ""}, (None, None, None)),
        ({"from": "inf", "to": "-inf", "q": "x"}, (None, None, "x")),
        ({"q": "å" * 201}, (None, None, "å" * 200)),
        ({"q": "\ud800" * 201}, (None, None, "\ud800" * 200)),
    ],
)
def test_log_filters_match(query, expected):
    request = SimpleNamespace(query=query)
    assert server._log_filters(request) == adapter.python_call("_log_filters", request) == expected


def test_explicit_compatibility_helpers_match_reference_policy(monkeypatch):
    rows = [{"ts": 1, "nested": {"value": "needle"}}]
    assert go_audit_query._filter_compat(rows, None, None, "needle") == adapter.python_call(
        "filter_log_entries", rows, None, None, "needle"
    )
    database = [UserDict({"id": "db", "ts": "2"})]
    live = []
    with adapter.python_operations():
        monkeypatch.setattr(audit_service, "recent_changes", lambda: live)
        expected = server._merged_audit_entries(_manager(database))
    assert go_audit_query._merge_compat(database, lambda: live) == expected
