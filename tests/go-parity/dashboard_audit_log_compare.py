import copy
import math
import os

import dashboard_audit_log_plugin as adapter
import pytest

from mining_dashboard.service import audit_service, data_audit

# ruff: noqa: S101

pytest_plugins = ["dashboard_audit_log_plugin"]
pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)


def _outcome(function, *args, **kwargs):
    try:
        return "value", function(*args, **kwargs)
    except Exception as error:
        return "error", type(error), str(error)


def _recent(monkeypatch, entries, limit=50):
    expected_entries = copy.deepcopy(entries)
    actual_entries = copy.deepcopy(entries)
    monkeypatch.setattr(audit_service, "_tail_json_lines", lambda _path: expected_entries)
    expected = _outcome(adapter.python_call, "recent_changes", limit)
    monkeypatch.setattr(audit_service, "_tail_json_lines", lambda _path: actual_entries)
    actual = _outcome(audit_service.recent_changes, limit)
    assert actual == expected
    assert actual_entries == expected_entries == entries
    return actual


def _rows(entries):
    expected_entries = copy.deepcopy(entries)
    actual_entries = copy.deepcopy(entries)
    expected = _outcome(lambda: list(adapter.python_call("_control_audit_rows", expected_entries)))
    actual = _outcome(lambda: list(data_audit._control_audit_rows(actual_entries)))
    assert actual == expected
    assert actual_entries == expected_entries == entries
    return actual


def test_recent_normalizes_fields_order_and_drops_extras(monkeypatch):
    entries = [
        {
            "ts": "old",
            "id": "old-id",
            "actor": "old actor",
            "action": "preview",
            "status": "previewed",
            "keys": "OLD_KEY",
            "secret": "drop-me",
        },
        {
            "ts": "new<script>",
            "id": 'new"id',
            "actor": "new\\actor\x1b[31m",
            "action": "commit<script>",
            "status": "applied<img>",
            "keys": "XVB_ENABLED >< P2POOL_PORT",
            "extra": {"opaque": 1},
        },
    ]
    outcome = _recent(monkeypatch, entries)
    assert outcome[0] == "value"
    assert [row["id"] for row in outcome[1]] == ["newid", "old-id"]
    assert all(set(row) == {"ts", "id", "actor", "action", "status", "keys"} for row in outcome[1])


@pytest.mark.parametrize(
    "entry",
    [
        {"ts": None, "id": 42, "actor": True, "action": 1.5, "status": [], "keys": {}},
        {
            "ts": math.nan,
            "id": math.inf,
            "actor": -math.inf,
            "action": "\ud800action",
            "status": "status\udfff",
            "keys": "key\ud800value",
        },
        {
            "ts": "t" * 100,
            "id": "i" * 100,
            "actor": "a" * 100,
            "action": "c" * 100,
            "status": "s" * 100,
            "keys": "k" * 500,
        },
    ],
)
def test_recent_coercion_nonfinite_surrogate_and_caps_match(monkeypatch, entry):
    _recent(monkeypatch, [entry])


@pytest.mark.parametrize("limit", [0, 1, 2, -1, -3, 50])
def test_recent_limit_semantics_match(monkeypatch, limit):
    entries = [{"id": str(index), "actor": str(index)} for index in range(4)]
    _recent(monkeypatch, entries, limit)


@pytest.mark.parametrize("entries,limit", [([None], 50), ([[]], 50), ([{}], "bad")])
def test_recent_type_failures_match(monkeypatch, entries, limit):
    assert _recent(monkeypatch, entries, limit)[0] == "error"


def test_mirror_rows_reverse_order_skip_falsy_ids_and_keep_exact_fields():
    entries = [
        {"id": "old", "ts": "1", "actor": "a", "action": "preview", "status": "p"},
        {"id": "", "ts": "2", "actor": "skip"},
        {
            "id": "new",
            "ts": "3",
            "actor": "b",
            "action": "commit",
            "status": "applied",
            "keys": "X",
            "extra": "drop",
        },
    ]
    outcome = _rows(entries)
    assert outcome == (
        "value",
        [
            {
                "id": "new",
                "ts": "3",
                "source": "control",
                "actor": "b",
                "action": "commit",
                "status": "applied",
                "keys": "X",
            },
            {
                "id": "old",
                "ts": "1",
                "source": "control",
                "actor": "a",
                "action": "preview",
                "status": "p",
                "keys": "",
            },
        ],
    )


@pytest.mark.parametrize(
    "entries",
    [
        [{"id": None}, {"id": 0}, {"id": False}],
        [None],
    ],
)
def test_mirror_row_coercions_and_type_failures_match(entries):
    _rows(entries)
