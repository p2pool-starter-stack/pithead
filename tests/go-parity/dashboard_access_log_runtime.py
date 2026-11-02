import os

import dashboard_access_log_plugin as adapter
import pytest

from mining_dashboard import go_access_log
from mining_dashboard.service import audit_service

# ruff: noqa: S101

pytest_plugins = ["dashboard_access_log_plugin"]
pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)


def _row(ts=100.0, status=401, uri="/old"):
    return {
        "ts": ts,
        "status": status,
        "request": {"method": "GET", "uri": uri},
        "user_id": "admin",
    }


def test_reads_rows_once_then_clock_once(monkeypatch):
    order = []
    monkeypatch.setattr(
        audit_service,
        "access_rows",
        lambda _path: order.append("rows") or [_row()],
    )
    monkeypatch.setattr(audit_service.time, "time", lambda: order.append("clock") or 200.0)
    summary = audit_service.access_summary()
    assert summary["failures_24h"] == 1
    assert order == ["rows", "clock"]


def test_unavailable_does_not_read_clock_or_native_unused_values(monkeypatch):
    monkeypatch.setattr(audit_service, "access_rows", lambda _path: None)
    monkeypatch.setattr(
        audit_service.time,
        "time",
        lambda: (_ for _ in ()).throw(AssertionError("clock read")),
    )
    summary = audit_service.access_summary(limit=object())
    assert summary["available"] is False


def test_one_native_call_uses_captured_generation(monkeypatch):
    rows = [_row(uri={"path": ["/old", 7]})]
    rows[0]["user_id"] = ["admin", {"level": 1}]
    call = go_access_log._call
    captured = []

    def interleaved(operation, **values):
        captured.append(values["config"])
        rows[0]["ts"] = 999.0
        rows[0]["request"]["uri"]["path"][0] = "/new"
        rows[0]["user_id"][1]["level"] = 9
        return call(operation, **values)

    monkeypatch.setattr(audit_service, "access_rows", lambda _path: rows)
    monkeypatch.setattr(go_access_log, "_call", interleaved)
    summary = audit_service.access_summary(now=200.0)
    assert summary["entries"] == [
        {
            "ts": 100.0,
            "status": 401,
            "method": "GET",
            "uri": "path: /old 7",
            "user": "admin level: 1",
        }
    ]
    assert captured[0]["entries"][0]["ts"] == 100.0
    assert captured[0]["entries"][0]["uri"] == "{'path': ['/old', 7]}"
    assert captured[0]["entries"][0]["user"] == "['admin', {'level': 1}]"


def test_provider_coercions_happen_before_native_call_in_row_order(monkeypatch):
    reads = []

    class Number:
        def __init__(self, name, value):
            self.name = name
            self.value = value

        def __float__(self):
            reads.append("float-" + self.name)
            return float(self.value)

        def __int__(self):
            reads.append("int-" + self.name)
            return int(self.value)

    rows = [_row(Number("first", 1), Number("first", 401)), _row(Number("second", 2), 200)]
    monkeypatch.setattr(audit_service, "access_rows", lambda _path: rows)
    audit_service.access_summary(now=10.0)
    assert reads == ["float-first", "int-first", "float-second"]


def test_replaced_reader_is_read_once_before_native_call(monkeypatch):
    rows = [_row()]
    calls = []

    def reader(path):
        calls.append(path)
        return rows

    monkeypatch.setattr(audit_service, "access_rows", reader)
    assert audit_service.access_summary(now=200.0)["failures_24h"] == 1
    assert len(calls) == 1


@pytest.mark.parametrize(
    ("name", "replacement", "reason"),
    [
        ("_clean", lambda value, max_len=200: str(value)[:max_len], "sanitizer-provider"),
        ("float", lambda value: float(value), "numeric-provider"),
        ("int", lambda value: int(value), "numeric-provider"),
    ],
)
def test_replaced_scalar_provider_uses_explicit_compatibility(
    monkeypatch, name, replacement, reason
):
    monkeypatch.setattr(audit_service, name, replacement, raising=False)
    monkeypatch.setattr(audit_service, "access_rows", lambda _path: [_row()])
    before = adapter.COMPATIBILITY[reason]
    assert audit_service.access_summary(now=200.0)["failures_24h"] == 1
    assert adapter.COMPATIBILITY[reason] == before + 1


def test_replaced_text_provider_preserves_reference_error(monkeypatch):
    monkeypatch.setattr(audit_service, "str", lambda value: str(value), raising=False)
    monkeypatch.setattr(audit_service, "access_rows", lambda _path: [_row()])
    before = adapter.COMPATIBILITY["text-provider"]
    with pytest.raises(TypeError, match="isinstance"):
        audit_service.access_summary(now=200.0)
    assert adapter.COMPATIBILITY["text-provider"] == before + 1


def test_replaced_method_provider_uses_explicit_compatibility(monkeypatch):
    monkeypatch.setattr(audit_service, "_KNOWN_METHODS", list(audit_service._KNOWN_METHODS))
    monkeypatch.setattr(audit_service, "access_rows", lambda _path: [_row()])
    before = adapter.COMPATIBILITY["method-provider"]
    assert audit_service.access_summary(now=200.0)["failures_24h"] == 1
    assert adapter.COMPATIBILITY["method-provider"] == before + 1


