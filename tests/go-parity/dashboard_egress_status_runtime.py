import json
import os

import dashboard_egress_status_plugin as adapter
import pytest

from mining_dashboard import go_egress_status
from mining_dashboard.service.network import egress_status

# ruff: noqa: S101

pytest_plugins = ["dashboard_egress_status_plugin"]
pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)

NOW = 1_800_000_000


def _write(tmp_path, value):
    path = tmp_path / "status.json"
    path.write_text(json.dumps(value))
    return str(path)


def test_invalid_status_returns_before_clock(tmp_path, monkeypatch):
    path = _write(tmp_path, {"rc": False, "checked_at": NOW})
    monkeypatch.setattr(
        egress_status.time,
        "time",
        lambda: (_ for _ in ()).throw(AssertionError("clock read")),
    )
    assert egress_status.egress_firewall_state(path) == "unverified"


def test_clock_provider_compatibility_reads_clock_once(tmp_path, monkeypatch):
    path = _write(tmp_path, {"rc": 0, "checked_at": NOW})
    calls = []
    monkeypatch.setattr(egress_status.time, "time", lambda: calls.append("clock") or NOW)
    before = adapter.COMPATIBILITY["_loaded_compat:clock-provider"]
    assert egress_status.egress_firewall_state(path) == "enforced"
    assert calls == ["clock"]
    assert adapter.COMPATIBILITY["_loaded_compat:clock-provider"] == before + 1


def test_abs_provider_compatibility_preserves_current_provider(tmp_path, monkeypatch):
    path = _write(tmp_path, {"rc": 0, "checked_at": NOW})
    calls = []
    monkeypatch.setattr(
        egress_status, "abs", lambda value: calls.append(value) or 361, raising=False
    )
    before = adapter.COMPATIBILITY["_loaded_compat:abs-provider"]
    assert egress_status.egress_firewall_state(path, NOW) == "unverified"
    assert calls == [0]
    assert adapter.COMPATIBILITY["_loaded_compat:abs-provider"] == before + 1


def test_abs_provider_custom_result_is_not_projected(tmp_path, monkeypatch):
    path = _write(tmp_path, {"rc": 0, "checked_at": NOW})
    calls = []

    class Age:
        def __gt__(self, other):
            calls.append(("compare", other))
            return False

    monkeypatch.setattr(
        egress_status, "abs", lambda value: calls.append(value) or Age(), raising=False
    )
    assert egress_status.egress_firewall_state(path, NOW) == "enforced"
    assert calls == [0, ("compare", 360)]


def test_abs_provider_error_is_preserved(tmp_path, monkeypatch):
    path = _write(tmp_path, {"rc": 0, "checked_at": NOW})
    calls = []

    def failed(value):
        calls.append(value)
        raise RuntimeError("abs failed")

    monkeypatch.setattr(egress_status, "abs", failed, raising=False)
    with pytest.raises(RuntimeError, match="abs failed"):
        egress_status.egress_firewall_state(path, NOW)
    assert calls == [0]


def test_custom_age_compatibility_does_not_repeat_arithmetic(tmp_path):
    path = _write(tmp_path, {"rc": 0, "checked_at": NOW})
    calls = []

    class Age:
        def __gt__(self, other):
            calls.append(("compare", other))
            return False

    class Delta:
        def __abs__(self):
            calls.append(("abs",))
            return Age()

    class Clock:
        def __sub__(self, other):
            calls.append(("subtract", other))
            return Delta()

    before = adapter.COMPATIBILITY["_result_compat:age-shape"]
    assert egress_status.egress_firewall_state(path, Clock()) == "enforced"
    assert calls == [("subtract", NOW), ("abs",), ("compare", 360)]
    assert adapter.COMPATIBILITY["_result_compat:age-shape"] == before + 1


@pytest.mark.parametrize(
    "value",
    [1 << 1000, -(1 << 1000)],
)
def test_wide_integer_uses_explicit_compatibility(tmp_path, value):
    path = _write(tmp_path, {"rc": 0, "checked_at": value})
    before = adapter.COMPATIBILITY["_loaded_compat:wide-integer"]
    assert egress_status.egress_firewall_state(path, NOW) == "unverified"
    assert adapter.COMPATIBILITY["_loaded_compat:wide-integer"] == before + 1


