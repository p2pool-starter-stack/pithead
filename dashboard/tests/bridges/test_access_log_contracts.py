from types import SimpleNamespace

import pytest

from mining_dashboard import go_access_log as bridge
from mining_dashboard.service import audit_service


@pytest.fixture
def access(monkeypatch):
    monkeypatch.setattr(
        bridge,
        "PROVIDERS",
        {
            "_clean": audit_service._clean,
            "_SAFE_CHARS": audit_service._SAFE_CHARS,
            "isfinite": audit_service.math.isfinite,
        },
    )
    monkeypatch.setattr(bridge, "REFERENCE_FUNCTIONS", {})
    monkeypatch.setattr(bridge, "_value", lambda result, _identities: result)
    return bridge


def summary(available=True, entries=None):
    return {
        "available": available,
        "entries": entries or [],
        "failures_24h": 0,
        "last_failure_ts": None,
        "rotate_hint": False,
    }


def test_access_projection_captures_rows_clock_and_native_summary(access, monkeypatch):
    rows = [
        {
            "ts": "1",
            "status": "401",
            "request": {"method": "GET", "uri": "/state"},
            "user_id": "operator",
        },
        {"ts": "bad", "status": "bad", "request": None},
    ]
    calls = []
    monkeypatch.setattr(audit_service, "access_rows", lambda path: rows)
    monkeypatch.setattr(audit_service, "time", SimpleNamespace(time=lambda: 10.0))
    result = summary(
        entries=[{"ts": 1.0, "status": 401, "method": "GET", "uri": "/state", "user": "operator"}]
    )
    result.update(failures_24h=1, last_failure_ts=1.0, rotate_hint=True)
    monkeypatch.setattr(
        access,
        "_call",
        lambda operation, **values: (calls.append((operation, values)) or result, {}),
    )
    assert access.access_summary(limit=1) is result
    operation, values = calls[0]
    assert operation == "audit-access" and values["config"]["now"] == 10.0
    assert values["config"]["entries"] == [
        {
            "ts": 1.0,
            "status": 401,
            "method": "GET",
            "uri": "/state",
            "user": "operator",
            "probe": None,
        },
        {"ts": 0.0, "status": 0, "method": None, "uri": "", "user": "", "probe": None},
    ]
    assert values["config"]["limit"] == 1


def test_unavailable_access_log_has_no_clock_dependency(access, monkeypatch):
    monkeypatch.setattr(audit_service, "access_rows", lambda _path: None)
    result = summary(False)
    monkeypatch.setattr(access, "_call", lambda *_args, **_kwargs: (result, {}))
    assert access.access_summary() is result


def test_access_compatibility_uses_captured_rows_once(access, monkeypatch):
    rows, calls = [{}], []
    monkeypatch.setattr(
        audit_service, "access_rows", lambda path: calls.append(("read", path)) or rows
    )
    monkeypatch.setattr(
        audit_service,
        "_access_summary_rows",
        lambda *args: calls.append(("reference", args)) or "reference",
    )
    assert access.access_summary(limit=1.5, now=1) == "reference"
    assert len(calls) == 2 and calls[1][1] == (rows, 1.5, 1)
    rows[0]["status"] = str(1 << 1001)
    assert access.access_summary(limit=1, now=1) == "reference"
    assert calls[-1][1][0] is rows


@pytest.mark.parametrize(
    "raw",
    [
        None,
        [None],
        [{1: "value"}],
        [{"request": {1: "value"}}],
        [{"ts": object()}],
        [{"status": 1 << 1001}],
        [{"request": {"method": type("Text", (str,), {})("GET")}}],
        [{"request": {"uri": ("tuple",)}}],
    ],
)
def test_access_rows_refuse_unsupported_shapes(access, raw):
    assert not access._native_rows(raw)


def test_access_text_classifier_rejects_cycles_and_unbounded_integers(access):
    cycle = []
    cycle.append(cycle)
    assert not access._plain_text(cycle)
    assert not access._plain_text({1: "value"})
    assert not access._plain_text(1 << 1001)
    assert access._plain_text({"field": [None, True, 1.0, "text"]})