def test_replaced_finite_provider_uses_explicit_compatibility(monkeypatch):
    finite = go_access_log.PROVIDERS["isfinite"]
    monkeypatch.setattr(audit_service.math, "isfinite", lambda value: finite(value))
    monkeypatch.setattr(audit_service, "access_rows", lambda _path: [_row()])
    before = adapter.COMPATIBILITY["finite-provider"]
    assert audit_service.access_summary(now=200.0)["failures_24h"] == 1
    assert adapter.COMPATIBILITY["finite-provider"] == before + 1


@pytest.mark.parametrize(
    ("field", "value", "reason", "error"),
    [
        ("now", object(), "clock-value", TypeError),
        ("threshold", object(), "rotation-threshold", TypeError),
    ],
)
def test_invalid_scalar_compatibility_preserves_failure_order(
    monkeypatch, field, value, reason, error
):
    monkeypatch.setattr(audit_service, "access_rows", lambda _path: [_row()])
    if field == "threshold":
        monkeypatch.setattr(audit_service, "ROTATE_HINT_401S", value)
        arguments = {"now": 200.0}
    else:
        arguments = {"now": value}
    monkeypatch.setattr(
        go_access_log,
        "_call",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(AssertionError("native called")),
    )
    before = adapter.COMPATIBILITY[reason]
    with pytest.raises(error):
        audit_service.access_summary(**arguments)
    assert adapter.COMPATIBILITY[reason] == before + 1


def test_wide_parsed_status_uses_compatibility_before_native(monkeypatch):
    row = _row(status="9" * 400)
    monkeypatch.setattr(audit_service, "access_rows", lambda _path: [row])
    monkeypatch.setattr(
        go_access_log,
        "_call",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(AssertionError("native called")),
    )
    before = adapter.COMPATIBILITY["wide-status"]
    summary = audit_service.access_summary(now=200.0)
    assert summary["entries"][0]["status"] == 0
    assert adapter.COMPATIBILITY["wide-status"] == before + 1


def test_retained_row_cap_uses_compatibility_before_projection(monkeypatch):
    count = go_access_log._NATIVE_MAX_ROWS + 1
    rows = [_row()] * count
    monkeypatch.setattr(audit_service, "access_rows", lambda _path: rows)
    monkeypatch.setattr(
        go_access_log,
        "_call",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(AssertionError("native called")),
    )
    before = adapter.COMPATIBILITY["retained-row-count"]
    summary = audit_service.access_summary(limit=0, now=200.0)
    assert summary["entries"] == []
    assert summary["failures_24h"] == count
    assert adapter.COMPATIBILITY["retained-row-count"] == before + 1


def test_compatibility_preserves_lazy_error(monkeypatch):
    def rows():
        yield _row()
        raise RuntimeError("late row failure")

    monkeypatch.setattr(audit_service, "access_rows", lambda _path: rows())
    with pytest.raises(RuntimeError, match="late row failure"):
        audit_service.access_summary(now=200.0)


@pytest.mark.parametrize("failure", ["invalid", "transport"])
def test_native_failures_do_not_use_reference_policy(monkeypatch, failure):
    monkeypatch.setattr(audit_service, "access_rows", lambda _path: [_row()])

    def failed(*_args, **_kwargs):
        if failure == "transport":
            raise RuntimeError("transport failed")
        return None, {}

    monkeypatch.setattr(go_access_log, "_call", failed)
    with pytest.raises(RuntimeError):
        audit_service.access_summary(now=200.0)


@pytest.mark.parametrize(
    "reply",
    [
        ["dict", [["available", ["bool", True]]]],
        [
            "dict",
            [
                ["available", ["bool", True]],
                ["entries", ["list", []]],
                ["failures_24h", ["int", "-1"]],
                ["last_failure_ts", ["null", None]],
                ["rotate_hint", ["bool", False]],
            ],
        ],
        [
            "dict",
            [
                ["available", ["bool", True]],
                ["entries", ["list", [["dict", []]]]],
                ["failures_24h", ["int", "0"]],
                ["last_failure_ts", ["null", None]],
                ["rotate_hint", ["bool", False]],
            ],
        ],
    ],
)
def test_malformed_native_reply_is_rejected(monkeypatch, reply):
    monkeypatch.setattr(audit_service, "access_rows", lambda _path: [_row()])
    monkeypatch.setattr(go_access_log, "_call", lambda *_args, **_kwargs: (reply, {}))
    with pytest.raises(RuntimeError):
        audit_service.access_summary(now=200.0)


def test_malformed_unavailable_native_reply_is_rejected(monkeypatch):
    reply = [
        "dict",
        [
            ["available", ["bool", False]],
            ["entries", ["list", []]],
            ["failures_24h", ["int", "0"]],
            ["last_failure_ts", ["null", None]],
            ["rotate_hint", ["bool", True]],
        ],
    ]
    monkeypatch.setattr(audit_service, "access_rows", lambda _path: None)
    monkeypatch.setattr(go_access_log, "_call", lambda *_args, **_kwargs: (reply, {}))
    with pytest.raises(RuntimeError):
        audit_service.access_summary(limit=object())


def test_install_keeps_original_and_is_idempotent():
    originals = dict(go_access_log.REFERENCE_FUNCTIONS)
    go_access_log.install()
    assert go_access_log.REFERENCE_FUNCTIONS == originals
    assert audit_service.access_summary is go_access_log.access_summary
