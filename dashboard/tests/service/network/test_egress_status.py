"""The egress panel and header badge follow the host's live firewall verdict (#2599)."""

import json

import pytest

from mining_dashboard.service.network import egress, egress_status
from mining_dashboard.service.network.egress import compute_egress_posture, compute_topology
from mining_dashboard.service.network.egress_status import (
    ENFORCED,
    MISSING,
    UNVERIFIED,
    egress_firewall_state,
    with_firewall_state,
)
from mining_dashboard.web.views.views import _egress_badge
from tests.service.conftest import _SAFE

NOW = 1_800_000_000


def _write(tmp_path, body):
    path = tmp_path / "egress-status.json"
    path.write_text(body if isinstance(body, str) else json.dumps(body))
    return str(path)


@pytest.mark.parametrize(
    ("rc", "state"),
    [(0, ENFORCED), (1, MISSING), (2, MISSING), (3, UNVERIFIED), (4, MISSING), (5, MISSING)],
)
def test_each_host_verdict_maps_to_a_state(tmp_path, rc, state):
    path = _write(tmp_path, {"rc": rc, "verdict": "x", "checked_at": NOW - 60})
    assert egress_firewall_state(path, now=NOW) == state


@pytest.mark.parametrize(
    "body",
    [
        None,  # no file: an install whose `up` has not installed the timer yet
        "{not json",
        [],
        {"verdict": "enforced", "checked_at": NOW},
        {"rc": 0, "checked_at": NOW - 3 * 120 - 1},  # the timer stopped: three missed checks
        {"rc": 0, "checked_at": NOW + 3 * 120 + 1},  # a clock that cannot be trusted either way
        {"rc": 1, "checked_at": NOW - 3 * 120 - 1},  # a stale alarm is not repeated as current
    ],
)
def test_anything_but_a_fresh_verdict_is_unverified(tmp_path, body):
    path = str(tmp_path / "absent.json") if body is None else _write(tmp_path, body)
    assert egress_firewall_state(path, now=NOW) == UNVERIFIED


def test_a_check_within_three_intervals_is_fresh(tmp_path):
    path = _write(tmp_path, {"rc": 0, "checked_at": NOW - 3 * 120})
    assert egress_firewall_state(path, now=NOW) == ENFORCED


def _posture(state, **overrides):
    return with_firewall_state(compute_egress_posture, state=state, **{**_SAFE, **overrides})


def test_an_enforced_firewall_keeps_today_s_posture():
    assert _posture(ENFORCED, p2pool_clearnet=True) == {
        **compute_egress_posture(**{**_SAFE, "p2pool_clearnet": True}),
        "summary": {
            **compute_egress_posture(**{**_SAFE, "p2pool_clearnet": True})["summary"],
            "firewall_state": ENFORCED,
        },
    }


def test_a_missing_firewall_warns_and_claims_nothing_is_blocked():
    p = _posture(MISSING, p2pool_clearnet=True)
    s = p["summary"]
    assert s["firewall_state"] == MISSING
    assert s["level"] == "warn"
    assert s["label"].startswith("Tor-only egress firewall MISSING")
    assert "blocked by the egress firewall" not in s["label"]
    assert s["blocked_by_firewall"] == 0
    assert s["leaks"] == 1  # p2pool's clearnet sidechain dial is live without the DROP
    assert not any(c.get("blocked_by_firewall") for comp in p["components"] for c in comp["conns"])
    badge = _egress_badge(s)
    assert badge["variant"] == "bad"
    assert "MISSING" in badge["text"]


def test_a_missing_firewall_warns_even_when_every_route_is_tor():
    s = _posture(MISSING)["summary"]
    assert (s["leaks"], s["level"]) == (0, "warn")
    assert _egress_badge(s)["variant"] == "warn"
    assert s["label"] == (
        "Tor-only egress firewall MISSING on the host (clearnet egress is not fail-closed; "
        "run 'pithead up'); All egress via Tor"
    )


def test_an_unverified_firewall_never_shows_green():
    s = _posture(UNVERIFIED)["summary"]
    assert s["level"] == "warn"
    assert s["label"].startswith("Egress firewall state unverified")
    assert _egress_badge(s)["variant"] == "warn"


def test_an_opted_out_firewall_ignores_the_status_file():
    p = with_firewall_state(compute_egress_posture, state=MISSING, **{**_SAFE, "firewall": False})
    assert p == compute_egress_posture(**{**_SAFE, "firewall": False})


def test_the_topology_summary_follows_the_same_state():
    t = with_firewall_state(compute_topology, state=MISSING, **{**_SAFE, "p2pool_clearnet": True})
    assert t["summary"]["firewall_state"] == MISSING
    assert not any(e.get("blocked_by_firewall") for e in t["edges"])


def test_the_live_builders_read_the_host_file(tmp_path, monkeypatch):
    monkeypatch.setattr(egress.config, "TOR_EGRESS_FIREWALL", True)
    monkeypatch.setattr(
        egress_status, "EGRESS_STATUS_PATH", _write(tmp_path, {"rc": 1, "checked_at": 0})
    )
    monkeypatch.setattr(egress_status.time, "time", lambda: 60)
    assert egress.egress_posture_from_config()["summary"]["firewall_state"] == MISSING
    assert egress.topology_from_config()["summary"]["firewall_state"] == MISSING
    assert egress_status.live_firewall_state() == MISSING
    monkeypatch.setattr(egress.config, "TOR_EGRESS_FIREWALL", False)
    assert egress_status.live_firewall_state() is None