@pytest.mark.parametrize(
    "arguments,reason",
    [
        (([], 1.0, 1, 1, {"GET"}), "slice-limit"),
        (([], 1, "clock", 1, {"GET"}), "clock-value"),
        (([], 1, 1, "threshold", {"GET"}), "rotation-threshold"),
        (([], 1, 1, 1, ["GET"]), "method-provider"),
    ],
)
def test_access_selection_reasons_are_explicit(access, arguments, reason):
    assert access._selection_reason(*arguments) == reason


@pytest.mark.parametrize(
    "name,reason",
    [
        ("_clean", "sanitizer-provider"),
        ("_SAFE_CHARS", "sanitizer-provider"),
        ("float", "numeric-provider"),
        ("int", "numeric-provider"),
        ("str", "text-provider"),
    ],
)
def test_access_replaced_providers_do_not_enter_native_path(access, monkeypatch, name, reason):
    monkeypatch.setattr(audit_service, name, object(), raising=False)
    assert access._selection_reason([], 1, 1, 1, {"GET"}) == reason


def test_access_retained_budget_and_finite_provider(access, monkeypatch):
    monkeypatch.setattr(access, "_NATIVE_MAX_ROWS", 0)
    assert access._selection_reason([{}], 1, 1, 1, {"GET"}) == "retained-row-count"
    monkeypatch.setattr(audit_service, "math", SimpleNamespace(isfinite=lambda _value: True))
    assert access._selection_reason([], 1, 1, 1, {"GET"}) == "finite-provider"


@pytest.mark.parametrize(
    "result",
    [
        None,
        {},
        {**summary(), "failures_24h": 1},
        {**summary(), "available": 1},
        {**summary(), "last_failure_ts": 1.0},
        {**summary(), "rotate_hint": 1},
    ],
)
def test_access_rejects_invalid_native_summaries(access, monkeypatch, result):
    monkeypatch.setattr(access, "_call", lambda *_args, **_kwargs: (result, {}))
    with pytest.raises(RuntimeError, match="native access log returned invalid"):
        access._summary(True, [])


@pytest.mark.parametrize(
    "field,value",
    [
        ("ts", float("nan")),
        ("status", 600),
        ("method", "UNKNOWN"),
        ("uri", "x" * 201),
        ("user", "\x00"),
    ],
)
def test_access_rejects_invalid_native_entry_fields(access, monkeypatch, field, value):
    row = {"ts": 1.0, "status": 200, "method": "GET", "uri": "/state", "user": "operator"}
    row[field] = value
    result = summary(entries=[row])
    monkeypatch.setattr(access, "_call", lambda *_args, **_kwargs: (result, {}))
    with pytest.raises(RuntimeError, match="invalid entries"):
        access._summary(True, [{}], methods=["GET"])


def test_access_unavailable_reply_and_decoder_are_checked(access, monkeypatch):
    monkeypatch.setattr(access, "_call", lambda *_args, **_kwargs: (summary(False), {}))
    result = summary(False)
    result["rotate_hint"] = True
    monkeypatch.setattr(access, "_call", lambda *_args, **_kwargs: (result, {}))
    with pytest.raises(RuntimeError, match="invalid availability"):
        access._summary(False)

    def fail(*_args):
        raise KeyError("missing reference")

    monkeypatch.setattr(access, "_value", fail)
    with pytest.raises(RuntimeError, match="invalid data"):
        access._summary(False)


def test_access_install_preserves_reference_and_provider_bindings(access, monkeypatch):
    original = audit_service.access_summary
    monkeypatch.setattr(audit_service, "access_summary", original)
    monkeypatch.setattr(access, "PROVIDERS", {})
    access.install()
    assert audit_service.access_summary is access.access_summary
    assert access.REFERENCE_FUNCTIONS["access_summary"] is original
    assert access.PROVIDERS["_clean"] is audit_service._clean
