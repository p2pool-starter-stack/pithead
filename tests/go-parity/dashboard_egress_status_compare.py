import json
import os

import dashboard_egress_status_plugin as adapter
import pytest

from mining_dashboard.service.network import egress_status

# ruff: noqa: S101

pytest_plugins = ["dashboard_egress_status_plugin"]
pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)

NOW = 1_800_000_000


def _write(tmp_path, body):
    path = tmp_path / "status.json"
    path.write_text(body if isinstance(body, str) else json.dumps(body))
    return str(path)


def _outcome(function, *args, **kwargs):
    try:
        return "value", function(*args, **kwargs)
    except Exception as error:
        return "error", type(error), str(error)


@pytest.mark.parametrize(
    "body",
    [
        {"rc": 0, "checked_at": NOW - 360},
        {"rc": 1, "checked_at": NOW - 361},
        {"rc": 2, "checked_at": NOW + 60},
        {"rc": 3, "checked_at": NOW},
        {"rc": 4, "checked_at": NOW},
        {"rc": 5, "checked_at": NOW},
        {"rc": False, "checked_at": NOW},
        {"rc": 0.0, "checked_at": NOW},
        {"rc": 0, "checked_at": "invalid"},
        [],
        '{"rc":0,"checked_at":NaN}',
        '{"rc":0,"checked_at":Infinity}',
        {"rc": 1 << 999, "checked_at": NOW},
        {"rc": -(1 << 999), "checked_at": NOW},
    ],
)
def test_status_matches_reference(tmp_path, body):
    path = _write(tmp_path, body)
    with adapter.python_operations():
        expected = _outcome(adapter.ORIGINALS["egress_firewall_state"], path, NOW)
    actual = _outcome(adapter.NATIVES["egress_firewall_state"], path, NOW)
    assert actual == expected


@pytest.mark.parametrize("now", [float("nan"), float("inf"), float("-inf")])
def test_nonfinite_computed_age_matches_reference(tmp_path, now):
    path = _write(tmp_path, {"rc": 0, "checked_at": 0})
    with adapter.python_operations():
        expected = adapter.ORIGINALS["egress_firewall_state"](path, now)
    assert egress_status.egress_firewall_state(path, now) == expected


@pytest.mark.parametrize("state", ["enforced", "missing", "unverified"])
def test_firewall_overlay_matches_reference_and_preserves_identity(state):
    expected_result = {"summary": {"label": "All egress via Tor", "opaque": object()}}
    actual_result = {"summary": {"label": "All egress via Tor", "opaque": object()}}

    with adapter.python_operations():
        expected = adapter.ORIGINALS["with_firewall_state"](
            lambda **_values: expected_result, firewall=True, state=state
        )
    actual = egress_status.with_firewall_state(
        lambda **_values: actual_result, firewall=True, state=state
    )
    assert actual is actual_result
    assert actual["summary"] is actual_result["summary"]
    for field in ("firewall_state", "level", "label"):
        assert actual["summary"].get(field) == expected["summary"].get(field)


def test_disabled_firewall_returns_exact_builder_result_without_native_call():
    result = {"summary": {"opaque": object()}}
    before = dict(adapter.CALLS)
    actual = egress_status.with_firewall_state(
        lambda **values: result if values == {"firewall": False, "opaque": object} else None,
        firewall=False,
        opaque=object,
    )
    assert actual is result
    assert dict(adapter.CALLS) == before


def test_status_requests_project_only_numeric_metadata(tmp_path, monkeypatch):
    path = _write(tmp_path, {"rc": 0, "checked_at": NOW, "opaque": "not sent"})
    requests = []
    call = egress_status.egress_firewall_state.__globals__["_request"]

    def observed(operation, **payload):
        requests.append((operation, payload))
        return call(operation, **payload)

    monkeypatch.setitem(egress_status.egress_firewall_state.__globals__, "_request", observed)
    assert egress_status.egress_firewall_state(path, NOW) == "enforced"
    assert requests == [
        (
            "firewall-status-valid",
            {
                "rc": {"kind": "int", "value": "0"},
                "checked_at": {"kind": "int", "value": str(NOW)},
            },
        ),
        (
            "firewall-status-result",
            {
                "rc": {"kind": "int", "value": "0"},
                "age": {"kind": "int", "value": "0"},
            },
        ),
    ]