def test_interposed_state_provider_runs_once_then_uses_native_plan(monkeypatch):
    calls = []
    monkeypatch.setattr(
        egress_status, "egress_firewall_state", lambda: calls.append("state") or "missing"
    )
    before_compatibility = dict(adapter.COMPATIBILITY)
    before_plans = adapter.CALLS["firewall-plan"]
    result = go_egress_status.with_firewall_state(
        lambda **values: {"summary": {"label": str(values["firewall"])}}, firewall=True
    )
    assert calls == ["state"]
    assert result["summary"]["firewall_state"] == "missing"
    assert adapter.CALLS["firewall-plan"] == before_plans + 1
    assert dict(adapter.COMPATIBILITY) == before_compatibility


def test_state_truthiness_is_evaluated_once():
    calls = []

    class State(str):
        def __bool__(self):
            calls.append("state")
            return True

    result = egress_status.with_firewall_state(
        lambda **_values: {"summary": {"label": "safe"}},
        firewall=True,
        state=State("enforced"),
    )
    assert result["summary"]["firewall_state"] == "enforced"
    assert calls == ["state"]


def test_firewall_truthiness_is_evaluated_once():
    calls = []

    class Firewall:
        def __bool__(self):
            calls.append("firewall")
            return True

    result = egress_status.with_firewall_state(
        lambda **_values: {"summary": {"label": "safe"}},
        firewall=Firewall(),
        state="enforced",
    )
    assert result["summary"]["firewall_state"] == "enforced"
    assert calls == ["firewall"]


def test_unknown_state_preserves_partial_mutation_order():
    summary = {"label": "original"}
    before = adapter.COMPATIBILITY["_resolved_compat:state-value"]
    with pytest.raises(KeyError, match="unknown"):
        egress_status.with_firewall_state(
            lambda **_values: {"summary": summary}, firewall=True, state="unknown"
        )
    assert summary == {"label": "original", "firewall_state": "unknown", "level": "warn"}
    assert adapter.COMPATIBILITY["_resolved_compat:state-value"] == before + 1


def test_label_mapping_subclass_does_not_run_equality(monkeypatch):
    class Labels(dict):
        def __eq__(self, other):
            raise AssertionError(f"compared with {other}")

    monkeypatch.setattr(egress_status, "_LABELS", Labels(egress_status._LABELS))
    before = adapter.COMPATIBILITY["_resolved_compat:plan-label"]
    result = egress_status.with_firewall_state(
        lambda **_values: {"summary": {"label": "safe"}},
        firewall=True,
        state="missing",
    )
    assert result["summary"]["label"].startswith("Tor-only egress firewall MISSING")
    assert adapter.COMPATIBILITY["_resolved_compat:plan-label"] == before + 1


def test_opaque_summary_label_formats_after_overlay_mutations():
    events = []

    class Label:
        def __format__(self, spec):
            events.append(("format", spec))
            return "opaque"

    class Summary(dict):
        def __setitem__(self, key, value):
            events.append(("set", key))
            super().__setitem__(key, value)

    summary = Summary(label=Label())
    result = egress_status.with_firewall_state(
        lambda **_values: {"summary": summary}, firewall=True, state="missing"
    )
    assert result["summary"] is summary
    assert events == [
        ("set", "firewall_state"),
        ("set", "level"),
        ("format", ""),
        ("set", "label"),
    ]


@pytest.mark.parametrize(
    ("operation", "target"),
    [
        (
            "firewall-status-valid",
            lambda path: egress_status.egress_firewall_state(path, NOW),
        ),
        (
            "firewall-status-result",
            lambda path: egress_status.egress_firewall_state(path, NOW),
        ),
        (
            "firewall-plan",
            lambda _path: egress_status.with_firewall_state(
                lambda **_values: {"summary": {"label": "safe"}},
                firewall=True,
                state="enforced",
            ),
        ),
    ],
)
def test_native_errors_are_fatal(tmp_path, monkeypatch, operation, target):
    path = _write(tmp_path, {"rc": 0, "checked_at": NOW})
    call = go_egress_status.go_channel.call

    def failed(helper, payload):
        if payload["operation"] == operation:
            raise RuntimeError("native failed")
        return call(helper, payload)

    monkeypatch.setattr(go_egress_status.go_channel, "call", failed)
    with pytest.raises(RuntimeError, match="native failed"):
        target(path)


def test_malformed_native_reply_is_fatal(tmp_path, monkeypatch):
    path = _write(tmp_path, {"rc": 0, "checked_at": NOW})
    monkeypatch.setattr(go_egress_status.go_channel, "call", lambda *_args, **_kwargs: {})
    with pytest.raises(RuntimeError, match="invalid firewall status validity"):
        egress_status.egress_firewall_state(path, NOW)
